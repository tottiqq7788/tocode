import Foundation

enum ModelRelayMetricsRange: String, CaseIterable {
    case sixHours
    case week
    case month

    var title: String {
        switch self {
        case .sixHours: return "近六小时"
        case .week: return "近一周"
        case .month: return "近一个月"
        }
    }
}

struct ModelRelayCallEvent: Equatable {
    let timestamp: Date
    let route: String
    let providerID: UUID?
    let providerName: String?
    let publishedModel: String
    let upstreamModel: String?
    let status: Int?
    let durationMs: Int
    let ok: Bool
}

struct ModelRelayChartPoint: Equatable {
    let start: Date
    let count: Int
}

protocol ModelRelayCallMetricsRecording: AnyObject {
    var lastUsedProviderID: UUID? { get }
    var callsLogURL: URL { get }
    func record(_ event: ModelRelayCallEvent)
    func series(providerID: UUID, range: ModelRelayMetricsRange, now: Date) -> [ModelRelayChartPoint]
    func ensureTodayLogFile() throws -> URL
}

struct ModelRelayMetricsState: Codable, Equatable {
    var version: Int = 1
    var lastUsedProviderID: UUID?
    var fineBuckets: [String: [String: Int]] = [:]
    var dailyBuckets: [String: [String: Int]] = [:]
    var logDay: String?
}

final class ModelRelayCallMetricsStore: ModelRelayCallMetricsRecording {
    let callsLogURL: URL
    let metricsURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private let lock = NSLock()
    private var state: ModelRelayMetricsState
    private var isoDayFormatter: DateFormatter
    private var detailFormatter: ISO8601DateFormatter

