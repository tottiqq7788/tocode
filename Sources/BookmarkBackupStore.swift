import Foundation

struct BookmarkBackupStore {
    let directoryURL: URL
    let packFileURL: URL
    let slotsDirectoryURL: URL

    static var live: BookmarkBackupStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("com.tocode.app/bookmark-backups", isDirectory: true)
        return BookmarkBackupStore(directoryURL: directory)
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.packFileURL = directoryURL.appendingPathComponent("pack.json")
        self.slotsDirectoryURL = directoryURL.appendingPathComponent("slots", isDirectory: true)
    }

    func load() -> BookmarkBackupPack {
        guard let data = try? Data(contentsOf: packFileURL),
              let pack = try? JSONDecoder().decode(BookmarkBackupPack.self, from: data) else {
            return .empty
        }
        return pack
    }

    func save(_ pack: BookmarkBackupPack) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directoryURL.path)
        try fm.createDirectory(at: slotsDirectoryURL, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: slotsDirectoryURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pack)
        let temporary = directoryURL.appendingPathComponent("pack.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
        _ = try fm.replaceItemAt(packFileURL, withItemAt: temporary)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: packFileURL.path)

        let keepDays = Set(pack.slots.map(\.day))
        if let existing = try? fm.contentsOfDirectory(at: slotsDirectoryURL, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "json" {
                let day = url.deletingPathExtension().lastPathComponent
                if !keepDays.contains(day) {
                    try? fm.removeItem(at: url)
                }
            }
        }
        for slot in pack.slots {
            let slotURL = slotsDirectoryURL.appendingPathComponent("\(slot.day).json")
            let slotData = try encoder.encode(slot)
            let slotTmp = slotsDirectoryURL.appendingPathComponent("\(slot.day).\(UUID().uuidString).tmp")
            try slotData.write(to: slotTmp, options: .atomic)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: slotTmp.path)
            _ = try fm.replaceItemAt(slotURL, withItemAt: slotTmp)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: slotURL.path)
        }
    }
}
