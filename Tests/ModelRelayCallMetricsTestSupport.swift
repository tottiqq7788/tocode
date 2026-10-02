import Foundation

final class MemoryModelRelayCallMetricsStore: ModelRelayCallMetricsRecording {
    private(set) var events: [ModelRelayCallEvent] = []
    private(set) var lastUsedProviderID: UUID?
    private let directory: URL
    let callsLogURL: URL
    private var logDay: String?
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tocode-relay-metrics-\(UUID().uuidString)",
        isDirectory: true
    )) {
        self.directory = directory
        self.callsLogURL = directory.appendingPathComponent("model-relay-calls.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(_ event: ModelRelayCallEvent) {
        rotateIfNeeded(now: event.timestamp)
        events.append(event)
        if let providerID = event.providerID {
            lastUsedProviderID = providerID
        }
        let line = [
            "ts=\(ISO8601DateFormatter().string(from: event.timestamp))",
            "route=\(event.route)",
            "providerId=\(event.providerID?.uuidString.lowercased() ?? "-")",
            "providerName=\(event.providerName ?? "-")",
            "publishedModel=\(event.publishedModel)",
            "upstreamModel=\(event.upstreamModel ?? "-")",
            "status=\(event.status.map(String.init) ?? "-")",
            "durationMs=\(event.durationMs)",
            "ok=\(event.ok ? "1" : "0")"
        ].joined(separator: " ") + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: callsLogURL.path),
               let handle = try? FileHandle(forWritingTo: callsLogURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                FileManager.default.createFile(
                    atPath: callsLogURL.path,
                    contents: data,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]
                )
            }
        }
    }

    func series(providerID: UUID, range: ModelRelayMetricsRange, now: Date) -> [ModelRelayChartPoint] {
        let matching = events.filter { $0.providerID == providerID }
        return [ModelRelayChartPoint(start: now, count: matching.count)]
    }

    func ensureTodayLogFile() throws -> URL {
        rotateIfNeeded(now: Date())
        if !FileManager.default.fileExists(atPath: callsLogURL.path) {
            FileManager.default.createFile(
                atPath: callsLogURL.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }
        return callsLogURL
    }

    private func rotateIfNeeded(now: Date) {
        let day = dayFormatter.string(from: now)
        guard logDay != day else { return }
        logDay = day
        events.removeAll()
        try? Data().write(to: callsLogURL, options: .atomic)
    }
}
