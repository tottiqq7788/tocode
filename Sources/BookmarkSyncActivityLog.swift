import Foundation

/// 本机会话内的书签同步活动日志（内存环形缓冲 + 可选落盘，不含密钥明文）。
final class BookmarkSyncActivityLog: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let date: Date
        let message: String
    }

    static let defaultCapacity = 2000

    private let lock = NSLock()
    private let capacity: Int
    private let fileURL: URL?
    private var stored: [Entry] = []
    /// 在持锁外回调；订阅方若改 UI 须自行切回主线程。
    var onChange: (() -> Void)?

    init(
        capacity: Int = BookmarkSyncActivityLog.defaultCapacity,
        fileURL: URL? = BookmarkSyncActivityLog.defaultFileURL()
    ) {
        self.capacity = max(1, capacity)
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.tocode.app/bookmark-sync-activity.log")
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ message: String) {
        let cleaned = Self.sanitize(message)
        guard !cleaned.isEmpty else { return }
        let entry = Entry(date: Date(), message: cleaned)
        lock.lock()
        stored.append(entry)
        if stored.count > capacity {
            stored.removeFirst(stored.count - capacity)
        }
        lock.unlock()
        appendToFile(entry)
        onChange?()
    }

    func clear() {
        lock.lock()
        stored.removeAll(keepingCapacity: true)
        lock.unlock()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        onChange?()
    }

    /// 供 CLI：读内存；若为空再读落盘尾部。
    func dumpText(maxLines: Int = 200) -> String {
        let memory = renderedText()
        if !entries.isEmpty {
            let lines = memory.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= maxLines { return memory }
            return lines.suffix(maxLines).joined(separator: "\n")
        }
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return memory
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func appendToFile(_ entry: Entry) {
        guard let fileURL else { return }
        let line = "[\(Self.timeFormatter.string(from: entry.date))] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func renderedText(nowFormatter: DateFormatter = BookmarkSyncActivityLog.timeFormatter) -> String {
        let snapshot = entries
        if snapshot.isEmpty {
            return "尚无同步记录。连接浏览器扩展或发生书签变更后会显示在这里。"
        }
        return snapshot.map { entry in
            "[\(nowFormatter.string(from: entry.date))] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// 去掉可能误入的密钥/密文片段。
    static func sanitize(_ message: String) -> String {
        var text = message
        let patterns = [
            #"密钥[：:]\s*\S+"#,
            #"secret[：:=\s]+\S+"#,
            #"ciphertext[：:=\s]+\S+"#,
            #"verifier[：:=\s]+\S+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: range,
                    withTemplate: "[已隐藏]"
                )
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
