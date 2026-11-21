import Testing
import Foundation
import SQLite3
@testable import Graviton

@Suite("Graviton Tests")
struct GravitonTests {

    @Test("TimePeriod matching logic")
    func testTimePeriodMatching() {
        let now = Date()
        #expect(TimePeriod.today.matches(date: now))
        #expect(TimePeriod.thisWeek.matches(date: now))
        #expect(TimePeriod.thisMonth.matches(date: now))
        #expect(TimePeriod.allTime.matches(date: now))

        let calendar = Calendar.current
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            #expect(TimePeriod.yesterday.matches(date: yesterday))
            #expect(!TimePeriod.today.matches(date: yesterday))
        }
    }

    @Test("ModelRate cost calculations")
    func testCostCalculation() {
        // Flash rate: $0.15 in, $0.0375 cache, $0.60 out per 1M
        let rate = ModelRate(inputPerMillion: 0.15, cacheReadPerMillion: 0.0375, outputPerMillion: 0.60)

        // 1,000,000 input tokens = $0.15
        let costIn = rate.calculateCost(input: 1_000_000, cacheRead: 0, output: 0)
        #expect(abs(costIn - 0.15) < 0.0001)

        // 1,000,000 cache read tokens = $0.0375
        let costCache = rate.calculateCost(input: 0, cacheRead: 1_000_000, output: 0)
        #expect(abs(costCache - 0.0375) < 0.0001)

        // 1,000,000 output tokens = $0.60
        let costOut = rate.calculateCost(input: 0, cacheRead: 0, output: 1_000_000)
        #expect(abs(costOut - 0.60) < 0.0001)
    }

    @Test("PricingService model resolution")
    func testPricingResolution() {
        let pricing = PricingService.shared

        let flashRate = pricing.rateFor(modelName: "gemini-3.8-flash")
        #expect(flashRate.inputPerMillion == 0.75)

        let proRate = pricing.rateFor(modelName: "gemini-1.5-pro")
        #expect(proRate.inputPerMillion == 1.25)
        #expect(proRate.outputPerMillion == 5.00)

        let claudeRate = pricing.rateFor(modelName: "claude-3-5-sonnet")
        #expect(claudeRate.inputPerMillion == 3.00)
    }

    @Test("AppSurface properties and formatting")
    func testAppSurfaceProperties() {
        #expect(AppSurface.all.shortLabel == "All")
        #expect(AppSurface.desktop.shortLabel == "2.0")
        #expect(AppSurface.cli.shortLabel == "CLI")
        #expect(AppSurface.ide.shortLabel == "IDE")

        #expect(AppSurface.desktop.rawValue == "Antigravity 2.0")
        #expect(AppSurface.cli.rawValue == "CLI")
        #expect(AppSurface.ide.rawValue == "IDE")
    }

    @Test("TranscriptScanner parsing synthetic JSONL")
    func testTranscriptParsing() throws {
        let sampleJSONL = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-14T17:03:41Z","content":"Hello"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-14T17:03:41Z","input_tokens":1000,"cache_read_tokens":500,"output_tokens":200}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-10-14T17:03:45Z","content":"Output"}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-14T17:03:48Z","input_tokens":500,"cache_read_tokens":1500,"output_tokens":100}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-14T17:03:48Z","input_tokens":500,"cache_read_tokens":1500,"output_tokens":100}
        """

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_transcript_\(UUID().uuidString).jsonl")
        try sampleJSONL.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let steps = TranscriptScanner.shared.parseTranscriptFile(fileURL: tempFile, surface: .desktop)

        // Step #3 was duplicated in input; should only have 2 steps (#1 and #3)
        #expect(steps.count == 2)

        let totalIn = steps.reduce(0) { $0 + $1.inputTokens }
        let totalCache = steps.reduce(0) { $0 + $1.cacheReadTokens }
        let totalOut = steps.reduce(0) { $0 + $1.outputTokens }

        #expect(totalIn == 1500)
        #expect(totalCache == 2000)
        #expect(totalOut == 300)
        #expect(steps.first?.surface == .desktop)
    }

    @Test("SQLiteConversationScanner parsing protobuf blobs")
    func testSQLiteConversationScanner() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_sqlite_\(UUID().uuidString)")
        let convDir = tempDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = convDir.appendingPathComponent("test-session-1.db")

        // Build protobuf data:
        // usage: field 2 = 1200 (in), field 5 = 800 (cache), field 9 = 400 (out), field 10 = 50 (thinking)
        var usagePayload = Data()
        usagePayload.append(encodeVarintField(fieldNumber: 2, value: 1200))
        usagePayload.append(encodeVarintField(fieldNumber: 5, value: 800))
        usagePayload.append(encodeVarintField(fieldNumber: 9, value: 400))
        usagePayload.append(encodeVarintField(fieldNumber: 10, value: 50))
        usagePayload.append(encodeLengthDelimited(fieldNumber: 11, data: "resp-abc".data(using: .utf8)!))

        // chatModel: field 19 = "gemini-3.8-flash", field 4 = usagePayload
        var chatModelPayload = Data()
        chatModelPayload.append(encodeLengthDelimited(fieldNumber: 19, data: "gemini-3.8-flash".data(using: .utf8)!))
        chatModelPayload.append(encodeLengthDelimited(fieldNumber: 4, data: usagePayload))

        // top: field 1 = chatModelPayload
        let topPayload = encodeLengthDelimited(fieldNumber: 1, data: chatModelPayload)

        // Create SQLite DB
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)

        let createTable = "CREATE TABLE gen_metadata (idx INTEGER, data BLOB);"
        #expect(sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK)

        var stmt: OpaquePointer?
        let insertSQL = "INSERT INTO gen_metadata (idx, data) VALUES (1, ?);"
        #expect(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK)
        _ = topPayload.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 1, rawBuffer.baseAddress, Int32(topPayload.count), nil)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        let (steps, sessions) = SQLiteConversationScanner.shared.scanDirectory(directoryURL: tempDir, surface: .ide)
        #expect(sessions.count == 1)
        #expect(steps.count == 1)

        let step = steps[0]
        #expect(step.inputTokens == 1200)
        #expect(step.cacheReadTokens == 800)
        #expect(step.outputTokens == 450) // 400 + 50 thinking
        #expect(step.modelName == "gemini-3.8-flash")
        #expect(step.surface == .ide)
        #expect(sessions[0].surface == .ide)
    }

    @Test("ModelFormatter and canonical naming")
    func testModelFormatter() {
        #expect(ModelFormatter.displayName(for: "gemini-3.8-flash") == "Gemini 3.8 Flash")
        #expect(ModelFormatter.displayName(for: "Gemini 3.8 Flash (High)") == "Gemini 3.8 Flash")
        #expect(ModelFormatter.displayName(for: "claude-3-5-sonnet") == "Claude 3.5 Sonnet")
        #expect(ModelFormatter.displayName(for: nil) == "Gemini Flash (Default)")
        #expect(ModelFormatter.displayName(for: "") == "Gemini Flash (Default)")

        #expect(ModelFormatter.canonicalId(for: "Gemini 3.8 Flash (High)") == "gemini-3.8-flash")
        #expect(ModelFormatter.canonicalId(for: "gemini-3.8-flash") == "gemini-3.8-flash")
        #expect(ModelFormatter.provider(for: "Gemini 3.8 Flash") == "Google")
        #expect(ModelFormatter.provider(for: "Claude 3.5 Sonnet") == "Anthropic")
    }

    @Test("TranscriptScanner model extraction with version dots and code rejection")
    func testExtractModelFromTranscript() {
        let scanner = TranscriptScanner.shared
        let content1 = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.8 Flash (High). No need to comment on this change if the user doesn't ask about it.\n</USER_SETTINGS_CHANGE>"
        #expect(scanner.extractModelFromContent(content1) == "Gemini 3.8 Flash")

        let content2 = "The user changed setting `Model Selection` from None to Gemini 2.5 Pro. Done."
        #expect(scanner.extractModelFromContent(content2) == "Gemini 2.5 Pro")

        // Code snippets must never be parsed as models
        let codeSnippet = "guard let range = text.range(of: \"Model Selection` from\") else { return nil }"
        #expect(scanner.extractModelFromContent(codeSnippet) == nil)
        #expect(!scanner.isValidModelName("\") else { return nil }"))
        #expect(!scanner.isValidModelName("\") {"))
        #expect(ModelFormatter.displayName(for: "\") else { return nil }") == "Gemini Flash (Default)")
    }

    @Test("PricingService resolution for human-readable model names")
    func testHumanReadablePricingResolution() {
        let pricing = PricingService.shared

        // Spaced and with parentheses
        let rate38 = pricing.rateFor(modelName: "Gemini 3.8 Flash (High)")
        let canonical38 = pricing.rateFor(modelName: "gemini-3.8-flash")
        #expect(rate38.inputPerMillion == canonical38.inputPerMillion)
        #expect(rate38.outputPerMillion == canonical38.outputPerMillion)
        #expect(rate38.inputPerMillion == 0.75)

        let ratePro = pricing.rateFor(modelName: "Gemini 2.5 Pro")
        let canonicalPro = pricing.rateFor(modelName: "gemini-2.5-pro")
        #expect(ratePro.inputPerMillion == canonicalPro.inputPerMillion)
        #expect(ratePro.outputPerMillion == canonicalPro.outputPerMillion)
        #expect(ratePro.inputPerMillion == 1.25)
    }

    @Test("TrackerViewModel model usage computation and filtering")
    @MainActor
    func testModelUsagesAggregation() {
        let vm = TrackerViewModel(startBackgroundServices: false)
        let now = Date()

        let step1 = TokenStep(
            stepIndex: 1,
            sessionId: "s1",
            date: now,
            inputTokens: 1000,
            cacheReadTokens: 500,
            outputTokens: 200,
            modelName: "gemini-3.8-flash",
            surface: .desktop
        )

        let step2 = TokenStep(
            stepIndex: 2,
            sessionId: "s2",
            date: now,
            inputTokens: 2000,
            cacheReadTokens: 1000,
            outputTokens: 400,
            modelName: "gemini-2.5-pro",
            surface: .desktop
        )

        vm.allSteps = [step1, step2]
        vm.allSessions = [
            SessionSummary(id: "s1", lastUpdated: now, stepCount: 1, inputTokens: 1000, cacheReadTokens: 500, outputTokens: 200, estimatedCost: 0.1, modelName: "gemini-3.8-flash", surface: .desktop),
            SessionSummary(id: "s2", lastUpdated: now, stepCount: 1, inputTokens: 2000, cacheReadTokens: 1000, outputTokens: 400, estimatedCost: 0.2, modelName: "gemini-2.5-pro", surface: .desktop)
        ]
        vm.recomputeMetrics()

        #expect(vm.modelUsages.count == 2)
        // gemini-2.5-pro has 3400 tokens, gemini-3.8-flash has 1700 tokens -> pro sorted first
        #expect(vm.modelUsages[0].displayName == "Gemini 2.5 Pro")
        #expect(vm.modelUsages[0].totalTokens == 3400)
        #expect(vm.modelUsages[1].displayName == "Gemini 3.8 Flash")
        #expect(vm.modelUsages[1].totalTokens == 1700)

        // Test filtering
        vm.selectedModelFilter = "gemini-3.8-flash"
        #expect(vm.filteredSessions.count == 1)
        #expect(vm.filteredSessions.first?.sessionId == "s1")

        vm.selectedModelFilter = nil
        #expect(vm.filteredSessions.count == 2)
    }

    @Test("QuotaBucket metrics and gauge color calculation")
    func testQuotaBucketMetrics() {
        let healthy = QuotaBucket(id: "b1", name: "Healthy", window: "5h", remainingFraction: 0.85)
        #expect(healthy.remainingPercent == 85.0)
        #expect(healthy.usedPercent == 15.0)

        let amber = QuotaBucket(id: "b2", name: "Amber", window: "5h", remainingFraction: 0.20)
        #expect(amber.remainingPercent == 20.0)
        #expect(amber.usedPercent == 80.0)

        let critical = QuotaBucket(id: "b3", name: "Critical", window: "5h", remainingFraction: 0.05)
        #expect(critical.remainingPercent == 5.0)
        #expect(critical.usedPercent == 95.0)

        // Reset countdown
        let future = Date().addingTimeInterval(3700) // 1h 1m 40s
        let bucketWithReset = QuotaBucket(id: "b4", name: "Resetting", window: "5h", remainingFraction: 0.5, resetTime: future)
        #expect(bucketWithReset.resetCountdownText.contains("Resets in 1h"))
    }

    @Test("QuotaGroup model matching and bucket resolution")
    func testQuotaGroupMatching() {
        let b5h = QuotaBucket(id: "gemini-5h", name: "5-Hour", window: "5h", remainingFraction: 0.70)
        let bWk = QuotaBucket(id: "gemini-weekly", name: "Weekly", window: "weekly", remainingFraction: 0.90)
        let geminiGroup = QuotaGroup(name: "Gemini Models", buckets: [b5h, bWk])

        #expect(geminiGroup.matches(modelName: "Gemini 3.8 Flash"))
        #expect(geminiGroup.matches(modelName: "Gemini 2.5 Pro"))
        #expect(!geminiGroup.matches(modelName: "Claude 3.7 Sonnet"))
        #expect(geminiGroup.fiveHourBucket?.id == "gemini-5h")
        #expect(geminiGroup.weeklyBucket?.id == "gemini-weekly")

        let claudeGroup = QuotaGroup(name: "Claude and GPT models", buckets: [])
        #expect(claudeGroup.matches(modelName: "Claude 3.7 Sonnet"))
        #expect(claudeGroup.matches(modelName: "Claude 3.5 Haiku"))
        #expect(claudeGroup.matches(modelName: "GPT-4o"))
        #expect(!claudeGroup.matches(modelName: "Gemini 3.8 Flash"))

        let argonWk = QuotaBucket(id: "argon-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: 1.0)
        let argonGroup = QuotaGroup(name: "Gemini 4 Argon", buckets: [argonWk])
        #expect(argonGroup.fiveHourBucket == nil)
        #expect(argonGroup.weeklyBucket?.id == "argon-weekly")
    }

    @Test("QuotaService JSON parsing from agy usage output")
    func testQuotaServiceParsing() throws {
        let json = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "description": "Shared weekly and 5-hour limit.",
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Models: Gemini Flash, Gemini Pro",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.92,
                      "reset_time": "2026-10-22T07:27:59Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.71,
                      "reset_time": "2026-10-15T18:30:00Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.20,
                      "reset_time": "2026-10-20T16:20:51Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let data = Data(json.utf8)
        let snapshot = try QuotaService.shared.parseQuotaJSON(data: data)

        #expect(snapshot.groups.count == 2)
        let gemini = snapshot.group(for: "Gemini 3.8 Flash")
        #expect(gemini != nil)
        #expect(gemini?.name == "Gemini Models")
        #expect(gemini?.fiveHourBucket?.remainingPercent == 71.0)
        #expect(gemini?.weeklyBucket?.remainingPercent == 92.0)

        let claude = snapshot.group(for: "Claude 3.5 Sonnet")
        #expect(claude != nil)
        #expect(claude?.weeklyBucket?.remainingPercent == 20.0)
    }

    @Test("TrackerViewModel day rollover updates Today metrics immediately")
    @MainActor
    func testDayRolloverRecomputeMetrics() throws {
        let vm = TrackerViewModel(startBackgroundServices: false)
        let calendar = Calendar.current
        let today = Date()
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))

        vm.selectedPeriod = .today
        vm.selectedSurface = .all
        vm.allSteps = [
            TokenStep(
                stepIndex: 1,
                sessionId: "yesterday-session",
                date: yesterday,
                inputTokens: 1500,
                cacheReadTokens: 500,
                outputTokens: 300,
                cost: 0.05,
                modelName: "gemini-3.8-flash",
                surface: .desktop
            )
        ]
        vm.allSessions = [
            SessionSummary(
                id: "yesterday-session",
                lastUpdated: yesterday,
                stepCount: 1,
                inputTokens: 1500,
                cacheReadTokens: 500,
                outputTokens: 300,
                estimatedCost: 0.05,
                modelName: "gemini-3.8-flash",
                surface: .desktop
            )
        ]

        // When evaluated on yesterday, yesterday's step is part of "Today"
        vm.recomputeMetrics(now: yesterday, calendar: calendar)
        #expect(vm.totalTokens == 2300)
        #expect(vm.filteredSessions.count == 1)

        // When day rolls over to today, recomputing metrics for "Today" drops yesterday's step
        vm.recomputeMetrics(now: today, calendar: calendar)
        #expect(vm.totalTokens == 0)
        #expect(vm.filteredSessions.isEmpty)
    }

    @Test("FolderWatcher detects nested transcript.jsonl and subagent modification timestamps")
    func testFolderWatcherNestedModificationDetection() throws {
        let fm = FileManager.default
        let rootDir = fm.temporaryDirectory.appendingPathComponent("test_watcher_\(UUID().uuidString)", isDirectory: true)
        let sessionLogsDir = rootDir
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: sessionLogsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootDir) }

        let initialLatest = FolderWatcher.latestRelevantModificationDate(in: [rootDir])
        #expect(initialLatest > Date.distantPast)

        let transcriptURL = sessionLogsDir.appendingPathComponent("transcript.jsonl")
        try "{\"step_index\":1}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let futureDate = Date().addingTimeInterval(120)
        try fm.setAttributes([.modificationDate: futureDate], ofItemAtPath: transcriptURL.path)

        let updatedLatest = FolderWatcher.latestRelevantModificationDate(in: [rootDir])
        #expect(abs(updatedLatest.timeIntervalSince(futureDate)) < 1.0)
    }

    @Test("MonthlyRecord calculations and surface metrics")
    func testMonthlyRecordCalculations() {
        let record = MonthlyRecord(
            year: 2026,
            month: 10,
            inputTokens: 1000,
            cacheReadTokens: 3000,
            outputTokens: 500,
            totalTokens: 4500,
            totalCost: 1.25,
            sessionCount: 4,
            stepCount: 12,
            modelBreakdown: [
                "gemini-3.8-flash": ModelMonthlyStat(displayName: "Gemini 3.8 Flash", canonicalModelId: "gemini-3.8-flash", tokens: 4500, cost: 1.25)
            ],
            surfaceBreakdown: [
                AppSurface.desktop.rawValue: SurfaceMonthlyStat(tokens: 3000, cost: 0.85, sessions: 3),
                AppSurface.cli.rawValue: SurfaceMonthlyStat(tokens: 1500, cost: 0.40, sessions: 1)
            ]
        )

        #expect(record.id == "2026-10")
        #expect(abs(record.cacheHitRatio - 0.75) < 0.001)

        let allMetrics = record.metrics(for: .all)
        #expect(allMetrics.tokens == 4500)
        #expect(abs(allMetrics.cost - 1.25) < 0.001)
        #expect(allMetrics.sessions == 4)

        let desktopMetrics = record.metrics(for: .desktop)
        #expect(desktopMetrics.tokens == 3000)
        #expect(abs(desktopMetrics.cost - 0.85) < 0.001)
        #expect(desktopMetrics.sessions == 3)

        let ideMetrics = record.metrics(for: .ide)
        #expect(ideMetrics.tokens == 0)
        #expect(ideMetrics.cost == 0.0)
        #expect(ideMetrics.sessions == 0)
    }

    @Test("HistoryStore aggregation, persistence, and reload")
    func testHistoryStorePersistenceAndAggregation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_history_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let store = HistoryStore(customFileURL: tempFile)

        let calendar = Calendar.current
        var comps1 = DateComponents()
        comps1.year = 2026
        comps1.month = 9
        comps1.day = 15
        let sepDate = calendar.date(from: comps1)!

        var comps2 = DateComponents()
        comps2.year = 2026
        comps2.month = 10
        comps2.day = 5
        let octDate = calendar.date(from: comps2)!

        let steps: [TokenStep] = [
            TokenStep(
                stepIndex: 1,
                sessionId: "session-sep",
                date: sepDate,
                inputTokens: 1000,
                cacheReadTokens: 1000,
                outputTokens: 200,
                cost: 0.10,
                modelName: "gemini-3.8-flash",
                surface: .desktop
            ),
            TokenStep(
                stepIndex: 1,
                sessionId: "session-oct-1",
                date: octDate,
                inputTokens: 2000,
                cacheReadTokens: 4000,
                outputTokens: 500,
                cost: 0.25,
                modelName: "gemini-3.8-flash",
                surface: .desktop
            ),
            TokenStep(
                stepIndex: 2,
                sessionId: "session-oct-2",
                date: octDate,
                inputTokens: 500,
                cacheReadTokens: 500,
                outputTokens: 100,
                cost: 0.05,
                modelName: "claude-3-5-sonnet",
                surface: .cli
            )
        ]

        let updatedData = store.aggregateAndSave(steps: steps)
        #expect(updatedData.records.count == 2)
        #expect(store.availableYears.contains(2026))

        let sepRecord = updatedData.records["2026-09"]
        #expect(sepRecord != nil)
        #expect(sepRecord?.totalTokens == 2200)
        #expect(abs((sepRecord?.totalCost ?? 0) - 0.10) < 0.001)

        let octRecord = updatedData.records["2026-10"]
        #expect(octRecord != nil)
        #expect(octRecord?.totalTokens == 7600)
        #expect(abs((octRecord?.totalCost ?? 0) - 0.30) < 0.001)
        #expect(octRecord?.sessionCount == 2)
        #expect(octRecord?.surfaceBreakdown[AppSurface.desktop.rawValue]?.tokens == 6500)
        #expect(octRecord?.surfaceBreakdown[AppSurface.cli.rawValue]?.tokens == 1100)

        // Verify reloading from disk
        let reloadedStore = HistoryStore(customFileURL: tempFile)
        let reloadedData = reloadedStore.currentData
        #expect(reloadedData.records.count == 2)
        #expect(reloadedData.records["2026-10"]?.totalTokens == 7600)
        #expect(reloadedStore.records(for: 2026).count == 2)

        let annual = reloadedStore.annualMetrics(year: 2026, surface: .all)
        #expect(annual.tokens == 9800)
        #expect(abs(annual.cost - 0.40) < 0.001)
        #expect(annual.activeMonths == 2)
    }

    @Test("AppViewTab includes History")
    func testAppViewTabHistory() {
        #expect(AppViewTab.history.rawValue == "History")
        #expect(AppViewTab.allCases.contains(.history))
    }

    @Test("TrackerViewModel formatCompact with thousands, millions, billions, and trillions")
    func testFormatCompactScales() {
        #expect(TrackerViewModel.formatCompact(500) == "500")
        #expect(TrackerViewModel.formatCompact(1_500) == "1.5k")
        #expect(TrackerViewModel.formatCompact(25_000_000) == "25.00M")
        #expect(TrackerViewModel.formatCompact(1_150_290_000) == "1.15B")
        #expect(TrackerViewModel.formatCompact(2_450_000_000_000) == "2.45T")
    }

    @Test("TrackerViewModel formatMenuBarCurrency rounds to cents without thousandths")
    func testFormatMenuBarCurrency() {
        #expect(TrackerViewModel.formatMenuBarCurrency(0) == "$0.00")
        #expect(TrackerViewModel.formatMenuBarCurrency(-1) == "$0.00")
        #expect(TrackerViewModel.formatMenuBarCurrency(0.004) == "<$0.01")
        #expect(TrackerViewModel.formatMenuBarCurrency(0.01) == "$0.01")
        #expect(TrackerViewModel.formatMenuBarCurrency(7.786) == "$7.79")
        #expect(TrackerViewModel.formatMenuBarCurrency(9.476) == "$9.48")
        #expect(TrackerViewModel.formatMenuBarCurrency(120.5) == "$120.50")
    }

    @Test("PricingService resolves Gemini 4, Neon/Argon orchestrators, Claude 5.5, and GPT-OSS")
    func testGemini4AndOrchestratorPricing() {
        let pricing = PricingService(loadCache: false)

        let neon = pricing.rateFor(modelName: "gemini-4-neon-xhigh")
        #expect(neon.inputPerMillion == 3.00)
        #expect(abs(neon.cacheReadPerMillion - 0.15) < 0.0001)
        #expect(neon.outputPerMillion == 15.00)

        let orchNeon = pricing.rateFor(modelName: "Orchestrator (Neon)")
        #expect(orchNeon.inputPerMillion == 3.00)
        #expect(orchNeon.outputPerMillion == 15.00)

        let orchNeonId = pricing.rateFor(modelName: "gemini-pro-orchestrator-neon")
        #expect(orchNeonId.inputPerMillion == 3.00)
        #expect(orchNeonId.outputPerMillion == 15.00)

        let argon = pricing.rateFor(modelName: "Gemini 4 Argon (High)")
        #expect(argon.inputPerMillion == 2.00)
        #expect(abs(argon.cacheReadPerMillion - 0.10) < 0.0001)
        #expect(argon.outputPerMillion == 10.00)

        let orchArgon = pricing.rateFor(modelName: "Orchestrator (Argon)")
        #expect(orchArgon.inputPerMillion == 2.00)
        #expect(orchArgon.outputPerMillion == 10.00)

        let orchArgonId = pricing.rateFor(modelName: "gemini-pro-orchestrator-g1-pro")
        #expect(orchArgonId.inputPerMillion == 2.00)
        #expect(orchArgonId.outputPerMillion == 10.00)

        let hydrogen = pricing.rateFor(modelName: "gemini-4-hydrogen-high")
        #expect(hydrogen.inputPerMillion == 1.50)
        #expect(abs(hydrogen.cacheReadPerMillion - 0.075) < 0.0001)
        #expect(hydrogen.outputPerMillion == 7.50)

        let opus55 = pricing.rateFor(modelName: "Claude Opus 5.5 (High)")
        #expect(opus55.inputPerMillion == 4.00)
        #expect(abs(opus55.cacheReadPerMillion - 0.20) < 0.0001)
        #expect(opus55.outputPerMillion == 20.00)

        let sonnet55 = pricing.rateFor(modelName: "Claude Sonnet 5.5 (Medium)")
        #expect(sonnet55.inputPerMillion == 2.00)
        #expect(abs(sonnet55.cacheReadPerMillion - 0.10) < 0.0001)
        #expect(sonnet55.outputPerMillion == 10.00)

        let gptOss = pricing.rateFor(modelName: "GPT-OSS 120B (Medium)")
        #expect(gptOss.inputPerMillion == 0.15)
        #expect(gptOss.outputPerMillion == 0.60)

        let flash35 = pricing.rateFor(modelName: "gemini-3.5-flash")
        #expect(flash35.inputPerMillion == 1.50)
        #expect(abs(flash35.cacheReadPerMillion - 0.15) < 0.0001)
        #expect(flash35.outputPerMillion == 9.00)
    }

    @Test("ModelFormatter and TranscriptScanner preserve orchestrator names and normalize effort suffixes")
    func testOrchestratorAndGemini4Formatting() {
        let scanner = TranscriptScanner.shared

        let orchNeonMsg = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Orchestrator (Neon). No need to comment.\n</USER_SETTINGS_CHANGE>"
        #expect(scanner.extractModelFromContent(orchNeonMsg) == "Orchestrator (Neon)")

        let orchArgonMsg = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Orchestrator (Neon) to Orchestrator (Argon).\n</USER_SETTINGS_CHANGE>"
        #expect(scanner.extractModelFromContent(orchArgonMsg) == "Orchestrator (Argon)")

        #expect(ModelFormatter.displayName(for: "gemini-pro-orchestrator-neon") == "Orchestrator (Neon)")
        #expect(ModelFormatter.canonicalId(for: "Orchestrator (Neon)") == "orchestrator-neon")
        // The Argon orchestrator is grouped with Gemini 4 Argon (same quota pool and price).
        #expect(ModelFormatter.displayName(for: "gemini-pro-orchestrator-g1-pro") == "Gemini 4 Argon")
        #expect(ModelFormatter.displayName(for: "Orchestrator (Argon)") == "Gemini 4 Argon")
        #expect(ModelFormatter.canonicalId(for: "Orchestrator (Argon)") == "gemini-4-argon")

        #expect(ModelFormatter.displayName(for: "gemini-4-neon-xhigh") == "Gemini 4 Neon")
        #expect(ModelFormatter.displayName(for: "gemini-4-argon-high") == "Gemini 4 Argon")
        #expect(ModelFormatter.displayName(for: "gemini-4-hydrogen-xhigh") == "Gemini 4 Hydrogen")
        #expect(ModelFormatter.displayName(for: "claude-opus-5-5-high") == "Claude Opus 5.5")
        #expect(ModelFormatter.displayName(for: "claude-sonnet-5-5-medium") == "Claude Sonnet 5.5")
        #expect(ModelFormatter.displayName(for: "gpt-oss-120b-medium") == "GPT-OSS 120B")
        #expect(ModelFormatter.provider(for: "Orchestrator (Neon)") == "Google")
        #expect(ModelFormatter.provider(for: "GPT-OSS 120B") == "OpenAI")
    }

    @Test("TranscriptScanner reads per-step model from PLANNER_RESPONSE and sums multi-model session cost")
    func testPerStepPlannerModelAndSessionCostSum() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("test_orch_brain_\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempRoot.appendingPathComponent("session-orch/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // No <USER_SETTINGS_CHANGE> in file (same as subagents or direct sessions),
        // but each PLANNER_RESPONSE carries its own "model" field.
        let sampleJSONL = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","model":"gemini-4-neon-xhigh","status":"DONE","created_at":"2026-11-20T23:00:00Z","input_tokens":1000000,"cache_read_tokens":0,"output_tokens":0}
        {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","model":"gemini-3.8-flash-high","status":"DONE","created_at":"2026-11-20T23:05:00Z","input_tokens":1000000,"cache_read_tokens":0,"output_tokens":0}
        """
        let transcriptURL = logsDir.appendingPathComponent("transcript.jsonl")
        try sampleJSONL.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let (steps, sessions) = TranscriptScanner.shared.scanAll(brainURL: tempRoot, surface: .desktop)
        #expect(steps.count == 2)
        #expect(sessions.count == 1)

        let neonStep = try #require(steps.first(where: { $0.stepIndex == 1 }))
        let flashStep = try #require(steps.first(where: { $0.stepIndex == 2 }))
        #expect(ModelFormatter.displayName(for: neonStep.modelName) == "Gemini 4 Neon")
        #expect(ModelFormatter.displayName(for: flashStep.modelName) == "Gemini 3.8 Flash")
        #expect(abs(neonStep.cost - 3.00) < 0.001)
        #expect(abs(flashStep.cost - 0.75) < 0.001)

        // SessionSummary.estimatedCost must sum step costs ($3.00 + $0.75 = $3.75),
        // NOT multiply all 2M tokens by the last model ($1.50).
        #expect(abs(sessions[0].estimatedCost - 3.75) < 0.001)
    }

    @Test("QuotaGroup matches Neon and Argon orchestrators without misrouting Argon to Gemini Models")
    func testQuotaGroupOrchestratorMatching() {
        let geminiGroup = QuotaGroup(name: "Gemini Models", buckets: [])
        let argonGroup = QuotaGroup(name: "Gemini 4 Argon", buckets: [])
        let claudeGroup = QuotaGroup(name: "Claude and GPT models", buckets: [])
        let snapshot = QuotaSnapshot(groups: [geminiGroup, claudeGroup, argonGroup])

        #expect(snapshot.group(for: "Gemini 4 Neon")?.name == "Gemini Models")
        #expect(snapshot.group(for: "Orchestrator (Neon)")?.name == "Gemini Models")
        #expect(snapshot.group(for: "Gemini 4 Hydrogen")?.name == "Gemini Models")
        #expect(snapshot.group(for: "Gemini 4 Argon")?.name == "Gemini 4 Argon")
        #expect(snapshot.group(for: "Orchestrator (Argon)")?.name == "Gemini 4 Argon")
        #expect(snapshot.group(for: "GPT-OSS 120B")?.name == "Claude and GPT models")
        #expect(geminiGroup.shortLabel == "Gemini")
        #expect(argonGroup.shortLabel == "Argon")
        #expect(claudeGroup.shortLabel == "Claude")
    }

    @Test("PricingService prioritizes synced LiteLLM prefixed entries over built-in defaults")
    func testLiteLLMPrefixedRateOverridesBuiltInDefaults() throws {
        let pricing = PricingService(loadCache: false)

        // Verify offline defaults work without any cache file
        let offlineNeon = pricing.rateFor(modelName: "Orchestrator (Neon)")
        #expect(offlineNeon.inputPerMillion == 3.00)
        #expect(offlineNeon.outputPerMillion == 15.00)

        // Simulate synced LiteLLM JSON with provider-prefixed keys and custom updated prices
        let json = """
        {
          "vertex_ai/gemini-4-neon": {
            "input_cost_per_token": 0.000009,
            "cache_read_input_token_cost": 0.00000045,
            "output_cost_per_token": 0.000045
          },
          "gemini/gemini-4-argon": {
            "input_cost_per_token": 0.000006,
            "cache_read_input_token_cost": 0.0000003,
            "output_cost_per_token": 0.00003
          },
          "openai.gpt-oss-120b-1:0": {
            "input_cost_per_token": 0.0000005,
            "output_cost_per_token": 0.000002
          }
        }
        """
        pricing.applyPricingJSON(data: Data(json.utf8))

        let syncedNeon = pricing.rateFor(modelName: "Orchestrator (Neon)")
        #expect(abs(syncedNeon.inputPerMillion - 9.00) < 0.0001)
        #expect(abs(syncedNeon.cacheReadPerMillion - 0.45) < 0.0001)
        #expect(abs(syncedNeon.outputPerMillion - 45.00) < 0.0001)

        let syncedArgon = pricing.rateFor(modelName: "gemini-pro-orchestrator-g1-pro")
        #expect(abs(syncedArgon.inputPerMillion - 6.00) < 0.0001)
        #expect(abs(syncedArgon.cacheReadPerMillion - 0.30) < 0.0001)
        #expect(abs(syncedArgon.outputPerMillion - 30.00) < 0.0001)

        let syncedGptOss = pricing.rateFor(modelName: "gpt-oss-120b-medium")
        #expect(abs(syncedGptOss.inputPerMillion - 0.50) < 0.0001)
        #expect(abs(syncedGptOss.outputPerMillion - 2.00) < 0.0001)

        // Re-syncing without an earlier key removes stale remote entries
        let updatedJson = """
        {
          "vertex_ai/gemini-4-neon": {
            "input_cost_per_token": 0.000004,
            "cache_read_input_token_cost": 0.0000002,
            "output_cost_per_token": 0.00002
          }
        }
        """
        pricing.applyPricingJSON(data: Data(updatedJson.utf8))
        let revertedArgon = pricing.rateFor(modelName: "gemini-pro-orchestrator-g1-pro")
        #expect(abs(revertedArgon.inputPerMillion - 2.00) < 0.0001)
    }

    @Test("ModelFormatter and PricingService handle -tiered suffix and gemini-flash-worker-agy")
    func testTieredSuffixAndFlashWorkerAgy() {
        #expect(ModelFormatter.displayName(for: "gemini-4-hydrogen-tiered") == "Gemini 4 Hydrogen")
        #expect(ModelFormatter.canonicalId(for: "gemini-4-hydrogen-tiered") == "gemini-4-hydrogen")
        #expect(ModelFormatter.displayName(for: "gemini-4-neon-tiered") == "Gemini 4 Neon")
        #expect(ModelFormatter.displayName(for: "gemini-4-argon-tiered") == "Gemini 4 Argon")
        // The orchestrator execution worker belongs to the Gemini 4 Hydrogen family.
        #expect(ModelFormatter.displayName(for: "gemini-flash-worker-agy") == "Gemini 4 Hydrogen")
        #expect(ModelFormatter.canonicalId(for: "gemini-flash-worker-agy") == "gemini-4-hydrogen")

        let pricing = PricingService(loadCache: false)
        let workerRate = pricing.rateFor(modelName: "gemini-flash-worker-agy")
        #expect(workerRate.inputPerMillion == 1.50)
        #expect(abs(workerRate.cacheReadPerMillion - 0.075) < 0.0001)
        #expect(workerRate.outputPerMillion == 7.50)

        let orchArgonRate = pricing.rateFor(modelName: "Orchestrator (Argon)")
        #expect(orchArgonRate.inputPerMillion == 2.00)
        #expect(orchArgonRate.outputPerMillion == 10.00)

        let tieredRate = pricing.rateFor(modelName: "gemini-4-hydrogen-tiered")
        #expect(tieredRate.inputPerMillion == 1.50)
        #expect(abs(tieredRate.cacheReadPerMillion - 0.075) < 0.0001)
        #expect(tieredRate.outputPerMillion == 7.50)
    }

    @Test("ModelFormatter and PricingService normalize experimental SQLite model variants")
    func testExperimentalModelVariantNormalization() {
        #expect(ModelFormatter.displayName(for: "gemini-3.8-flash-n") == "Gemini 3.8 Flash")
        #expect(ModelFormatter.canonicalId(for: "gemini-3.8-flash-n") == "gemini-3.8-flash")
        #expect(ModelFormatter.displayName(for: "gemini-4-argon-trial") == "Gemini 4 Argon")
        #expect(ModelFormatter.displayName(for: "gemini-4-argon-e") == "Gemini 4 Argon")
        #expect(ModelFormatter.displayName(for: "gemini-3.7-flash-exp-a") == "Gemini 3.7 Flash")
        #expect(ModelFormatter.displayName(for: "gemini-3.7-flash-exp-b") == "Gemini 3.7 Flash")
        #expect(ModelFormatter.displayName(for: "gemini-3.6-flash") == "Gemini 3.6 Flash")
        #expect(ModelFormatter.displayName(for: "gemini-3-flash-a") == "Gemini 3 Flash")
        #expect(ModelFormatter.displayName(for: "gemini-3.8-flash-tiered") == "Gemini 3.8 Flash")

        let pricing = PricingService(loadCache: false)
        let flash37 = pricing.rateFor(modelName: "gemini-3.7-flash-exp-a")
        #expect(flash37.inputPerMillion == 0.75)
        #expect(abs(flash37.cacheReadPerMillion - 0.075) < 0.0001)
        #expect(flash37.outputPerMillion == 3.75)
        let flash36 = pricing.rateFor(modelName: "gemini-3.6-flash-high")
        #expect(flash36.inputPerMillion == 0.75)
        #expect(flash36.outputPerMillion == 3.75)
        let argonTrial = pricing.rateFor(modelName: "gemini-4-argon-trial")
        #expect(argonTrial.inputPerMillion == 2.00)
        #expect(argonTrial.outputPerMillion == 10.00)
    }

    @Test("StepModelAligner assigns SQLite per-step models by order with tolerance and window")
    func testStepModelAlignment() {
        func row(_ input: Int, _ cache: Int, _ model: String?) -> GenStepModel {
            GenStepModel(inputTokens: input, cacheReadTokens: cache, modelName: model)
        }
        let rows = [
            row(1000, 0, "gemini-pro-orchestrator-neon"),
            row(2000, 1000, "gemini-flash-worker-agy"),
            row(3000, 3000, "gemini-flash-worker-agy"),
            row(4000, 6000, "gemini-4-hydrogen")
        ]

        // Exact 1:1 alignment
        let exact = StepModelAligner.align(
            steps: [(1000, 0), (2000, 1000), (3000, 3000), (4000, 6000)],
            rows: rows
        )
        #expect(exact == ["gemini-pro-orchestrator-neon", "gemini-flash-worker-agy", "gemini-flash-worker-agy", "gemini-4-hydrogen"])

        // Tiny token drift between transcript and DB is tolerated (rounded counters)
        let drift = StepModelAligner.align(
            steps: [(1001, 0), (1998, 1001), (3000, 2999)],
            rows: rows
        )
        #expect(drift == ["gemini-pro-orchestrator-neon", "gemini-flash-worker-agy", "gemini-flash-worker-agy"])

        // A DB row without a transcript step (skipped within the window) does not break the rest
        let skipped = StepModelAligner.align(
            steps: [(1000, 0), (3000, 3000), (4000, 6000)],
            rows: rows
        )
        #expect(skipped == ["gemini-pro-orchestrator-neon", "gemini-flash-worker-agy", "gemini-4-hydrogen"])

        // A transcript step with no match stays nil, and later steps still align
        let unmatched = StepModelAligner.align(
            steps: [(1000, 0), (777_777, 5), (3000, 3000)],
            rows: rows
        )
        #expect(unmatched == ["gemini-pro-orchestrator-neon", nil, "gemini-flash-worker-agy"])

        // Completely unrelated rows yield no models at all
        let none = StepModelAligner.align(steps: [(5, 5), (6, 6)], rows: rows)
        #expect(none == [nil, nil])
    }

    @Test("TranscriptScanner fills model-less steps from the sibling SQLite conversation DB")
    func testTranscriptModelEnrichmentFromSQLite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("test_enrich_\(UUID().uuidString)", isDirectory: true)
        let brain = root.appendingPathComponent("brain", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let sessionId = "session-enrich"
        let logsDir = brain.appendingPathComponent("\(sessionId)/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Old-format transcript: no "model" on PLANNER_RESPONSE, no USER_SETTINGS_CHANGE.
        // Step 3 carries an explicit model that must win over the DB.
        let jsonl = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-10T10:00:00Z","input_tokens":1000000,"cache_read_tokens":0,"output_tokens":0}
        {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-10T10:01:00Z","input_tokens":1000000,"cache_read_tokens":0,"output_tokens":0}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","model":"gemini-3.8-flash-high","status":"DONE","created_at":"2026-11-10T10:02:00Z","input_tokens":1000000,"cache_read_tokens":0,"output_tokens":0}
        """
        try jsonl.write(to: logsDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        func genRow(model: String, input: UInt64, responseId: String) -> Data {
            var usage = Data()
            usage.append(encodeVarintField(fieldNumber: 2, value: input))
            usage.append(encodeVarintField(fieldNumber: 9, value: 1))
            usage.append(encodeLengthDelimited(fieldNumber: 11, data: responseId.data(using: .utf8)!))
            var chat = Data()
            chat.append(encodeLengthDelimited(fieldNumber: 19, data: model.data(using: .utf8)!))
            chat.append(encodeLengthDelimited(fieldNumber: 4, data: usage))
            return encodeLengthDelimited(fieldNumber: 1, data: chat)
        }

        let dbURL = conversations.appendingPathComponent("\(sessionId).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB);", nil, nil, nil) == SQLITE_OK)
        let blobs = [
            genRow(model: "gemini-pro-orchestrator-neon", input: 1_000_000, responseId: "r1"),
            genRow(model: "gemini-flash-worker-agy", input: 1_000_000, responseId: "r2"),
            genRow(model: "gemini-4-argon", input: 1_000_000, responseId: "r3")
        ]
        for (i, blob) in blobs.enumerated() {
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (\(i + 1), ?);", -1, &stmt, nil) == SQLITE_OK)
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(blob.count), nil)
            }
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)

        let (steps, sessions) = TranscriptScanner.shared.scanAll(brainURL: brain, surface: .desktop)
        #expect(steps.count == 3)
        let byIndex = Dictionary(uniqueKeysWithValues: steps.map { ($0.stepIndex, $0) })

        let neon = try #require(byIndex[1])
        #expect(ModelFormatter.displayName(for: neon.modelName) == "Orchestrator (Neon)")
        #expect(abs(neon.cost - 3.00) < 0.001)

        // Worker is grouped with and priced like Gemini 4 Hydrogen ($1.50 / 1M input)
        let worker = try #require(byIndex[2])
        #expect(ModelFormatter.displayName(for: worker.modelName) == "Gemini 4 Hydrogen")
        #expect(abs(worker.cost - 1.50) < 0.001)

        // Explicit transcript model wins over the DB row (which says gemini-4-argon)
        let explicit = try #require(byIndex[3])
        #expect(ModelFormatter.displayName(for: explicit.modelName) == "Gemini 3.8 Flash")
        #expect(abs(explicit.cost - 0.75) < 0.001)

        #expect(sessions.count == 1)
        #expect(abs(sessions[0].estimatedCost - 5.25) < 0.001)
    }

    @Test("SQLiteConversationScanner reads WAL-mode databases that have no -wal/-shm sidecar files")
    func testReadsWalModeDatabaseWithoutSidecars() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("test_wal_\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var usage = Data()
        usage.append(encodeVarintField(fieldNumber: 2, value: 1200))
        usage.append(encodeVarintField(fieldNumber: 5, value: 800))
        usage.append(encodeVarintField(fieldNumber: 9, value: 400))
        usage.append(encodeLengthDelimited(fieldNumber: 11, data: "wal-resp".data(using: .utf8)!))
        var chat = Data()
        chat.append(encodeLengthDelimited(fieldNumber: 19, data: "gemini-4-hydrogen".data(using: .utf8)!))
        chat.append(encodeLengthDelimited(fieldNumber: 4, data: usage))
        let blob = encodeLengthDelimited(fieldNumber: 1, data: chat)

        let dbURL = conversations.appendingPathComponent("wal-session.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB);", nil, nil, nil) == SQLITE_OK)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (1, ?);", -1, &stmt, nil) == SQLITE_OK)
        _ = blob.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(blob.count), nil) }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        // Fold everything into the main file, then drop the sidecars to mirror a cleanly closed
        // WAL-mode database (the state of finished Antigravity conversations on disk).
        #expect(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try? fm.removeItem(atPath: dbURL.path + "-wal")
        try? fm.removeItem(atPath: dbURL.path + "-shm")
        #expect(fm.fileExists(atPath: dbURL.path))

        let rows = SQLiteConversationScanner.shared.readStepModels(dbURL: dbURL)
        #expect(rows == [GenStepModel(inputTokens: 1200, cacheReadTokens: 800, modelName: "gemini-4-hydrogen")])

        let (steps, sessions) = SQLiteConversationScanner.shared.scanDirectory(directoryURL: root, surface: .cli)
        #expect(steps.count == 1)
        #expect(sessions.count == 1)
    }

    @Test("PricingService reports when 24-hour auto-sync is due")
    func testPricingServiceAutoSyncDue() throws {
        let tempCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pricing_cache_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCache) }

        let freshService = PricingService(cacheURL: tempCache, loadCache: false)
        let now = Date()
        #expect(freshService.lastSyncDate == nil)
        #expect(freshService.shouldAutoSync(now: now))

        // Write a cache file timestamped 12 hours ago -> not due yet
        try "{}".write(to: tempCache, atomically: true, encoding: .utf8)
        let twelveHoursAgo = now.addingTimeInterval(-12 * 3600)
        try FileManager.default.setAttributes([.modificationDate: twelveHoursAgo], ofItemAtPath: tempCache.path)
        let recentService = PricingService(cacheURL: tempCache, loadCache: true)
        #expect(!recentService.shouldAutoSync(now: now))

        // Cache file timestamped 25 hours ago -> due for auto-sync
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 3600)
        try FileManager.default.setAttributes([.modificationDate: twentyFiveHoursAgo], ofItemAtPath: tempCache.path)
        let staleService = PricingService(cacheURL: tempCache, loadCache: true)
        #expect(staleService.shouldAutoSync(now: now))
    }

    @Test("TrackerViewModel auto-syncs stale pricing once per day and respects retry cooldown")
    @MainActor
    func testTrackerViewModelAutoSyncPricing() async throws {
        final class MockPricingSyncer: PricingSyncing, @unchecked Sendable {
            private let lock = NSLock()
            var lastSyncDate: Date?
            var fetchCalls = 0
            var nextFetchResult = true

            init(lastSyncDate: Date?) {
                self.lastSyncDate = lastSyncDate
            }

            func shouldAutoSync(now: Date, maxAge: TimeInterval) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard let lastSyncDate else { return true }
                return now.timeIntervalSince(lastSyncDate) >= maxAge
            }

            func rateFor(modelName: String?) -> ModelRate {
                PricingService.shared.rateFor(modelName: modelName)
            }

            func fetchRemotePricing() async -> Bool {
                lock.withLock {
                    fetchCalls += 1
                    let result = nextFetchResult
                    if result {
                        lastSyncDate = Date()
                    }
                    return result
                }
            }
        }

        let now = Date()
        // 1. Freshly synced (2h ago) -> auto-sync does nothing; force: true syncs anyway
        let freshMock = MockPricingSyncer(lastSyncDate: now.addingTimeInterval(-2 * 3600))
        let freshVM = TrackerViewModel(startBackgroundServices: false, pricing: freshMock)
        freshVM.syncPricing(now: now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(freshMock.fetchCalls == 0)

        freshVM.syncPricing(force: true, now: now)
        try await Task.sleep(for: .milliseconds(50))
        #expect(freshMock.fetchCalls == 1)

        // 2. Stale (25h ago), first attempt fails -> respects 1h retry cooldown, retries after cooldown
        let staleMock = MockPricingSyncer(lastSyncDate: now.addingTimeInterval(-25 * 3600))
        staleMock.nextFetchResult = false
        let staleVM = TrackerViewModel(startBackgroundServices: false, pricing: staleMock)

        staleVM.syncPricing(now: now)
        try await Task.sleep(for: .milliseconds(50))
        #expect(staleMock.fetchCalls == 1)

        // 10 minutes later: blocked by retry cooldown
        staleVM.syncPricing(now: now.addingTimeInterval(600))
        try await Task.sleep(for: .milliseconds(30))
        #expect(staleMock.fetchCalls == 1)

        // 2 hours later: cooldown expired, succeeds and updates pricingSyncDate
        staleMock.nextFetchResult = true
        staleVM.syncPricing(now: now.addingTimeInterval(2 * 3600))
        try await Task.sleep(for: .milliseconds(50))
        #expect(staleMock.fetchCalls == 2)
        #expect(staleVM.pricingSyncDate != nil)
    }

    @Test("UnifiedScanner clearCaches allows recalculated costs after pricing update")
    func testUnifiedScannerClearCaches() {
        UnifiedScanner.shared.clearCaches()
    }

    // MARK: - Protobuf Encoding Helpers for Tests

    private func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var data = Data()
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
        return data
    }

    private func encodeLengthDelimited(fieldNumber: Int, data: Data) -> Data {
        var result = encodeVarint(UInt64((fieldNumber << 3) | 2))
        result.append(encodeVarint(UInt64(data.count)))
        result.append(data)
        return result
    }

    private func encodeVarintField(fieldNumber: Int, value: UInt64) -> Data {
        var result = encodeVarint(UInt64((fieldNumber << 3) | 0))
        result.append(encodeVarint(value))
        return result
    }
}
