import Foundation

struct BookmarkLedgerStore {
    let fileURL: URL

    static var live: BookmarkLedgerStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return BookmarkLedgerStore(
            fileURL: base.appendingPathComponent("com.tocode.app/bookmark-ledger.json")
        )
    }

    func load() -> BookmarkLedgerSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        guard let snapshot = try? JSONDecoder().decode(BookmarkLedgerSnapshot.self, from: data) else {
            BookmarkCorruptFile.quarantine(fileURL)
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: BookmarkLedgerSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let temporary = directory.appendingPathComponent("bookmark-ledger.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}

/// 读不懂的文件改名留存，不让后续保存把它覆盖掉。
enum BookmarkCorruptFile {
    @discardableResult
    static func quarantine(_ url: URL, now: Date = Date()) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let target = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            NSLog("Tocode 书签文件无法解析，已留存为 %@", target.lastPathComponent)
            return target
        } catch {
            NSLog("Tocode 书签文件无法解析，留存失败：%@", error.localizedDescription)
            return nil
        }
    }
}
