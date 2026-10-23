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

enum BookmarkLedgerMerge {
    /// 初次并集 / 后加入：不因缺失而删除；同网址收成一条（LWW）。
    static func unionMerge(
        ledger: BookmarkLedgerSnapshot,
        incoming: [BookmarkEntry],
        incomingFolders: [BookmarkFolderRecord] = [],
        browserKey: String?,
        now: Double = Date().timeIntervalSince1970
    ) -> BookmarkLedgerSnapshot {
        var byURL: [String: BookmarkEntry] = [:]
        for entry in ledger.entries {
            byURL[entry.url] = entry
        }

        var tombstones = Dictionary(uniqueKeysWithValues: ledger.tombstones.map { ($0.url, $0) })
        let alreadyJoined = browserKey.map { ledger.joinedBrowserKeys.contains($0) } ?? true

        for raw in incoming {
            guard let url = BookmarkURL.canonicalize(raw.url) else { continue }
            var candidate = raw
            candidate.url = url

            if !alreadyJoined {
                tombstones.removeValue(forKey: url)
            } else if tombstones[url] != nil {
                continue
            }

            if let existing = byURL[url] {
                byURL[url] = prefer(existing, candidate)
            } else {
                if candidate.id.isEmpty {
                    candidate.id = UUID().uuidString
                }
                byURL[url] = candidate
            }
        }

        var byFolder = Dictionary(uniqueKeysWithValues: ledger.folders.map { ($0.pathKey, $0) })
        for folder in incomingFolders {
            let key = folder.pathKey
            if let existing = byFolder[key] {
                byFolder[key] = preferFolder(existing, folder)
            } else {
                byFolder[key] = folder
            }
        }

        var joined = ledger.joinedBrowserKeys
        if let browserKey, !joined.contains(browserKey) {
            joined.append(browserKey)
        }

        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: byURL.values.sorted { $0.url < $1.url },
            folders: byFolder.values.sorted { $0.pathKey < $1.pathKey },
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: joined
        )
    }

    /// 加入完成后的删除：写入墓碑并去掉条目。
    static func deleteURL(
        _ urlRaw: String,
        in ledger: BookmarkLedgerSnapshot,
        now: Double = Date().timeIntervalSince1970
    ) -> BookmarkLedgerSnapshot {
        guard let url = BookmarkURL.canonicalize(urlRaw) else { return ledger }
        let entries = ledger.entries.filter { $0.url != url }
        var tombstones = Dictionary(uniqueKeysWithValues: ledger.tombstones.map { ($0.url, $0) })
        tombstones[url] = BookmarkTombstone(url: url, deletedAt: now)
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: entries,
            folders: ledger.folders,
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    /// 改标题 / 文件夹 / 夹内顺序；网址不变。
    static func updateEntry(
        urlRaw: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int?,
        updatedAt: Double,
        in ledger: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        guard let url = BookmarkURL.canonicalize(urlRaw) else { return ledger }
        var entries = ledger.entries
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return ledger }
        if let title { entries[index].title = title }
        if let folder { entries[index].folder = folder }
        if let siblingIndex { entries[index].siblingIndex = siblingIndex }
        entries[index].updatedAt = updatedAt
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: entries,
            folders: ledger.folders,
            tombstones: ledger.tombstones,
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    /// 把旧网址改成新网址；新网址已存在时旧网址进墓碑，保留已存在条。
    static func changeURL(
        from oldRaw: String,
        to newRaw: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int?,
        updatedAt: Double,
        in ledger: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        guard let oldURL = BookmarkURL.canonicalize(oldRaw),
              let newURL = BookmarkURL.canonicalize(newRaw) else {
            return ledger
        }
        if oldURL == newURL {
            return updateEntry(
                urlRaw: oldURL,
                title: title,
                folder: folder,
                siblingIndex: siblingIndex,
                updatedAt: updatedAt,
                in: ledger
            )
        }

        var byURL = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.url, $0) })
        var tombstones = Dictionary(uniqueKeysWithValues: ledger.tombstones.map { ($0.url, $0) })
        let old = byURL.removeValue(forKey: oldURL)
        tombstones[oldURL] = BookmarkTombstone(url: oldURL, deletedAt: updatedAt)
        tombstones.removeValue(forKey: newURL)

        if var existing = byURL[newURL] {
            if updatedAt >= existing.updatedAt {
                if let title { existing.title = title }
                if let folder { existing.folder = folder }
                if let siblingIndex { existing.siblingIndex = siblingIndex }
                existing.updatedAt = updatedAt
            }
            byURL[newURL] = existing
        } else {
            let created = BookmarkEntry(
                id: old?.id ?? UUID().uuidString,
                url: newURL,
                title: title ?? old?.title ?? newURL,
                folder: folder ?? old?.folder ?? BookmarkFolderPath(kind: .other, segments: []),
                siblingIndex: siblingIndex ?? old?.siblingIndex ?? 0,
                updatedAt: updatedAt
            )
            byURL[newURL] = created
        }

        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: byURL.values.sorted { $0.url < $1.url },
            folders: ledger.folders,
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    /// 合并远端解密后的快照（并集 + 墓碑并集，较新墓碑优先）。
    static func mergeRemote(
        local: BookmarkLedgerSnapshot,
        remote: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        let merged = unionMerge(
            ledger: local,
            incoming: remote.entries,
            incomingFolders: remote.folders,
            browserKey: nil
        )
        var tombstones = Dictionary(uniqueKeysWithValues: merged.tombstones.map { ($0.url, $0) })
        for stone in remote.tombstones {
            if let existing = tombstones[stone.url] {
                if stone.deletedAt > existing.deletedAt {
                    tombstones[stone.url] = stone
                }
            } else {
                tombstones[stone.url] = stone
            }
        }
        let entries = merged.entries.filter { tombstones[$0.url] == nil }
        var joined = Set(local.joinedBrowserKeys)
        remote.joinedBrowserKeys.forEach { joined.insert($0) }
        return BookmarkLedgerSnapshot(
            version: max(local.version, remote.version),
            entries: entries,
            folders: merged.folders,
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: max(local.remoteRevision, remote.remoteRevision),
            joinedBrowserKeys: joined.sorted()
        )
    }

    /// 纯 LWW：较新 updatedAt 胜出 title / folder / siblingIndex。
    static func prefer(_ a: BookmarkEntry, _ b: BookmarkEntry) -> BookmarkEntry {
        if b.updatedAt >= a.updatedAt {
            var winner = b
            winner.id = a.id
            winner.url = a.url
            return winner
        }
        return a
    }

    static func preferFolder(_ a: BookmarkFolderRecord, _ b: BookmarkFolderRecord) -> BookmarkFolderRecord {
        b.updatedAt >= a.updatedAt ? b : a
    }

    /// 从浏览器原始树节点解析布局（扩展上报格式）。
    static func layout(fromBrowserNodes nodes: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> BookmarkTreeLayout {
        var entries: [BookmarkEntry] = []
        var folders: [BookmarkFolderRecord] = []

        func walk(_ node: [String: Any], folder: BookmarkFolderPath) {
            let type = node["type"] as? String ?? ""
            let siblingIndex = intValue(node["index"]) ?? 0
            if type == "folder" {
                let title = (node["title"] as? String) ?? ""
                let kind = folderKind(forRootTitle: title, current: folder)
                let next: BookmarkFolderPath
                if folder.kind == .named || (kind == .named && !folder.segments.isEmpty) {
                    next = BookmarkFolderPath(kind: .named, segments: folder.segments + (title.isEmpty ? [] : [title]))
                } else if kind != .named {
                    next = BookmarkFolderPath(kind: kind, segments: [])
                } else {
                    next = BookmarkFolderPath(kind: .named, segments: title.isEmpty ? [] : [title])
                }
                // 根级 toolbar/other/mobile 本身不记为 named 记录；具名夹与其子夹记入。
                if next.kind == .named || !next.segments.isEmpty {
                    let updated = (node["dateAdded"] as? Double).map { $0 / 1000.0 } ?? now
                    folders.append(
                        BookmarkFolderRecord(path: next, siblingIndex: siblingIndex, updatedAt: updated)
                    )
                }
                for child in (node["children"] as? [[String: Any]]) ?? [] {
                    walk(child, folder: next)
                }
                return
            }
            guard type == "bookmark",
                  let url = node["url"] as? String,
                  let canonical = BookmarkURL.canonicalize(url) else {
                return
            }
            let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = (node["dateAdded"] as? Double).map { $0 / 1000.0 } ?? now
            entries.append(
                BookmarkEntry(
                    id: (node["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                    url: canonical,
                    title: (title?.isEmpty == false ? title! : canonical),
                    folder: folder,
                    siblingIndex: siblingIndex,
                    updatedAt: updated
                )
            )
        }
        for node in nodes {
            walk(node, folder: BookmarkFolderPath(kind: .other, segments: []))
        }
        return BookmarkTreeLayout(entries: entries, folders: folders)
    }

    /// 兼容旧调用点。
    static func entries(fromBrowserNodes nodes: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> [BookmarkEntry] {
        layout(fromBrowserNodes: nodes, now: now).entries
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func folderKind(forRootTitle title: String, current: BookmarkFolderPath) -> BookmarkFolderKind {
        if current.kind != .other || !current.segments.isEmpty {
            return current.kind == .other && current.segments.isEmpty ? mapRoot(title) : .named
        }
        return mapRoot(title)
    }

    private static func mapRoot(_ title: String) -> BookmarkFolderKind {
        let lower = title.lowercased()
        if ["书签栏", "bookmarks bar", "bookmarks toolbar", "收藏夹栏", "favourites bar", "favorites bar"].contains(where: { lower == $0 || title == $0 })
            || lower.contains("toolbar") || title.contains("书签栏") || title.contains("收藏夹栏") {
            return .toolbar
        }
        if ["其他书签", "other bookmarks", "其他收藏夹", "other favorites"].contains(where: { lower == $0 || title == $0 })
            || title.contains("其他书签") {
            return .other
        }
        if ["移动设备书签", "mobile bookmarks", "移动收藏夹"].contains(where: { lower == $0 || title == $0 })
            || lower.contains("mobile") {
            return .mobile
        }
        if title.isEmpty || lower == "bookmarks" || title == "书签" || title == "收藏夹" {
            return .other
        }
        return .named
    }
}
