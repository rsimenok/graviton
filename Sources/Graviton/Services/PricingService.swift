import Foundation

public protocol PricingSyncing: Sendable {
    var lastSyncDate: Date? { get }
    func shouldAutoSync(now: Date, maxAge: TimeInterval) -> Bool
    func rateFor(modelName: String?) -> ModelRate
    @discardableResult
    func fetchRemotePricing() async -> Bool
}

public final class PricingService: @unchecked Sendable, PricingSyncing {
    public static let shared = PricingService()
    public static let defaultAutoSyncInterval: TimeInterval = 24 * 60 * 60

    private let litellmURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let cacheURL: URL

    private var builtInRates: [String: ModelRate] = [:]
    private var remoteRates: [String: ModelRate] = [:]
    private var resolutionCache: [String: ModelRate] = [:]
    private let lock = NSLock()
    private var _lastSyncDate: Date?

    public var lastSyncDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastSyncDate
    }

    public func shouldAutoSync(now: Date = Date(), maxAge: TimeInterval = PricingService.defaultAutoSyncInterval) -> Bool {
        guard let synced = lastSyncDate else { return true }
        return now.timeIntervalSince(synced) >= maxAge
    }

    public init(cacheURL: URL? = nil, loadCache: Bool = true) {
        if let customURL = cacheURL {
            self.cacheURL = customURL
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let appCacheDir = cachesDir.appendingPathComponent("Graviton", isDirectory: true)
            try? FileManager.default.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
            self.cacheURL = appCacheDir.appendingPathComponent("pricing-litellm.json")
        }

        loadBuiltInDefaults()
        if loadCache {
            loadLocalCache()
        }
    }

    private func loadBuiltInDefaults() {
        // Official rates per 1M tokens ($/1M)
        let defaults: [String: ModelRate] = [
            // Gemini 4 family (including Neon & Argon orchestrators)
            "gemini-4-neon": ModelRate(inputPerMillion: 3.00, cacheReadPerMillion: 0.15, outputPerMillion: 15.00),
            "gemini-4-argon": ModelRate(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00),
            "gemini-4-hydrogen": ModelRate(inputPerMillion: 1.50, cacheReadPerMillion: 0.075, outputPerMillion: 7.50),
            "gemini-4-carbon": ModelRate(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00),

            // Gemini Flash family (Standard Antigravity default models)
            "gemini-3.8-flash": ModelRate(inputPerMillion: 0.75, cacheReadPerMillion: 0.075, outputPerMillion: 3.75),
            "gemini-3.5-flash": ModelRate(inputPerMillion: 1.50, cacheReadPerMillion: 0.15, outputPerMillion: 9.00),
            "gemini-3-flash": ModelRate(inputPerMillion: 0.50, cacheReadPerMillion: 0.05, outputPerMillion: 3.00),
            "gemini-2.5-flash": ModelRate(inputPerMillion: 0.30, cacheReadPerMillion: 0.03, outputPerMillion: 2.50),
            "gemini-2.0-flash": ModelRate(inputPerMillion: 0.10, cacheReadPerMillion: 0.0250, outputPerMillion: 0.40),
            "gemini-1.5-flash": ModelRate(inputPerMillion: 0.075, cacheReadPerMillion: 0.01875, outputPerMillion: 0.30),
            "gemini-flash": ModelRate(inputPerMillion: 0.30, cacheReadPerMillion: 0.03, outputPerMillion: 2.50),

            // Gemini Pro family
            "gemini-2.5-pro": ModelRate(inputPerMillion: 1.25, cacheReadPerMillion: 0.3125, outputPerMillion: 5.00),
            "gemini-1.5-pro": ModelRate(inputPerMillion: 1.25, cacheReadPerMillion: 0.3125, outputPerMillion: 5.00),
            "gemini-pro": ModelRate(inputPerMillion: 1.25, cacheReadPerMillion: 0.3125, outputPerMillion: 5.00),

            // Claude 5.5 & 3.x family
            "claude-opus-5-5": ModelRate(inputPerMillion: 4.00, cacheReadPerMillion: 0.20, outputPerMillion: 20.00),
            "claude-sonnet-5-5": ModelRate(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00),
            "claude-3-7-sonnet": ModelRate(inputPerMillion: 3.00, cacheReadPerMillion: 0.30, outputPerMillion: 15.00),
            "claude-3-5-sonnet": ModelRate(inputPerMillion: 3.00, cacheReadPerMillion: 0.30, outputPerMillion: 15.00),
            "claude-3-5-haiku": ModelRate(inputPerMillion: 0.80, cacheReadPerMillion: 0.08, outputPerMillion: 4.00),
            "claude-3-opus": ModelRate(inputPerMillion: 15.00, cacheReadPerMillion: 1.50, outputPerMillion: 75.00),

            // OpenAI OSS
            "gpt-oss-120b": ModelRate(inputPerMillion: 0.15, cacheReadPerMillion: 0.0375, outputPerMillion: 0.60),
        ]

        lock.lock()
        for (key, val) in defaults {
            builtInRates[key] = val
        }
        lock.unlock()
    }

    private func loadLocalCache() {
        guard let data = try? Data(contentsOf: cacheURL), parseAndApply(data: data, syncDate: nil) else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            setLastSyncDate(modDate)
        }
    }

    private func setLastSyncDate(_ date: Date) {
        lock.lock()
        _lastSyncDate = date
        lock.unlock()
    }

    public func applyPricingJSON(data: Data) {
        _ = parseAndApply(data: data, syncDate: nil)
    }

    /// Resolves a rate from synced LiteLLM entries (unprefixed first, then canonical provider prefixes),
    /// falling back to built-in defaults. Caller must hold `lock`.
    private func lookupRate(forKey key: String) -> ModelRate? {
        if let remote = remoteRates[key] {
            return remote
        }
        let prefixedCandidates = [
            "gemini/\(key)",
            "vertex_ai/\(key)",
            "anthropic/\(key)",
            "anthropic.\(key)",
            "azure_ai/\(key)",
            "openai.\(key)-1:0"
        ]
        for candidate in prefixedCandidates {
            if let remote = remoteRates[candidate] {
                return remote
            }
        }
        return builtInRates[key]
    }

    private func defaultFallbackRate() -> ModelRate {
        lookupRate(forKey: "gemini-2.5-flash")
            ?? ModelRate(inputPerMillion: 0.30, cacheReadPerMillion: 0.03, outputPerMillion: 2.50)
    }

    private static func mapOrchestratorAlias(_ hyphenated: String) -> String {
        switch hyphenated {
        case "gemini-pro-orchestrator-neon", "orchestrator-(neon)", "orchestrator-neon":
            return "gemini-4-neon"
        case "gemini-pro-orchestrator-g1-pro", "orchestrator-(argon)", "orchestrator-argon":
            return "gemini-4-argon"
        case "gemini-flash-worker-agy", "gemini-flash-worker":
            // The orchestrator execution worker is billed like the Gemini 4 Hydrogen family.
            return "gemini-4-hydrogen"
        default:
            return hyphenated
        }
    }

    public func rateFor(modelName: String?) -> ModelRate {
        lock.lock()
        defer { lock.unlock() }

        guard let rawTrimmed = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTrimmed.isEmpty else {
            return defaultFallbackRate()
        }

        let rawLower = rawTrimmed.lowercased()

        // 1. Fast lookup from memoized resolution cache
        if let cached = resolutionCache[rawLower] {
            return cached
        }

        let cleaned = ModelFormatter.stripEffortSuffix(from: rawTrimmed)
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawHyphenated = cleaned.replacingOccurrences(of: " ", with: "-")
        let hyphenated = Self.mapOrchestratorAlias(rawHyphenated)
        let dotHyphenated = hyphenated.replacingOccurrences(of: ".", with: "-")

        if let cached = resolutionCache[cleaned] ?? resolutionCache[hyphenated] ?? resolutionCache[dotHyphenated] {
            resolutionCache[rawLower] = cached
            return cached
        }

        // 2. Direct & canonical-prefix lookup in synced LiteLLM rates and built-in defaults
        let lookupKeys = [rawLower, cleaned, rawHyphenated, hyphenated, dotHyphenated]
        for key in lookupKeys {
            if let direct = lookupRate(forKey: key) {
                resolutionCache[rawLower] = direct
                resolutionCache[cleaned] = direct
                resolutionCache[hyphenated] = direct
                return direct
            }
        }

        // 3. Known model family pattern matching (prioritizing synced rates via lookupRate)
        let familyMatchOrder: [(patterns: [String], canonicalKey: String)] = [
            (["neon"], "gemini-4-neon"),
            (["argon", "g1-pro"], "gemini-4-argon"),
            (["hydrogen"], "gemini-4-hydrogen"),
            (["carbon"], "gemini-4-carbon"),
            (["3.8-flash", "3.8flash", "3.7-flash", "3.6-flash"], "gemini-3.8-flash"),
            (["3.5-flash"], "gemini-3.5-flash"),
            (["3-flash", "3.0-flash"], "gemini-3-flash"),
            (["2.5-flash"], "gemini-2.5-flash"),
            (["2.0-flash", "2-flash"], "gemini-2.0-flash"),
            (["1.5-flash"], "gemini-1.5-flash"),
            (["flash"], "gemini-2.5-flash"),
            (["2.5-pro"], "gemini-2.5-pro"),
            (["1.5-pro"], "gemini-1.5-pro"),
            (["pro"], "gemini-2.5-pro"),
            (["opus-5-5", "opus-5.5", "5-5-opus", "5.5-opus"], "claude-opus-5-5"),
            (["sonnet-5-5", "sonnet-5.5", "5-5-sonnet", "5.5-sonnet"], "claude-sonnet-5-5"),
            (["3-7-sonnet", "3.7-sonnet", "sonnet-3.7"], "claude-3-7-sonnet"),
            (["3-5-sonnet", "3.5-sonnet", "sonnet-3.5"], "claude-3-5-sonnet"),
            (["sonnet"], "claude-sonnet-5-5"),
            (["haiku"], "claude-3-5-haiku"),
            (["opus"], "claude-opus-5-5"),
            (["gpt-oss-120b"], "gpt-oss-120b"),
        ]

        var resolved: ModelRate? = nil
        for (patterns, canonicalKey) in familyMatchOrder {
            if patterns.contains(where: { hyphenated.contains($0) || dotHyphenated.contains($0) }) {
                resolved = lookupRate(forKey: canonicalKey)
                if resolved != nil { break }
            }
        }

        let finalRate = resolved ?? defaultFallbackRate()
        resolutionCache[rawLower] = finalRate
        resolutionCache[cleaned] = finalRate
        resolutionCache[hyphenated] = finalRate
        return finalRate
    }

    @discardableResult
    public func fetchRemotePricing() async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: litellmURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            guard parseAndApply(data: data, syncDate: Date()) else {
                return false
            }

            try? data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            // Keep using cached or default rates if offline
            return false
        }
    }

    @discardableResult
    private func parseAndApply(data: Data, syncDate: Date?) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return false
        }

        var parsedRates: [String: ModelRate] = [:]
        for (modelKey, props) in json {
            let inputCost = (props["input_cost_per_token"] as? Double) ?? 0.0
            let cacheCost = (props["cache_read_input_token_cost"] as? Double) ?? (inputCost * 0.25)
            let outputCost = (props["output_cost_per_token"] as? Double) ?? 0.0

            if inputCost > 0 || outputCost > 0 {
                parsedRates[modelKey.lowercased()] = ModelRate(
                    inputPerMillion: inputCost * 1_000_000.0,
                    cacheReadPerMillion: cacheCost * 1_000_000.0,
                    outputPerMillion: outputCost * 1_000_000.0
                )
            }
        }

        lock.lock()
        defer { lock.unlock() }

        remoteRates = parsedRates
        if let syncDate {
            _lastSyncDate = syncDate
        }
        resolutionCache.removeAll()
        return true
    }
}
