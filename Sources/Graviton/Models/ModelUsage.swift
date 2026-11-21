import Foundation
import SwiftUI

public struct ModelUsage: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let provider: String
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let estimatedCost: Double
    public let stepCount: Int
    public let sessionCount: Int
    public let percentageOfTotal: Double
    public let cacheHitPercentage: Double
    public let rate: ModelRate
    public let color: Color
    public let quotaGroup: QuotaGroup?

    public var fiveHourQuota: QuotaBucket? { quotaGroup?.fiveHourBucket }
    public var weeklyQuota: QuotaBucket? { quotaGroup?.weeklyBucket }

    public init(
        id: String,
        displayName: String,
        provider: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        estimatedCost: Double,
        stepCount: Int,
        sessionCount: Int,
        percentageOfTotal: Double,
        cacheHitPercentage: Double,
        rate: ModelRate,
        color: Color,
        quotaGroup: QuotaGroup? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.stepCount = stepCount
        self.sessionCount = sessionCount
        self.percentageOfTotal = percentageOfTotal
        self.cacheHitPercentage = cacheHitPercentage
        self.rate = rate
        self.color = color
        self.quotaGroup = quotaGroup
    }
}

public struct ModelFormatter: Sendable {
    private static let trailingVariantTokens: Set<String> = ["low", "medium", "high", "xhigh", "max", "tiered"]

