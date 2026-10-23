import Foundation

enum BookmarkFolderKind: String, Codable, Equatable, Comparable {
    case toolbar
    case other
    case mobile
    case named

    private var rank: Int {
        switch self {
        case .toolbar: return 0
        case .other: return 1
        case .mobile: return 2
        case .named: return 3
        }
    }

    static func < (lhs: BookmarkFolderKind, rhs: BookmarkFolderKind) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct BookmarkFolderPath: Codable, Equatable, Hashable {
    var kind: BookmarkFolderKind
    /// named 时的文件夹路径段；toolbar/other/mobile 可为空。
    var segments: [String]

    var sortKey: String {
        "\(kind.rawValue)|\(segments.joined(separator: "/"))"
    }
}

struct BookmarkEntry: Codable, Equatable, Identifiable {
    var id: String
    var url: String
    var title: String
    var folder: BookmarkFolderPath
    /// 相对父文件夹的夹内顺序（0-based）。
    var siblingIndex: Int
    var updatedAt: Double

    init(
        id: String = UUID().uuidString,
        url: String,
        title: String,
        folder: BookmarkFolderPath,
        siblingIndex: Int = 0,
        updatedAt: Double
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.siblingIndex = siblingIndex
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, folder, siblingIndex, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        folder = try container.decode(BookmarkFolderPath.self, forKey: .folder)
        siblingIndex = try container.decodeIfPresent(Int.self, forKey: .siblingIndex) ?? 0
        updatedAt = try container.decode(Double.self, forKey: .updatedAt)
    }
}

/// 空文件夹或仅作容器的文件夹；按路径键唯一。
struct BookmarkFolderRecord: Codable, Equatable {
    var path: BookmarkFolderPath
    var siblingIndex: Int
    var updatedAt: Double

    var pathKey: String { path.sortKey }
}

struct BookmarkTombstone: Codable, Equatable {
    var url: String
    var deletedAt: Double
}

struct BookmarkLedgerSnapshot: Codable, Equatable {
    var version: Int
    var entries: [BookmarkEntry]
    var folders: [BookmarkFolderRecord]
    var tombstones: [BookmarkTombstone]
    var remoteRevision: Int
    var joinedBrowserKeys: [String]

    static let empty = BookmarkLedgerSnapshot(
        version: 1,
        entries: [],
        folders: [],
        tombstones: [],
        remoteRevision: 0,
        joinedBrowserKeys: []
    )

    enum CodingKeys: String, CodingKey {
        case version, entries, folders, tombstones, remoteRevision, joinedBrowserKeys
    }

    init(
        version: Int,
        entries: [BookmarkEntry],
        folders: [BookmarkFolderRecord] = [],
        tombstones: [BookmarkTombstone],
        remoteRevision: Int,
        joinedBrowserKeys: [String]
    ) {
        self.version = version
        self.entries = entries
        self.folders = folders
        self.tombstones = tombstones
        self.remoteRevision = remoteRevision
        self.joinedBrowserKeys = joinedBrowserKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([BookmarkEntry].self, forKey: .entries)
        folders = try container.decodeIfPresent([BookmarkFolderRecord].self, forKey: .folders) ?? []
        tombstones = try container.decode([BookmarkTombstone].self, forKey: .tombstones)
        remoteRevision = try container.decode(Int.self, forKey: .remoteRevision)
        joinedBrowserKeys = try container.decode([String].self, forKey: .joinedBrowserKeys)
    }

    /// 布局指纹：用于判断浏览器是否已对齐账本。
    func layoutFingerprint(for url: String) -> String? {
        guard let entry = entries.first(where: { $0.url == url }) else { return nil }
        return "\(entry.folder.sortKey)|\(entry.siblingIndex)|\(entry.title)"
    }
}

struct BookmarkTreeLayout: Equatable {
    var entries: [BookmarkEntry]
    var folders: [BookmarkFolderRecord]
}

