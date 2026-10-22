import AppKit
import Foundation

/// 遥控/关联通道诊断：本地 JSONL，不含 token、正文、密钥。
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    private let fileManager: FileManager
    private let directoryURL: URL
    private let lock = NSLock()
    private let dayFormatter: DateFormatter
    private let tsFormatter: ISO8601DateFormatter
    private var corr = UUID().uuidString.lowercased()
    private static let maxFileBytes = 8 * 1024 * 1024
    private static let keepDays = 7
    private static let blockedKeys: Set<String> = [
        "token", "device_token", "link_token", "authorization", "binding_key",
        "binding_key_digest", "text", "content", "body", "path", "caption",
        "bytes", "data", "password", "secret",
    ]

    var folderURL: URL { directoryURL }

    init(home: String = NSHomeDirectory(), fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.tocode.app/diagnostics", isDirectory: true)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyyMMdd"
        self.dayFormatter = day
        let ts = ISO8601DateFormatter()
        ts.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.tsFormatter = ts
    }

    func bumpConnectionCorr() -> String {
        lock.lock()
        defer { lock.unlock() }
        corr = UUID().uuidString.lowercased()
        return corr
    }

    func currentCorr() -> String {
        lock.lock()
        defer { lock.unlock() }
        return corr
    }

    func event(
        _ name: String,
        linkID: String? = nil,
        deviceID: String? = nil,
        corr: String? = nil,
        detail: [String: Any] = [:]
    ) {
        var row: [String: Any] = [
            "ts": tsFormatter.string(from: Date()),
            "side": "mac",
            "event": name,
            "corr": corr ?? currentCorr(),
        ]
        if let linkID, !linkID.isEmpty { row["link_id"] = linkID }
        if let deviceID, !deviceID.isEmpty { row["device_id"] = deviceID }
        let cleaned = Self.sanitize(detail)
        if !cleaned.isEmpty { row["detail"] = cleaned }
        append(row)
    }

    func openInFinder() {
        lock.lock()
        try? ensureDirectoryLocked()
        let url = directoryURL
        lock.unlock()
        NSWorkspace.shared.open(url)
    }

    static func sanitize(_ detail: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in detail {
            let lower = key.lowercased()
            if blockedKeys.contains(lower) { continue }
            if lower.contains("token") || lower.contains("secret") || lower.contains("password") { continue }
            switch value {
            case let text as String:
                if text.count > 240 {
                    out[key] = String(text.prefix(240))
                } else {
                    out[key] = text
                }
            case let number as NSNumber:
                out[key] = number
            case let flag as Bool:
                out[key] = flag
            case let nested as [String: Any]:
                let child = sanitize(nested)
                if !child.isEmpty { out[key] = child }
            case let list as [Any]:
                out[key] = list.prefix(20).map { item -> Any in
                    if let text = item as? String { return String(text.prefix(80)) }
                    if let number = item as? NSNumber { return number }
                    return String(describing: item).prefix(80)
                }
            default:
                out[key] = String(describing: value).prefix(80)
            }
        }
        return out
    }

    private func append(_ row: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { return }
        do {
            try ensureDirectoryLocked()
            pruneOldLocked()
            let file = fileURLLocked(for: Date())
            if !fileManager.fileExists(atPath: file.path) {
                fileManager.createFile(
                    atPath: file.path,
                    contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]
                )
            }
            if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > Self.maxFileBytes {
                return
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: file.path
            )
        } catch {
            return
        }
    }

    private func fileURLLocked(for date: Date) -> URL {
        directoryURL.appendingPathComponent("mac-\(dayFormatter.string(from: date)).jsonl")
    }

    private func ensureDirectoryLocked() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    private func pruneOldLocked() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: Date()) ?? Date.distantPast
        for url in items where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? cutoff
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
