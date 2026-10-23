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
    var updatedAt: Double

    init(id: String = UUID().uuidString, url: String, title: String, folder: BookmarkFolderPath, updatedAt: Double) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.updatedAt = updatedAt
    }
}

struct BookmarkTombstone: Codable, Equatable {
    var url: String
    var deletedAt: Double
}

struct BookmarkLedgerSnapshot: Codable, Equatable {
    var version: Int
    var entries: [BookmarkEntry]
    var tombstones: [BookmarkTombstone]
    var remoteRevision: Int
    var joinedBrowserKeys: [String]

    static let empty = BookmarkLedgerSnapshot(
        version: 1,
        entries: [],
        tombstones: [],
        remoteRevision: 0,
        joinedBrowserKeys: []
    )
}

enum BookmarkLedgerMerge {
    /// 初次并集 / 后加入：不因缺失而删除；同网址收成一条。
    static func unionMerge(
        ledger: BookmarkLedgerSnapshot,
        incoming: [BookmarkEntry],
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
                // 后加入：墓碑不挡并集加回（计划接受的结果）。
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

        var joined = ledger.joinedBrowserKeys
        if let browserKey, !joined.contains(browserKey) {
            joined.append(browserKey)
        }

        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: byURL.values.sorted { $0.url < $1.url },
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
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    /// 改标题 / 文件夹；网址不变。
    static func updateEntry(
        urlRaw: String,
        title: String?,
        folder: BookmarkFolderPath?,
        updatedAt: Double,
        in ledger: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        guard let url = BookmarkURL.canonicalize(urlRaw) else { return ledger }
        var entries = ledger.entries
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return ledger }
        if let title { entries[index].title = title }
        if let folder { entries[index].folder = folder }
        entries[index].updatedAt = updatedAt
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: entries,
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
        updatedAt: Double,
        in ledger: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        guard let oldURL = BookmarkURL.canonicalize(oldRaw),
              let newURL = BookmarkURL.canonicalize(newRaw) else {
            return ledger
        }
        if oldURL == newURL {
            return updateEntry(urlRaw: oldURL, title: title, folder: folder, updatedAt: updatedAt, in: ledger)
        }

        var byURL = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.url, $0) })
        var tombstones = Dictionary(uniqueKeysWithValues: ledger.tombstones.map { ($0.url, $0) })
        let old = byURL.removeValue(forKey: oldURL)
        tombstones[oldURL] = BookmarkTombstone(url: oldURL, deletedAt: updatedAt)
        tombstones.removeValue(forKey: newURL)

        if var existing = byURL[newURL] {
            if let title, updatedAt >= existing.updatedAt {
                existing.title = title
                existing.updatedAt = updatedAt
            }
            if let folder, updatedAt >= existing.updatedAt {
                existing.folder = folder
            }
            byURL[newURL] = existing
        } else {
            let created = BookmarkEntry(
                id: old?.id ?? UUID().uuidString,
                url: newURL,
                title: title ?? old?.title ?? newURL,
                folder: folder ?? old?.folder ?? BookmarkFolderPath(kind: .other, segments: []),
                updatedAt: updatedAt
            )
            byURL[newURL] = created
        }

        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: byURL.values.sorted { $0.url < $1.url },
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
        let merged = unionMerge(ledger: local, incoming: remote.entries, browserKey: nil)
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
        // 墓碑盖掉仍在的条目（两边都已加入后的删除）。
        let entries = merged.entries.filter { tombstones[$0.url] == nil }
        var joined = Set(local.joinedBrowserKeys)
        remote.joinedBrowserKeys.forEach { joined.insert($0) }
        return BookmarkLedgerSnapshot(
            version: max(local.version, remote.version),
            entries: entries,
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            remoteRevision: max(local.remoteRevision, remote.remoteRevision),
            joinedBrowserKeys: joined.sorted()
        )
    }

    static func prefer(_ a: BookmarkEntry, _ b: BookmarkEntry) -> BookmarkEntry {
        var winner = a
        if b.folder.kind < a.folder.kind
            || (b.folder.kind == a.folder.kind && b.folder.sortKey < a.folder.sortKey && a.folder.kind == .named) {
            winner.folder = b.folder
        } else if a.folder.kind == .named, b.folder.kind == .named, b.folder.sortKey < a.folder.sortKey {
            winner.folder = b.folder
        }
        if b.updatedAt >= a.updatedAt {
            winner.title = b.title
            winner.updatedAt = b.updatedAt
            if b.folder.kind < winner.folder.kind || b.folder.kind == winner.folder.kind {
                // 较新且文件夹同类或更优时采用较新文件夹
                if b.folder.kind < a.folder.kind || (b.folder.kind == a.folder.kind && b.updatedAt >= a.updatedAt) {
                    winner.folder = b.folder
                }
            }
        }
        winner.id = a.id
        winner.url = a.url
        return winner
    }

    /// 从浏览器原始树节点解析条目（扩展上报格式）。
    static func entries(fromBrowserNodes nodes: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> [BookmarkEntry] {
        var result: [BookmarkEntry] = []
        func walk(_ node: [String: Any], folder: BookmarkFolderPath) {
            let type = node["type"] as? String ?? ""
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
            result.append(
                BookmarkEntry(
                    id: (node["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                    url: canonical,
                    title: (title?.isEmpty == false ? title! : canonical),
                    folder: folder,
                    updatedAt: updated
                )
            )
        }
        for node in nodes {
            walk(node, folder: BookmarkFolderPath(kind: .other, segments: []))
        }
        return result
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