    /// Strips trailing effort/tier markers like "(High)", "(XHigh)", "-xhigh", "-medium", "-tiered"
    /// while preserving non-effort parenthetical identifiers like "Orchestrator (Neon)".
    public static func stripEffortSuffix(from name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing "(Low|Medium|High|XHigh|Max|Tiered)"
        if result.hasSuffix(")"), let openIdx = result.lastIndex(of: "(") {
            let inside = result[result.index(after: openIdx)..<result.index(before: result.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if trailingVariantTokens.contains(inside) {
                result = String(result[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip trailing effort/tier/experiment markers (including combinations), e.g.
        // "-high", "-xhigh", "-tiered", "-exp-a", "-trial" and the single-letter "-n"/"-e"/"-a" variants.
        var strippedAny = true
        while strippedAny {
            strippedAny = false
            let lower = result.lowercased()
            if let stripped = strippedOneSuffix(from: result, lowercased: lower) {
                result = stripped
                strippedAny = true
            }
        }

        return result
    }

    private static let experimentalSuffixes = ["-exp-a", "-exp-b", "-trial", "-agent"]
    private static let singleLetterSuffixes = ["-n", "-e", "-a"]
    private static let knownVariantBases: Set<String> = [
        "gemini-4-neon", "gemini-4-argon", "gemini-4-hydrogen", "gemini-4-carbon",
        "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
        "gemini-3-flash", "gemini-2.5-flash"
    ]

    private static func strippedOneSuffix(from result: String, lowercased lower: String) -> String? {
        for token in trailingVariantTokens {
            let suffix = "-\(token)"
            if lower.hasSuffix(suffix), result.count > suffix.count {
                return String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard lower.hasPrefix("gemini-") else { return nil }
        for suffix in experimentalSuffixes where lower.hasSuffix(suffix) && result.count > suffix.count {
            return String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Single letters are only safe to drop from well-known model bases (e.g. "gemini-3.8-flash-n").
        for suffix in singleLetterSuffixes where lower.hasSuffix(suffix) {
            let base = String(lower.dropLast(suffix.count))
            if knownVariantBases.contains(base) {
                return String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Maps known orchestrator/worker identifiers to the display name of the model family they are billed as.
    /// - Neon orchestrator stays separate; the Argon orchestrator is grouped with Gemini 4 Argon;
    ///   the execution worker belongs to the Gemini 4 Hydrogen family.
    private static func orchestratorDisplayName(for lowercased: String) -> String? {
        switch lowercased {
        case "gemini-pro-orchestrator-neon", "orchestrator (neon)", "orchestrator-neon", "orchestrator neon":
            return "Orchestrator (Neon)"
        case "gemini-pro-orchestrator-g1-pro", "orchestrator (argon)", "orchestrator-argon", "orchestrator argon":
            return "Gemini 4 Argon"
        case "gemini-flash-worker-agy", "gemini-flash-worker", "gemini flash worker":
            return "Gemini 4 Hydrogen"
        default:
            return nil
        }
    }

    public static func isValidModelName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 && trimmed.count <= 60 else { return false }

        if orchestratorDisplayName(for: trimmed.lowercased()) != nil {
            return true
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-. _"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let forbidden = ["{", "}", "(", ")", ";", "\"", "'", "[", "]", "return", "nil", "else", "guard", "let", "var", "func", "import", "class", "struct", "enum"]
        let lower = trimmed.lowercased()
        for bad in forbidden {
            if lower.contains(bad) { return false }
        }
        return true
    }

    public static func displayName(for rawName: String?) -> String {
        guard let raw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Gemini Flash (Default)"
        }
        let cleaned = stripEffortSuffix(from: raw)
        if let orchName = orchestratorDisplayName(for: cleaned.lowercased()) {
            return orchName
        }

        guard isValidModelName(cleaned) else {
            return "Gemini Flash (Default)"
        }

        let lower = cleaned.lowercased()
        switch lower {
        case "gemini-4-neon", "gemini 4 neon":
            return "Gemini 4 Neon"
        case "gemini-4-argon", "gemini 4 argon":
            return "Gemini 4 Argon"
        case "gemini-4-hydrogen", "gemini 4 hydrogen":
            return "Gemini 4 Hydrogen"
        case "gemini-4-carbon", "gemini 4 carbon":
            return "Gemini 4 Carbon"
        case "gemini-3.8-flash", "gemini 3.8 flash":
            return "Gemini 3.8 Flash"
        case "gemini-3.7-flash", "gemini 3.7 flash":
            return "Gemini 3.7 Flash"
        case "gemini-3.6-flash", "gemini 3.6 flash":
            return "Gemini 3.6 Flash"
        case "gemini-3-flash", "gemini 3 flash":
            return "Gemini 3 Flash"
        case "gemini-2.5-flash", "gemini 2.5 flash":
            return "Gemini 2.5 Flash"
        case "gemini-2.0-flash", "gemini 2.0 flash":
            return "Gemini 2.0 Flash"
        case "gemini-1.5-flash", "gemini 1.5 flash":
            return "Gemini 1.5 Flash"
        case "gemini-flash", "gemini flash":
            return "Gemini Flash"
        case "gemini-2.5-pro", "gemini 2.5 pro":
            return "Gemini 2.5 Pro"
        case "gemini-1.5-pro", "gemini 1.5 pro":
            return "Gemini 1.5 Pro"
        case "gemini-pro", "gemini pro":
            return "Gemini Pro"
        case "claude-opus-5-5", "claude-opus-5.5", "claude opus 5.5":
            return "Claude Opus 5.5"
        case "claude-sonnet-5-5", "claude-sonnet-5.5", "claude sonnet 5.5":
            return "Claude Sonnet 5.5"
        case "claude-3-7-sonnet", "claude 3.7 sonnet", "claude sonnet 3.7":
            return "Claude 3.7 Sonnet"
        case "claude-3-5-sonnet", "claude 3.5 sonnet", "claude sonnet 3.5":
            return "Claude 3.5 Sonnet"
        case "claude-3-5-haiku", "claude 3.5 haiku":
            return "Claude 3.5 Haiku"
        case "claude-3-opus", "claude 3 opus":
            return "Claude 3 Opus"
        case "gpt-oss-120b", "gpt oss 120b":
            return "GPT-OSS 120B"
        default:
            return cleaned
        }
    }

    public static func canonicalId(for rawName: String?) -> String {
        let display = displayName(for: rawName)
        return display.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    public static func color(for displayName: String) -> Color {
        let lower = displayName.lowercased()
        if lower.contains("neon") { return Color.indigo }
        if lower.contains("argon") { return Color.purple }
        if lower.contains("hydrogen") { return Color.teal }
        if lower.contains("3.8") { return Color.cyan }
        if lower.contains("pro") { return Color.purple }
        if lower.contains("opus") { return Color.red }
        if lower.contains("haiku") { return Color.yellow }
        if lower.contains("claude") || lower.contains("sonnet") { return Color.orange }
        if lower.contains("gpt") { return Color.green }
        if lower.contains("flash") { return Color.blue }
        return Color.teal
    }

    public static func provider(for displayName: String) -> String {
        let lower = displayName.lowercased()
        if lower.contains("gemini") || lower.contains("orchestrator") || lower.contains("neon") || lower.contains("argon") || lower.contains("hydrogen") {
            return "Google"
        }
        if lower.contains("claude") { return "Anthropic" }
        if lower.contains("gpt") || lower.contains("o1") || lower.contains("o3") { return "OpenAI" }
        return "AI"
    }
}
