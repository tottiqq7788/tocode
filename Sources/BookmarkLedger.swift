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
            var normalized = entry
            normalized.folder = normalizeFolderPath(entry.folder)
            byURL[normalized.url] = normalized
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

            candidate.folder = normalizeFolderPath(candidate.folder)
            if let existing = byURL[url] {
                var left = existing
                left.folder = normalizeFolderPath(left.folder)
                byURL[url] = prefer(left, candidate)
            } else {
                if candidate.id.isEmpty {
                    candidate.id = UUID().uuidString
                }
                byURL[url] = candidate
            }
        }

        var byFolder: [String: BookmarkFolderRecord] = [:]
        for record in ledger.folders {
            var normalized = record
            normalized.path = normalizeFolderPath(record.path)
            let key = normalized.pathKey
            if let existing = byFolder[key] {
                byFolder[key] = preferFolder(existing, normalized)
            } else {
                byFolder[key] = normalized
            }
        }
        for folder in incomingFolders {
            var normalized = folder
            normalized.path = normalizeFolderPath(folder.path)
            let key = normalized.pathKey
            if let existing = byFolder[key] {
                byFolder[key] = preferFolder(existing, normalized)
            } else {
                byFolder[key] = normalized
            }
        }
        let folders = dropSupersededNamedFolders(Array(byFolder.values))
        let canonical = canonicalizeSiblingIndices(
            entries: Array(byURL.values),
            folders: folders
        )

        var joined = ledger.joinedBrowserKeys
        if let browserKey, !joined.contains(browserKey) {
            joined.append(browserKey)
        }

        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: canonical.entries.sorted { $0.url < $1.url },
            folders: canonical.folders.sorted { $0.pathKey < $1.pathKey },
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: joined
        )
    }

    /// 每个父路径下的直接子书签与子夹：按 siblingIndex → 较新 updatedAt → 稳定键排序后写成 0..n-1。
    static func canonicalizeSiblingIndices(
        entries: [BookmarkEntry],
        folders: [BookmarkFolderRecord]
    ) -> (entries: [BookmarkEntry], folders: [BookmarkFolderRecord]) {
        enum Child {
            case bookmark(Int)
            case folder(Int)
        }

        var entries = entries
        var folders = folders
        var groups: [String: [(index: Int, updatedAt: Double, key: String, child: Child)]] = [:]

        for (i, entry) in entries.enumerated() {
            let parentKey = entry.folder.sortKey
            groups[parentKey, default: []].append(
                (entry.siblingIndex, entry.updatedAt, "b:" + entry.url, .bookmark(i))
            )
        }
        for (i, folder) in folders.enumerated() {
            guard let parent = parentPath(of: folder.path) else { continue }
            groups[parent.sortKey, default: []].append(
                (folder.siblingIndex, folder.updatedAt, "f:" + folder.pathKey, .folder(i))
            )
        }

        for (_, var children) in groups {
            children.sort {
                if $0.index != $1.index { return $0.index < $1.index }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.key < $1.key
            }
            for (newIndex, item) in children.enumerated() {
                switch item.child {
                case .bookmark(let i):
                    entries[i].siblingIndex = newIndex
                case .folder(let i):
                    folders[i].siblingIndex = newIndex
                }
            }
        }
        return (entries, folders)
    }

    /// 子夹的父路径；根级（无 segments）无父。
    static func parentPath(of path: BookmarkFolderPath) -> BookmarkFolderPath? {
        guard !path.segments.isEmpty else { return nil }
        return BookmarkFolderPath(kind: path.kind, segments: Array(path.segments.dropLast()))
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
    /// named 与同路径段的 toolbar/other/mobile 并存时，路径取 rooted（旧账本迁移）。
    static func prefer(_ a: BookmarkEntry, _ b: BookmarkEntry) -> BookmarkEntry {
        let newer = b.updatedAt >= a.updatedAt ? b : a
        var winner = newer
        winner.id = a.id
        winner.url = a.url
        if let rooted = rootedPathPreferring(a.folder, b.folder) {
            winner.folder = rooted
        }
        return winner
    }

    static func preferFolder(_ a: BookmarkFolderRecord, _ b: BookmarkFolderRecord) -> BookmarkFolderRecord {
        b.updatedAt >= a.updatedAt ? b : a
    }

    /// named 与 rooted 同段时取 rooted；否则不干预。
    static func rootedPathPreferring(_ a: BookmarkFolderPath, _ b: BookmarkFolderPath) -> BookmarkFolderPath? {
        let rooted: Set<BookmarkFolderKind> = [.toolbar, .other, .mobile]
        if a.kind == .named, rooted.contains(b.kind), a.segments == b.segments { return b }
        if b.kind == .named, rooted.contains(a.kind), a.segments == b.segments { return a }
        return nil
    }

    /// 丢掉已被 toolbar/other/mobile 同段路径替代的 named 文件夹记录。
    static func dropSupersededNamedFolders(_ folders: [BookmarkFolderRecord]) -> [BookmarkFolderRecord] {
        let rootedSegKeys = Set(
            folders
                .filter { $0.path.kind == .toolbar || $0.path.kind == .other || $0.path.kind == .mobile }
                .map { $0.path.segments.joined(separator: "\u{1f}") }
        )
        return folders.filter { folder in
            guard folder.path.kind == .named else { return true }
            let key = folder.path.segments.joined(separator: "\u{1f}")
            return !rootedSegKeys.contains(key)
        }
    }

    /// 从浏览器原始树节点解析布局（扩展上报格式）。
    /// 书签栏 / 其他书签 / 移动设备书签的子夹保留该根并追加路径段。
    static func layout(fromBrowserNodes nodes: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> BookmarkTreeLayout {
        var entries: [BookmarkEntry] = []
        var folders: [BookmarkFolderRecord] = []

        func walk(_ node: [String: Any], folder: BookmarkFolderPath, underResolvedRoot: Bool) {
            let type = node["type"] as? String ?? ""
            let siblingIndex = intValue(node["index"]) ?? 0
            if type == "folder" {
                let title = (node["title"] as? String) ?? ""
                let segment = title.isEmpty ? [] : [title]
                let next: BookmarkFolderPath
                let nextResolved: Bool
                if !underResolvedRoot {
                    // 浏览器虚拟根（空标题 / Bookmarks）只作容器，子节点仍未进入真实根。
                    if isVirtualBookmarkRootTitle(title) {
                        for child in (node["children"] as? [[String: Any]]) ?? [] {
                            walk(child, folder: folder, underResolvedRoot: false)
                        }
                        return
                    }
                    let kind = mapRoot(title)
                    if kind == .named {
                        next = BookmarkFolderPath(kind: .named, segments: segment)
                    } else {
                        next = BookmarkFolderPath(kind: kind, segments: [])
                    }
                    nextResolved = true
                } else {
                    // 已进入 toolbar/other/mobile/named：子夹保留该根并追加段。
                    next = BookmarkFolderPath(kind: folder.kind, segments: folder.segments + segment)
                    nextResolved = true
                }
                // 根级 toolbar/other/mobile 本身不记；具名夹与各根下的子夹记入。
                if next.kind == .named || !next.segments.isEmpty {
                    let updated = (node["dateAdded"] as? Double).map { $0 / 1000.0 } ?? now
                    folders.append(
                        BookmarkFolderRecord(path: next, siblingIndex: siblingIndex, updatedAt: updated)
                    )
                }
                for child in (node["children"] as? [[String: Any]]) ?? [] {
                    walk(child, folder: next, underResolvedRoot: nextResolved)
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
            walk(node, folder: BookmarkFolderPath(kind: .other, segments: []), underResolvedRoot: false)
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

    private static func isVirtualBookmarkRootTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return title.isEmpty || lower == "bookmarks" || title == "书签" || title == "收藏夹"
    }

    /// 浏览器对书签栏根的各种标题（含 Firefox「书签工具栏」）。
    static func isToolbarAliasTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        if ["书签栏", "书签工具栏", "bookmarks bar", "bookmarks toolbar", "收藏夹栏", "favourites bar", "favorites bar"]
            .contains(where: { lower == $0 || title == $0 }) {
            return true
        }
        return lower.contains("toolbar")
            || title.contains("书签栏")
            || title.contains("书签工具栏")
            || title.contains("收藏夹栏")
    }

    /// 把误记为 other/named 且首段为书签栏别名的路径收成 toolbar + 余下段。
    static func normalizeFolderPath(_ path: BookmarkFolderPath) -> BookmarkFolderPath {
        guard path.kind == .other || path.kind == .named,
              let first = path.segments.first,
              isToolbarAliasTitle(first) else {
            return path
        }
        return BookmarkFolderPath(kind: .toolbar, segments: Array(path.segments.dropFirst()))
    }

    private static func mapRoot(_ title: String) -> BookmarkFolderKind {
        if isToolbarAliasTitle(title) {
            return .toolbar
        }
        let lower = title.lowercased()
        if ["其他书签", "other bookmarks", "其他收藏夹", "other favorites"].contains(where: { lower == $0 || title == $0 })
            || title.contains("其他书签")
            || lower.contains("unfiled")
            || lower.contains("未整理") {
            return .other
        }
        if ["移动设备书签", "mobile bookmarks", "移动收藏夹"].contains(where: { lower == $0 || title == $0 })
            || lower.contains("mobile") {
            return .mobile
        }
        return .named
    }
}
