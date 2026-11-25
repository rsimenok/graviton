import Foundation

public struct WeeklyQuotaUsage: Sendable {
    public let usedPercent: Double
    public let startedAt: Date
    public let isPartial: Bool
}

/// Retains only today's observed weekly consumption, never a history of snapshots.
public final class WeeklyQuotaUsageStore: @unchecked Sendable {
    public static let shared = WeeklyQuotaUsageStore()

    private struct Entry: Codable {
        var startedAt: Date
        var observedAt: Date
        var baselineRemaining: Double
        var remaining: Double
        var consumedBeforeReset: Double = 0
        var resetTime: Date?
        var isPartial: Bool = false

        var consumed: Double {
            consumedBeforeReset + max(0, baselineRemaining - remaining)
        }
    }

    private struct State: Codable {
        var version = 1
        var dayStart: Date
        var timeZoneID: String
        var observedAt: Date
        var groups: [String: Entry] = [:]
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var state: State?

    public init(customFileURL: URL? = nil) {
        fileURL = customFileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graviton", isDirectory: true)
            .appendingPathComponent("weekly_usage_today.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(State.self, from: data), saved.version == 1 {
            state = saved
        }
    }

    public func usage(for groupID: String, now: Date = Date(), calendar: Calendar = .current) -> WeeklyQuotaUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard let state,
              state.dayStart == calendar.startOfDay(for: now),
              state.timeZoneID == calendar.timeZone.identifier,
              let entry = state.groups[groupID] else { return nil }
        return WeeklyQuotaUsage(usedPercent: entry.consumed * 100,
                                startedAt: entry.startedAt, isPartial: entry.isPartial)
    }

    /// Call exclusively for a fresh successful response, never for the cached fallback.
    public func record(_ snapshot: QuotaSnapshot, calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }

        let weeklyGroups = snapshot.groups.filter { $0.weeklyBucket != nil }
        guard !weeklyGroups.isEmpty,
              Set(weeklyGroups.map(\.id)).count == weeklyGroups.count else { return }
        // A late result must not roll back the day or an already processed observation.
        if let state, snapshot.fetchedAt <= state.observedAt { return }

        let dayStart = calendar.startOfDay(for: snapshot.fetchedAt)
        var updated = state ?? State(dayStart: dayStart, timeZoneID: calendar.timeZone.identifier,
                                     observedAt: snapshot.fetchedAt)
        if updated.dayStart != dayStart || updated.timeZoneID != calendar.timeZone.identifier {
            updated = State(dayStart: dayStart, timeZoneID: calendar.timeZone.identifier,
                            observedAt: snapshot.fetchedAt)
        }

        for group in weeklyGroups {
            guard let bucket = group.weeklyBucket, bucket.remainingFraction.isFinite else { continue }
            if var entry = updated.groups[group.id] {
                // Keep the last pre-reset reading until the CLI confirms the next cycle.
                // Otherwise delayed metadata can charge new-cycle usage to the old cycle.
                if let previousReset = entry.resetTime, previousReset <= snapshot.fetchedAt {
                    guard let nextReset = bucket.resetTime,
                          nextReset > previousReset, nextReset > snapshot.fetchedAt else {
                        entry.isPartial = true
                        updated.groups[group.id] = entry
                        continue
                    }
                }
                let confirmedReset: Bool
                if let previousReset = entry.resetTime, let nextReset = bucket.resetTime {
                    confirmedReset = previousReset > entry.observedAt && previousReset <= snapshot.fetchedAt
                        && nextReset > previousReset && nextReset > snapshot.fetchedAt
                } else {
                    confirmedReset = false
                }

                if confirmedReset || bucket.remainingFraction > entry.remaining {
                    // Preserve consumption already observed before a reset or correction.
                    entry.consumedBeforeReset = entry.consumed
                    entry.baselineRemaining = confirmedReset ? 1 : bucket.remainingFraction
                    entry.isPartial = entry.isPartial || !confirmedReset || entry.remaining > 0
                }
                entry.remaining = bucket.remainingFraction
                entry.observedAt = snapshot.fetchedAt
                entry.resetTime = bucket.resetTime ?? entry.resetTime
                updated.groups[group.id] = entry
            } else {
                updated.groups[group.id] = Entry(
                    startedAt: snapshot.fetchedAt, observedAt: snapshot.fetchedAt,
                    baselineRemaining: bucket.remainingFraction, remaining: bucket.remainingFraction,
                    resetTime: bucket.resetTime
                )
            }
        }
        updated.observedAt = snapshot.fetchedAt
        state = updated

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Could not save today's weekly quota usage: %@", error.localizedDescription)
        }
    }
}
