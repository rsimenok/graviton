import Foundation
import SwiftUI

public final class QuotaService: @unchecked Sendable {
    public static let shared = QuotaService()

    private let cacheKey = "agy_cached_quota_json"
    private let cacheDateKey = "agy_cached_quota_timestamp"
    private let usageStore: WeeklyQuotaUsageStore
    private let defaults: UserDefaults

    private let lock = NSLock()
    private var _currentSnapshot: QuotaSnapshot?

    public var currentSnapshot: QuotaSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _currentSnapshot
        }
        set {
            lock.lock()
            _currentSnapshot = newValue
            lock.unlock()
        }
    }

    public init(usageStore: WeeklyQuotaUsageStore = .shared, defaults: UserDefaults = .standard) {
        self.usageStore = usageStore
        self.defaults = defaults
        self._currentSnapshot = loadCachedSnapshot()
    }

    /// Discovers candidate path for `agy` CLI
    public func resolveAgyBinaryPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.local/bin/agy",
            "/usr/bin/agy",
            "/bin/agy"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try searching PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") {
                let p = (dir as NSString).appendingPathComponent("agy")
                if FileManager.default.isExecutableFile(atPath: p) {
                    return p
                }
            }
        }

        return nil
    }

    /// Asynchronously fetches live quota from `agy --print /usage --output-format json`
    public func fetchLiveQuota() async -> QuotaSnapshot? {
        guard let agyPath = resolveAgyBinaryPath() else {
            // Cannot locate agy binary; fallback to cached
            return currentSnapshot
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: agyPath)
                process.arguments = ["--print", "/usage", "--output-format", "json", "--print-timeout", "15s"]

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                    
                    // Allow up to 18 seconds for process to exit
                    let deadline = Date().addingTimeInterval(18)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }

                    if process.isRunning {
                        process.terminate()
                        continuation.resume(returning: self.currentSnapshot)
                        return
                    }

                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0, !data.isEmpty else {
                        continuation.resume(returning: self.currentSnapshot)
                        return
                    }

                    if let snapshot = try? self.acceptLiveQuota(data: data) {
                        continuation.resume(returning: snapshot)
                    } else {
                        continuation.resume(returning: self.currentSnapshot)
                    }
                } catch {
                    continuation.resume(returning: self.currentSnapshot)
                }
            }
        }
    }

    // MARK: - JSON Parsing

    /// The live-success path is deliberately separate from loading or returning the cache.
    @discardableResult
    func acceptLiveQuota(data: Data) throws -> QuotaSnapshot {
        let snapshot = try parseQuotaJSON(data: data)
        usageStore.record(snapshot)
        currentSnapshot = snapshot
        saveCachedSnapshot(data: data, fetchedAt: snapshot.fetchedAt)
        return snapshot
    }

    private enum QuotaError: Error {
        case unsuccessfulResponse
        case noQuotaData
        case ambiguousGroups
    }

    private struct RawAgyResponse: Decodable {
        let status: String?
        let response: String?
        let command: RawAgyCommand?
    }

    private struct RawAgyCommand: Decodable {
        let name: String?
        let data: RawAgyData?
    }

    private struct RawAgyData: Decodable {
        let description: String?
        let groups: [RawAgyGroup]?
    }

    private struct RawAgyGroup: Decodable {
        let name: String?
        let description: String?
        let buckets: [RawAgyBucket]?
    }

    private struct RawAgyBucket: Decodable {
        let id: String?
        let name: String?
        let description: String?
        let window: String?
        let remaining_fraction: Double?
        let reset_time: String?
    }

    public func parseQuotaJSON(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        let resp = try decoder.decode(RawAgyResponse.self, from: data)
        if let status = resp.status, status.uppercased() != "SUCCESS" {
            throw QuotaError.unsuccessfulResponse
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardIso = ISO8601DateFormatter()
        standardIso.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String?) -> Date? {
            guard let str = str else { return nil }
            return isoFormatter.date(from: str) ?? standardIso.date(from: str)
        }

        var groups: [QuotaGroup] = []

        if let rawGroups = resp.command?.data?.groups, !rawGroups.isEmpty {
            for rg in rawGroups {
                let gName = rg.name ?? "Models"
                var buckets: [QuotaBucket] = []

                if let rawBuckets = rg.buckets {
                    for rb in rawBuckets {
                        guard let bId = rb.id, let bWindow = rb.window else { continue }
                        let bName = rb.name ?? bWindow
                        guard let fraction = rb.remaining_fraction,
                              fraction.isFinite, (0.0...1.0).contains(fraction) else { continue }
                        let resetDate = parseDate(rb.reset_time)

                        buckets.append(QuotaBucket(
                            id: bId,
                            name: bName,
                            description: rb.description,
                            window: bWindow,
                            remainingFraction: fraction,
                            resetTime: resetDate,
                            rawResetTime: rb.reset_time
                        ))
                    }
                }

                if !buckets.isEmpty {
                    groups.append(QuotaGroup(name: gName, description: rg.description, buckets: buckets))
                }
            }
        } else if let responseText = resp.response, !responseText.isEmpty {
            // Fallback parsing from response string lines:
            // "Gemini Models\tWeekly Limit Remaining\t93%\t2026-10-22T07:27:59Z"
            var groupDict: [String: [QuotaBucket]] = [:]
            for line in responseText.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3 else { continue }
                let groupName = parts[0].trimmingCharacters(in: .whitespaces)
                let bucketName = parts[1].trimmingCharacters(in: .whitespaces)
                var pctStr = parts[2].trimmingCharacters(in: .whitespaces)
                if pctStr.hasSuffix("%") { pctStr.removeLast() }
                let resetStr = parts.count >= 4 ? parts[3].trimmingCharacters(in: .whitespaces) : nil

                guard let percent = Double(pctStr), percent.isFinite, (0.0...100.0).contains(percent) else { continue }
                let pct = percent / 100.0
                let isWeekly = bucketName.lowercased().contains("weekly")
                let window = isWeekly ? "weekly" : "5h"
                let bucketId = "\(groupName.lowercased().prefix(3))-\(window)"

                let bucket = QuotaBucket(
                    id: bucketId,
                    name: bucketName,
                    window: window,
                    remainingFraction: pct,
                    resetTime: parseDate(resetStr),
                    rawResetTime: resetStr
                )

                if groupDict[groupName] == nil {
                    groupDict[groupName] = []
                }
                groupDict[groupName]?.append(bucket)
            }

            for (name, bList) in groupDict {
                groups.append(QuotaGroup(name: name, buckets: bList))
            }
        }

        guard !groups.isEmpty else { throw QuotaError.noQuotaData }
        guard Set(groups.map(\.id)).count == groups.count else { throw QuotaError.ambiguousGroups }
        let desc = resp.command?.data?.description
        return QuotaSnapshot(fetchedAt: fetchedAt, description: desc, groups: groups)
    }

    // MARK: - Caching

    private func saveCachedSnapshot(data: Data, fetchedAt: Date) {
        defaults.set(data, forKey: cacheKey)
        defaults.set(fetchedAt.timeIntervalSince1970, forKey: cacheDateKey)
    }

    private func loadCachedSnapshot() -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: cacheKey) else {
            return nil
        }
        let fetchedAt = defaults.object(forKey: cacheDateKey) == nil
            ? Date.distantPast : Date(timeIntervalSince1970: defaults.double(forKey: cacheDateKey))
        return try? parseQuotaJSON(data: data, fetchedAt: fetchedAt)
    }
}
