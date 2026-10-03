import Foundation

protocol WeChatLegacyArchiveFileManaging {
    func itemType(at url: URL) throws -> FileAttributeType?
    func removeItem(at url: URL) throws
}

struct SystemWeChatLegacyArchiveFileManager: WeChatLegacyArchiveFileManaging {
    private let fileManager = FileManager.default

    func itemType(at url: URL) throws -> FileAttributeType? {
        guard fileManager.fileExists(atPath: url.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return nil
        }
        return try fileManager.attributesOfItem(atPath: url.path)[.type]
            as? FileAttributeType
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

enum WeChatArchiveMigrationError: Error, LocalizedError {
    case unexpectedLegacyItem
    case removalIncomplete

    var errorDescription: String? {
        switch self {
        case .unexpectedLegacyItem:
            return "旧微信归档路径存在，但不是文件夹或符号链接，未自动删除。"
        case .removalIncomplete:
            return "旧微信归档目录删除后仍然存在。"
        }
    }
}

struct WeChatArchiveMigration {
    static let completionKey = "tocode.wechat.roleArchiveMigrationCompleted"

    private let fileSystem: WeChatLegacyArchiveFileManaging
    private let homeDirectory: URL
    private let defaults: UserDefaults

    init(
        fileSystem: WeChatLegacyArchiveFileManaging =
            SystemWeChatLegacyArchiveFileManager(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = TocodePreferences.shared
    ) {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.defaults = defaults
    }

    @discardableResult
    func runIfNeeded() throws -> Bool {
        guard !defaults.bool(forKey: Self.completionKey) else {
            return false
        }
        let legacy = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("wechat", isDirectory: true)
        if let type = try fileSystem.itemType(at: legacy) {
            guard type == .typeDirectory || type == .typeSymbolicLink else {
                throw WeChatArchiveMigrationError.unexpectedLegacyItem
            }
            // FileManager 删除符号链接本身，不遍历它指向的目录。
            try fileSystem.removeItem(at: legacy)
        }
        guard try fileSystem.itemType(at: legacy) == nil else {
            throw WeChatArchiveMigrationError.removalIncomplete
        }
        defaults.set(true, forKey: Self.completionKey)
        return true
    }
}
