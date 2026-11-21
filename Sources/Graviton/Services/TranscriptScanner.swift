import Foundation

public final class TranscriptScanner: @unchecked Sendable {
    public static let shared = TranscriptScanner()

    private let lock = NSLock()
    private let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private struct CacheEntry {
        let mtime: Date
        let dbMtime: Date?
        let steps: [TokenStep]
        let summary: SessionSummary?
    }
    private var fileCache: [URL: CacheEntry] = [:]
    private var cacheEpoch: UInt64 = 0

    public init() {}

    private func parseDate(_ dateString: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return isoDateFormatter.date(from: dateString) ?? fallbackDateFormatter.date(from: dateString)
    }

    public func resolveBrainDirectory(customPath: String? = nil) -> URL {
        if let custom = customPath, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    public func scanAll(brainURL: URL? = nil, surface: AppSurface = .desktop) -> (steps: [TokenStep], sessions: [SessionSummary]) {
        let targetURL = brainURL ?? resolveBrainDirectory()
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return ([], [])
        }

        var allSteps: [TokenStep] = []
        var sessionSummaries: [SessionSummary] = []

        let transcriptFiles = findTranscriptFiles(in: targetURL)

        // Conversation databases live next to the brain directory (`<root>/brain` + `<root>/conversations`).
        let conversationsDir = targetURL.deletingLastPathComponent()
            .appendingPathComponent("conversations", isDirectory: true)

        for fileURL in transcriptFiles {
            let fileMtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            // The sibling DB supplies per-step models, so its changes must invalidate the cache too.
            let dbURL = conversationsDir.appendingPathComponent("\(extractSessionId(from: fileURL)).db")
            let dbMtime: Date? = FileManager.default.fileExists(atPath: dbURL.path)
                ? SQLiteConversationScanner.shared.effectiveModificationDate(for: dbURL)
                : nil

            lock.lock()
            let fileStartEpoch = cacheEpoch
            if let cached = fileCache[fileURL], cached.mtime == fileMtime, cached.dbMtime == dbMtime {
                lock.unlock()
                if !cached.steps.isEmpty {
                    allSteps.append(contentsOf: cached.steps)
                    if let summary = cached.summary {
                        sessionSummaries.append(summary)
                    }
                }
                continue
            }
            lock.unlock()

            let sessionSteps = parseTranscriptFile(fileURL: fileURL, surface: surface, conversationsDirectory: conversationsDir)
            var sessionSummary: SessionSummary? = nil
            if !sessionSteps.isEmpty {
                allSteps.append(contentsOf: sessionSteps)

                let sessionId = extractSessionId(from: fileURL)
                let latestDate = sessionSteps.map(\.date).max() ?? Date()
                let totalInput = sessionSteps.reduce(0) { $0 + $1.inputTokens }
                let totalCache = sessionSteps.reduce(0) { $0 + $1.cacheReadTokens }
                let totalOutput = sessionSteps.reduce(0) { $0 + $1.outputTokens }
                let detectedModel = sessionSteps.compactMap(\.modelName).last ?? sessionSteps.compactMap(\.modelName).first
                let cost = sessionSteps.reduce(0.0) { $0 + $1.cost }

                let summary = SessionSummary(
                    id: sessionId,
                    lastUpdated: latestDate,
                    stepCount: sessionSteps.count,
                    inputTokens: totalInput,
                    cacheReadTokens: totalCache,
                    outputTokens: totalOutput,
                    estimatedCost: cost,
                    modelName: detectedModel,
                    surface: surface
                )
                sessionSummaries.append(summary)
                sessionSummary = summary
            }

            lock.lock()
            if cacheEpoch == fileStartEpoch {
                fileCache[fileURL] = CacheEntry(mtime: fileMtime, dbMtime: dbMtime, steps: sessionSteps, summary: sessionSummary)
            }
            lock.unlock()
        }

        sessionSummaries.sort { $0.lastUpdated > $1.lastUpdated }
        allSteps.sort { $0.date > $1.date }

        return (allSteps, sessionSummaries)
    }

    private func findTranscriptFiles(in rootURL: URL) -> [URL] {
        var results: [URL] = []

        if let conversationFolders = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for folder in conversationFolders {
                let primaryTranscript = folder
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if FileManager.default.fileExists(atPath: primaryTranscript.path) {
                    results.append(primaryTranscript)
                }

                let subagentsDir = folder.appendingPathComponent("subagents")
                if let subagentFolders = try? FileManager.default.contentsOfDirectory(at: subagentsDir, includingPropertiesForKeys: nil) {
                    for subFolder in subagentFolders {
                        let subTranscript = subFolder.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                        if FileManager.default.fileExists(atPath: subTranscript.path) {
                            results.append(subTranscript)
                        }
                    }
                }
            }
        }

