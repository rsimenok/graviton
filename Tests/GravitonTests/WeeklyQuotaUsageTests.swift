import Foundation
import Testing
@testable import Graviton

@Suite("Weekly quota usage today")
struct WeeklyQuotaUsageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func snapshot(
        _ remaining: Double,
        at time: String,
        group: String = "Gemini Models",
        window: String = "weekly",
        reset: String? = "2026-12-01T09:00:00Z"
    ) -> QuotaSnapshot {
        QuotaSnapshot(fetchedAt: date(time), groups: [
            QuotaGroup(name: group, buckets: [
                QuotaBucket(id: "\(group)-\(window)", name: window, window: window,
                            remainingFraction: remaining, resetTime: reset.map(date))
            ])
        ])
    }

    private func withFile(_ body: (URL) throws -> Void) rethrows {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("weekly_usage_today.json"))
    }

    @Test("Tracks the observed decrease, independently for each group")
    func dailyDecrease() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            let first = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T09:00:00Z"), calendar: calendar))
            #expect(first.usedPercent == 0)
            store.record(snapshot(0.65, at: "2026-11-25T10:00:00Z"), calendar: calendar)
            store.record(snapshot(0.25, at: "2026-11-25T10:01:00Z", group: "Claude Models"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T10:01:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 15) < 0.0001)
            #expect(usage.startedAt == date("2026-11-25T09:00:00Z"))
            #expect(store.usage(for: "Claude Models", now: date("2026-11-25T10:01:00Z"), calendar: calendar)?.usedPercent == 0)
        }
    }

    @Test("Restart preserves today's baseline and accumulated usage")
    func restart() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            store.record(snapshot(0.70, at: "2026-11-25T10:00:00Z"), calendar: calendar)
            let restarted = WeeklyQuotaUsageStore(customFileURL: url)
            restarted.record(snapshot(0.65, at: "2026-11-25T11:00:00Z"), calendar: calendar)
            let usage = try #require(restarted.usage(for: "Gemini Models", now: date("2026-11-25T11:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 15) < 0.0001)
        }
    }

    @Test("A new day starts a new baseline without charging overnight changes")
    func newDay() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            store.record(snapshot(0.65, at: "2026-11-25T23:59:00Z"), calendar: calendar)
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-26T00:00:00Z"), calendar: calendar) == nil)
            store.record(snapshot(0.50, at: "2026-11-26T09:00:00Z"), calendar: calendar)
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-26T09:00:00Z"), calendar: calendar)?.usedPercent == 0)
            store.record(snapshot(0.40, at: "2026-11-26T10:00:00Z"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-26T10:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 10) < 0.0001)
        }
    }

    @Test("Duplicate and out-of-order samples cannot inflate or rewind consumption")
    func repeatedSamples() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            let first = snapshot(0.80, at: "2026-11-25T09:00:00Z")
            let last = snapshot(0.65, at: "2026-11-25T10:00:00Z")
            store.record(first, calendar: calendar)
            store.record(last, calendar: calendar)
            store.record(last, calendar: calendar)
            store.record(first, calendar: calendar)
            store.record(snapshot(0.95, at: "2026-11-24T09:00:00Z"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T11:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 15) < 0.0001)
        }
    }

    @Test("Confirmed weekly reset retains earlier usage and adds the observed new cycle")
    func weeklyReset() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
            store.record(snapshot(0.65, at: "2026-11-25T11:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
            store.record(snapshot(0.90, at: "2026-11-25T13:00:00Z", reset: "2026-12-02T12:00:00Z"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T13:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 25) < 0.0001)
            #expect(usage.isPartial)
            let restarted = WeeklyQuotaUsageStore(customFileURL: url)
            restarted.record(snapshot(0.85, at: "2026-11-25T14:00:00Z", reset: "2026-12-02T12:00:00Z"), calendar: calendar)
            let afterRestart = try #require(restarted.usage(for: "Gemini Models", now: date("2026-11-25T14:00:00Z"), calendar: calendar))
            #expect(abs(afterRestart.usedPercent - 30) < 0.0001)
        }
    }

    @Test("Reset is detected even when the new remaining balance is lower")
    func resetWithLowerBalance() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
            store.record(snapshot(0.70, at: "2026-11-25T13:00:00Z", reset: "2026-12-02T12:00:00Z"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T13:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 30) < 0.0001)
        }
    }

    @Test("Unknown increases never subtract earlier consumption or assume a full refill")
    func unknownIncrease() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z", reset: nil), calendar: calendar)
            store.record(snapshot(0.65, at: "2026-11-25T10:00:00Z", reset: nil), calendar: calendar)
            store.record(snapshot(0.90, at: "2026-11-25T11:00:00Z", reset: nil), calendar: calendar)
            store.record(snapshot(0.85, at: "2026-11-25T12:00:00Z", reset: nil), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T12:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 20) < 0.0001)
            #expect(usage.isPartial)
        }
    }

    @Test("Timezone changes establish a local baseline and five-hour buckets are ignored")
    func timezoneAndFiveHour() {
        withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            store.record(snapshot(0.10, at: "2026-11-25T10:00:00Z", window: "5h"), calendar: calendar)
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-25T10:00:00Z"), calendar: calendar)?.usedPercent == 0)
            var kyiv = calendar
            kyiv.timeZone = TimeZone(identifier: "Europe/Kyiv")!
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-25T10:00:00Z"), calendar: kyiv) == nil)
            store.record(snapshot(0.65, at: "2026-11-25T11:00:00Z"), calendar: kyiv)
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-25T11:00:00Z"), calendar: kyiv)?.usedPercent == 0)
        }
    }

    private func quotaJSON(_ bucketFields: String, status: String = "SUCCESS") -> Data {
        Data("""
        {"status":"\(status)","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"Gemini Models-weekly","name":"Weekly","window":"weekly",\(bucketFields)}
          ]}
        ]}}}
        """.utf8)
    }

    @Test("Only fresh valid live responses update today's usage")
    func liveResponses() throws {
        try withFile { url in
            let suiteName = "WeeklyQuotaUsageTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            let service = QuotaService(usageStore: store, defaults: defaults)
            let now = Date()
            let earlier = Calendar.current.startOfDay(for: now)
            store.record(QuotaSnapshot(fetchedAt: earlier, groups: [
                QuotaGroup(name: "Gemini Models", buckets: [
                    QuotaBucket(id: "Gemini Models-weekly", name: "Weekly", window: "weekly", remainingFraction: 0.80)
                ])
            ]))

            _ = try service.acceptLiveQuota(data: quotaJSON("\"remaining_fraction\":0.65"))
            let usage = try #require(store.usage(for: "Gemini Models"))
            #expect(abs(usage.usedPercent - 15) < 0.0001)
            let liveDate = try #require(service.currentSnapshot?.fetchedAt)

            // Reloading the display cache must neither record consumption nor invent a new date.
            let reloaded = QuotaService(usageStore: store, defaults: defaults)
            let cachedDate = try #require(reloaded.currentSnapshot?.fetchedAt)
            // The legacy cache stores Unix seconds, whose conversion can lose a fraction of a microsecond.
            #expect(abs(cachedDate.timeIntervalSince(liveDate)) < 0.000001)
            #expect(store.usage(for: "Gemini Models")?.usedPercent == usage.usedPercent)

            #expect(throws: (any Error).self) {
                try service.acceptLiveQuota(data: quotaJSON("\"remaining_fraction\":0.10", status: "ERROR"))
            }
            #expect(store.usage(for: "Gemini Models")?.usedPercent == usage.usedPercent)
            #expect(service.currentSnapshot?.fetchedAt == liveDate)
        }
    }

    @Test("An old display cache keeps its original date without starting today's counter")
    func oldCache() throws {
        try withFile { url in
            let suiteName = "WeeklyQuotaCacheTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(quotaJSON("\"remaining_fraction\":0.65"), forKey: "agy_cached_quota_json")
            defaults.set(date("2026-11-24T09:00:00Z").timeIntervalSince1970, forKey: "agy_cached_quota_timestamp")
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            let service = QuotaService(usageStore: store, defaults: defaults)
            #expect(service.currentSnapshot?.fetchedAt == date("2026-11-24T09:00:00Z"))
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-25T10:00:00Z"), calendar: calendar) == nil)
        }
    }

    @Test("Missing or invalid fractions cannot become artificial full quotas")
    func invalidFractions() throws {
        let service = QuotaService()
        for fields in ["\"reset_time\":null", "\"remaining_fraction\":-0.1", "\"remaining_fraction\":1.1"] {
            #expect(throws: (any Error).self) {
                try service.parseQuotaJSON(data: quotaJSON(fields))
            }
        }
        for percent in ["nonsense%", "1%0%", "65%%"] {
            let invalidText = Data("{\"response\":\"Gemini Models\\tWeekly Limit Remaining\\t\(percent)\"}".utf8)
            #expect(throws: (any Error).self) {
                try service.parseQuotaJSON(data: invalidText)
            }
        }
    }

    @Test("View model tolerates repeated group IDs and clears today's totals on the next day")
    @MainActor
    func viewModelDayRollover() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            let latest = snapshot(0.65, at: "2026-11-25T10:00:00Z")
            store.record(latest, calendar: calendar)
            let vm = TrackerViewModel(startBackgroundServices: false, weeklyUsageStore: store)
            vm.quotaSnapshot = QuotaSnapshot(fetchedAt: latest.fetchedAt, groups: latest.groups + latest.groups)
            vm.recomputeMetrics(now: date("2026-11-25T10:00:00Z"), calendar: calendar)
            let usage = try #require(vm.weeklyUsageToday["Gemini Models"])
            #expect(abs(usage.usedPercent - 15) < 0.0001)
            vm.recomputeMetrics(now: date("2026-11-26T00:00:00Z"), calendar: calendar)
            #expect(vm.weeklyUsageToday.isEmpty)
        }
    }

    @Test("Structured and text CLI formats refer to the same weekly quota")
    func outputFormatTransitions() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            let service = QuotaService(usageStore: store)
            let structured = quotaJSON("\"remaining_fraction\":0.80,\"reset_time\":\"2026-12-01T09:00:00Z\"")
            let text = Data("{\"response\":\"Gemini Models\\tWeekly Limit Remaining\\t65%\\t2026-12-01T09:00:00Z\"}".utf8)
            store.record(try service.parseQuotaJSON(data: structured, fetchedAt: date("2026-11-25T09:00:00Z")), calendar: calendar)
            store.record(try service.parseQuotaJSON(data: text, fetchedAt: date("2026-11-25T10:00:00Z")), calendar: calendar)
            let intermediate = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T10:00:00Z"), calendar: calendar))
            #expect(abs(intermediate.usedPercent - 15) < 0.0001)
            let structuredAgain = quotaJSON("\"remaining_fraction\":0.60,\"reset_time\":\"2026-12-01T09:00:00Z\"")
            store.record(try service.parseQuotaJSON(data: structuredAgain, fetchedAt: date("2026-11-25T11:00:00Z")), calendar: calendar)
            let result = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T11:00:00Z"), calendar: calendar))
            #expect(abs(result.usedPercent - 20) < 0.0001)
        }
    }

    @Test("Ambiguous duplicate group names cannot mutate the daily counter")
    func duplicateGroups() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            let service = QuotaService(usageStore: store)
            store.record(snapshot(0.90, at: "2026-11-25T09:00:00Z"), calendar: calendar)
            for nameField in ["\"name\":\"Gemini Models\",", ""] {
                let bucket = "\"buckets\":[{\"id\":\"weekly\",\"window\":\"weekly\",\"remaining_fraction\":0.65}]"
                let data = Data("{\"command\":{\"data\":{\"groups\":[{\(nameField)\(bucket)},{\(nameField)\(bucket)}]}}}".utf8)
                #expect(throws: (any Error).self) { try service.parseQuotaJSON(data: data) }
            }
            let first = snapshot(0.80, at: "2026-11-25T10:00:00Z").groups[0]
            let second = snapshot(0.65, at: "2026-11-25T10:00:00Z").groups[0]
            store.record(QuotaSnapshot(fetchedAt: date("2026-11-25T10:00:00Z"), groups: [first, second]), calendar: calendar)
            #expect(store.usage(for: "Gemini Models", now: date("2026-11-25T10:00:00Z"), calendar: calendar)?.usedPercent == 0)
        }
    }

    @Test("Expired or missing reset metadata cannot charge the new cycle to the old cycle")
    func delayedResetMetadata() throws {
        for reset in ["2026-11-25T12:00:00Z", nil] as [String?] {
            try withFile { url in
                let store = WeeklyQuotaUsageStore(customFileURL: url)
                store.record(snapshot(0.90, at: "2026-11-25T10:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
                store.record(snapshot(0.80, at: "2026-11-25T11:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
                store.record(snapshot(0.40, at: "2026-11-25T12:01:00Z", reset: reset), calendar: calendar)
                let unresolved = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T12:01:00Z"), calendar: calendar))
                #expect(abs(unresolved.usedPercent - 10) < 0.0001)
                #expect(unresolved.isPartial)
                store.record(snapshot(0.70, at: "2026-11-25T12:05:00Z", reset: "2026-12-02T12:00:00Z"), calendar: calendar)
                let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T12:05:00Z"), calendar: calendar))
                #expect(abs(usage.usedPercent - 40) < 0.0001)
            }
        }
    }

    @Test("A missing reset time before the boundary does not erase the known reset")
    func temporarilyMissingReset() throws {
        try withFile { url in
            let store = WeeklyQuotaUsageStore(customFileURL: url)
            store.record(snapshot(0.80, at: "2026-11-25T09:00:00Z", reset: "2026-11-25T12:00:00Z"), calendar: calendar)
            store.record(snapshot(0.75, at: "2026-11-25T11:00:00Z", reset: nil), calendar: calendar)
            store.record(snapshot(0.70, at: "2026-11-25T13:00:00Z", reset: "2026-12-02T12:00:00Z"), calendar: calendar)
            let usage = try #require(store.usage(for: "Gemini Models", now: date("2026-11-25T13:00:00Z"), calendar: calendar))
            #expect(abs(usage.usedPercent - 35) < 0.0001)
        }
    }
}