    var lastUsedProviderID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return state.lastUsedProviderID
    }

    init(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            calendar.locale = Locale(identifier: "en_US_POSIX")
            return calendar
        }()
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        let directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.tocode.app", isDirectory: true)
        self.callsLogURL = directory.appendingPathComponent("model-relay-calls.log", isDirectory: false)
        self.metricsURL = directory.appendingPathComponent("model-relay-metrics.json", isDirectory: false)

        let day = DateFormatter()
        day.calendar = calendar
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        self.isoDayFormatter = day

        let detail = ISO8601DateFormatter()
        detail.formatOptions = [.withInternetDateTime]
        self.detailFormatter = detail

        if let data = try? Data(contentsOf: metricsURL),
           let decoded = try? JSONDecoder().decode(ModelRelayMetricsState.self, from: data),
           decoded.version == 1 {
            self.state = decoded
        } else {
            self.state = ModelRelayMetricsState()
        }
        rotateLogIfNeeded(now: Date(), persist: true)
    }

    func record(_ event: ModelRelayCallEvent) {
        lock.lock()
        defer { lock.unlock() }
        rotateLogIfNeeded(now: event.timestamp, persist: false)
        appendDetailLocked(event)
        bumpBucketsLocked(event)
        if let providerID = event.providerID {
            state.lastUsedProviderID = providerID
        }
        pruneBucketsLocked(now: event.timestamp)
        persistMetricsLocked()
    }

    func series(providerID: UUID, range: ModelRelayMetricsRange, now: Date = Date()) -> [ModelRelayChartPoint] {
        lock.lock()
        defer { lock.unlock() }
        let providerKey = providerID.uuidString.lowercased()
        switch range {
        case .sixHours:
            return fineSeriesLocked(providerKey: providerKey, now: now)
        case .week:
            return dailySeriesLocked(providerKey: providerKey, now: now, days: 7)
        case .month:
            return weeklySeriesLocked(providerKey: providerKey, now: now, weeks: 5)
        }
    }

    func ensureTodayLogFile() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        rotateLogIfNeeded(now: Date(), persist: true)
        if !fileManager.fileExists(atPath: callsLogURL.path) {
            try ensureDirectoryLocked()
            guard fileManager.createFile(
                atPath: callsLogURL.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw ModelRelayError.configurationCorrupt
            }
        } else {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: callsLogURL.path
            )
        }
        return callsLogURL
    }

    private func rotateLogIfNeeded(now: Date, persist: Bool) {
        let day = isoDayFormatter.string(from: now)
        guard state.logDay != day else { return }
        state.logDay = day
        try? ensureDirectoryLocked()
        try? Data().write(to: callsLogURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: callsLogURL.path
        )
        if persist {
            persistMetricsLocked()
        }
    }

    private func appendDetailLocked(_ event: ModelRelayCallEvent) {
        try? ensureDirectoryLocked()
        let fields = [
            "ts=\(detailFormatter.string(from: event.timestamp))",
            "route=\(sanitize(event.route))",
            "providerId=\(event.providerID?.uuidString.lowercased() ?? "-")",
            "providerName=\(sanitize(event.providerName ?? "-"))",
            "publishedModel=\(sanitize(event.publishedModel))",
            "upstreamModel=\(sanitize(event.upstreamModel ?? "-"))",
            "status=\(event.status.map(String.init) ?? "-")",
            "durationMs=\(event.durationMs)",
            "ok=\(event.ok ? "1" : "0")"
        ]
        let line = fields.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: callsLogURL.path) {
            fileManager.createFile(
                atPath: callsLogURL.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
            return
        }
        guard let handle = try? FileHandle(forWritingTo: callsLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: callsLogURL.path
        )
    }

    private func bumpBucketsLocked(_ event: ModelRelayCallEvent) {
        guard let providerID = event.providerID else { return }
        let providerKey = providerID.uuidString.lowercased()
        let fineKey = fineBucketKey(for: event.timestamp)
        var fine = state.fineBuckets[providerKey] ?? [:]
        fine[fineKey, default: 0] += 1
        state.fineBuckets[providerKey] = fine

        let dayKey = isoDayFormatter.string(from: event.timestamp)
        var daily = state.dailyBuckets[providerKey] ?? [:]
        daily[dayKey, default: 0] += 1
        state.dailyBuckets[providerKey] = daily
    }

    private func pruneBucketsLocked(now: Date) {
        let fineCutoff = now.addingTimeInterval(-6 * 60 * 60 - 10 * 60)
        let dayCutoff = calendar.date(byAdding: .day, value: -31, to: startOfDay(now)) ?? now
        for (provider, buckets) in state.fineBuckets {
            state.fineBuckets[provider] = buckets.filter { key, _ in
                guard let date = fineBucketDate(key) else { return false }
                return date >= fineCutoff
            }
        }
        for (provider, buckets) in state.dailyBuckets {
            state.dailyBuckets[provider] = buckets.filter { key, _ in
                guard let date = isoDayFormatter.date(from: key) else { return false }
                return date >= dayCutoff
            }
        }
    }

    private func fineSeriesLocked(providerKey: String, now: Date) -> [ModelRelayChartPoint] {
        let buckets = state.fineBuckets[providerKey] ?? [:]
        let end = floorToTenMinutes(now)
        return (0..<36).reversed().map { offset -> ModelRelayChartPoint in
            let start = end.addingTimeInterval(TimeInterval(-offset * 10 * 60))
            let key = fineBucketKey(for: start)
            return ModelRelayChartPoint(start: start, count: buckets[key] ?? 0)
        }
    }

    private func dailySeriesLocked(providerKey: String, now: Date, days: Int) -> [ModelRelayChartPoint] {
        let buckets = state.dailyBuckets[providerKey] ?? [:]
        let today = startOfDay(now)
        return (0..<days).reversed().map { offset -> ModelRelayChartPoint in
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = isoDayFormatter.string(from: start)
            return ModelRelayChartPoint(start: start, count: buckets[key] ?? 0)
        }
    }

    private func weeklySeriesLocked(providerKey: String, now: Date, weeks: Int) -> [ModelRelayChartPoint] {
        let buckets = state.dailyBuckets[providerKey] ?? [:]
        let thisWeek = startOfWeek(now)
        return (0..<weeks).reversed().map { offset -> ModelRelayChartPoint in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) ?? thisWeek
            var total = 0
            for dayOffset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
                total += buckets[isoDayFormatter.string(from: day)] ?? 0
            }
            return ModelRelayChartPoint(start: weekStart, count: total)
        }
    }

    private func persistMetricsLocked() {
        try? ensureDirectoryLocked()
        guard let data = try? JSONEncoder().encode(state) else { return }
        let temporary = metricsURL.deletingLastPathComponent()
            .appendingPathComponent(".\(metricsURL.lastPathComponent).tocode-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else { return }
        do {
            if fileManager.fileExists(atPath: metricsURL.path) {
                _ = try fileManager.replaceItemAt(
                    metricsURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: metricsURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: metricsURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
        }
    }

    private func ensureDirectoryLocked() throws {
        try fileManager.createDirectory(
            at: callsLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    private func fineBucketKey(for date: Date) -> String {
        let floored = floorToTenMinutes(date)
        return detailFormatter.string(from: floored)
    }

    private func fineBucketDate(_ key: String) -> Date? {
        detailFormatter.date(from: key)
    }

    private func floorToTenMinutes(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = (components.minute ?? 0) / 10 * 10
        var floored = DateComponents()
        floored.year = components.year
        floored.month = components.month
        floored.day = components.day
        floored.hour = components.hour
        floored.minute = minute
        floored.second = 0
        return calendar.date(from: floored) ?? date
    }

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func startOfWeek(_ date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? startOfDay(date)
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: " ", with: "_")
    }
}