        return results
    }

    public func parseTranscriptFile(
        fileURL: URL,
        surface: AppSurface = .desktop,
        conversationsDirectory: URL? = nil
    ) -> [TokenStep] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let sessionId = extractSessionId(from: fileURL)

        struct RawStep {
            let stepIndex: Int
            let date: Date
            let inputTokens: Int
            let cacheReadTokens: Int
            let outputTokens: Int
            /// Model recorded on the step itself (newer transcripts).
            let explicitModel: String?
            /// Model from the latest `<USER_SETTINGS_CHANGE>` seen before this step.
            let settingsModel: String?
        }

        var rawSteps: [RawStep] = []
        var seenStepIndices = Set<Int>()
        var currentSessionModel: String? = nil

        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let hasPlanner = trimmed.contains("\"PLANNER_RESPONSE\"")
            let hasModel = trimmed.contains("<USER_SETTINGS_CHANGE>") && trimmed.contains("Model Selection")
            guard hasPlanner || hasModel else { return }

            guard let jsonData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
                return
            }

            if hasModel,
               let type = obj["type"] as? String, type == "USER_INPUT",
               let userSettings = obj["content"] as? String {
                if let match = self.extractModelFromContent(userSettings) {
                    currentSessionModel = match
                }
            }

            guard hasPlanner, let type = obj["type"] as? String, type == "PLANNER_RESPONSE" else {
                return
            }

            let stepIndex = (obj["step_index"] as? Int) ?? 0
            guard !seenStepIndices.contains(stepIndex) else { return }
            seenStepIndices.insert(stepIndex)

            let inputTokens = (obj["input_tokens"] as? Int) ?? 0
            let cacheReadTokens = (obj["cache_read_tokens"] as? Int) ?? 0
            let outputTokens = (obj["output_tokens"] as? Int) ?? 0

            guard (inputTokens + cacheReadTokens + outputTokens) > 0 else { return }

            let dateString = obj["created_at"] as? String
            let date = dateString.flatMap { self.parseDate($0) } ?? Date()

            rawSteps.append(RawStep(
                stepIndex: stepIndex,
                date: date,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                outputTokens: outputTokens,
                explicitModel: Self.validModelName((obj["model"] as? String)),
                settingsModel: currentSessionModel
            ))
        }

        // Older transcripts do not record the model per step. The sibling SQLite database does, so
        // recover it from there for every step that lacks an explicit model.
        var databaseModels = [String?](repeating: nil, count: rawSteps.count)
        if let conversationsDirectory,
           rawSteps.contains(where: { $0.explicitModel == nil }) {
            let dbURL = conversationsDirectory.appendingPathComponent("\(sessionId).db")
            if FileManager.default.fileExists(atPath: dbURL.path) {
                let rows = SQLiteConversationScanner.shared.readStepModels(dbURL: dbURL)
                databaseModels = StepModelAligner.align(
                    steps: rawSteps.map { ($0.inputTokens, $0.cacheReadTokens) },
                    rows: rows
                ).map { Self.validModelName($0) }
            }
        }

        var steps: [TokenStep] = []
        steps.reserveCapacity(rawSteps.count)
        for (index, raw) in rawSteps.enumerated() {
            // Priority: model on the step > per-step model from SQLite > session-level setting.
            let stepModel = raw.explicitModel ?? databaseModels[index] ?? raw.settingsModel

            let rate = PricingService.shared.rateFor(modelName: stepModel)
            let stepCost = rate.calculateCost(
                input: raw.inputTokens,
                cacheRead: raw.cacheReadTokens,
                output: raw.outputTokens
            )

            steps.append(TokenStep(
                stepIndex: raw.stepIndex,
                sessionId: sessionId,
                date: raw.date,
                inputTokens: raw.inputTokens,
                cacheReadTokens: raw.cacheReadTokens,
                outputTokens: raw.outputTokens,
                cost: stepCost,
                modelName: stepModel,
                surface: surface
            ))
        }

        return steps
    }

    /// Returns the trimmed name when it looks like a real model identifier, otherwise `nil`.
    private static func validModelName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              ModelFormatter.isValidModelName(ModelFormatter.stripEffortSuffix(from: trimmed)) else {
            return nil
        }
        return trimmed
    }

    public func clearCache() {
        lock.lock()
        cacheEpoch &+= 1
        fileCache.removeAll()
        lock.unlock()
    }

    private func extractSessionId(from fileURL: URL) -> String {
        let components = fileURL.pathComponents
        if let logsIdx = components.lastIndex(of: "logs"), logsIdx >= 2 {
            return components[logsIdx - 2]
        }
        return fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }

    public func extractModelFromContent(_ text: String) -> String? {
        guard text.contains("Model Selection") else { return nil }

        let targetText: String
        if let startTag = text.range(of: "<USER_SETTINGS_CHANGE>"),
           let endTag = text.range(of: "</USER_SETTINGS_CHANGE>") {
            targetText = String(text[startTag.upperBound..<endTag.lowerBound])
        } else if text.contains("The user changed setting `Model Selection`") {
            targetText = text
        } else {
            return nil
        }

        guard let range = targetText.range(of: "Model Selection` from") else { return nil }
        let after = targetText[range.upperBound...]
        guard let toRange = after.range(of: "to ") else { return nil }
        var candidate = String(after[toRange.upperBound...])

        if let firstLine = candidate.components(separatedBy: "\n").first {
            candidate = firstLine
        }

        if let dotSpaceRange = candidate.range(of: ". ") {
            candidate = String(candidate[..<dotSpaceRange.lowerBound])
        } else if candidate.hasSuffix(".") {
            candidate = String(candidate.dropLast())
        }

        let trimmed = ModelFormatter.stripEffortSuffix(from: candidate)
        guard isValidModelName(trimmed) else { return nil }
        return trimmed
    }

    public func isValidModelName(_ name: String) -> Bool {
        ModelFormatter.isValidModelName(name)
    }
}
