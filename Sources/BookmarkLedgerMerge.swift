import Foundation

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
            } else if let stone = tombstones[url] {
                // 已加入浏览器并集：墓碑硬挡残留副本。
                // 远程 merge（browserKey == nil）：对称 LWW 复活。
                if browserKey != nil {
                    continue
                }
                if candidate.updatedAt >= stone.deletedAt {
                    tombstones.removeValue(forKey: url)
                } else {
                    continue
                }
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

        var folderTombstones = Dictionary(
            uniqueKeysWithValues: ledger.folderTombstones.map { ($0.pathKey, $0) }
        )

        var byFolder: [String: BookmarkFolderRecord] = [:]
        for record in ledger.folders {
            var normalized = record
            normalized.path = normalizeFolderPath(record.path)
            let key = normalized.pathKey
            if let stone = folderTombstones[key] {
                if normalized.updatedAt >= stone.deletedAt {
                    folderTombstones.removeValue(forKey: key)
                } else {
                    continue
                }
            }
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
            if let stone = folderTombstones[key] {
                // 已加入浏览器：硬挡；远程（browserKey==nil）：对称 LWW。
                if browserKey != nil {
                    continue
                }
                if normalized.updatedAt >= stone.deletedAt {
                    folderTombstones.removeValue(forKey: key)
                } else {
                    continue
                }
            }
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
            folderTombstones: folderTombstones.values.sorted { $0.pathKey < $1.pathKey },
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
                    if entries[i].siblingIndex != newIndex {
                        entries[i].siblingIndex = newIndex
                        // 改序抬时间，避免 409/pull 用同戳旧序盖回。
                        entries[i].updatedAt = max(entries[i].updatedAt, item.updatedAt) + 0.001
                    }
                case .folder(let i):
                    if folders[i].siblingIndex != newIndex {
                        folders[i].siblingIndex = newIndex
                        folders[i].updatedAt = max(folders[i].updatedAt, item.updatedAt) + 0.001
                    }
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
            folderTombstones: ledger.folderTombstones,
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
        var next = BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: entries,
            folders: ledger.folders,
            tombstones: ledger.tombstones,
            folderTombstones: ledger.folderTombstones,
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
        if let folder {
            next = upsertFolderAncestors(folder, siblingIndex: nil, updatedAt: updatedAt, in: next)
        }
        return next
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

        var next = BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: byURL.values.sorted { $0.url < $1.url },
            folders: ledger.folders,
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            folderTombstones: ledger.folderTombstones,
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
        let resolvedFolder = folder ?? old?.folder
        if let resolvedFolder {
            next = upsertFolderAncestors(
                resolvedFolder,
                siblingIndex: nil,
                updatedAt: updatedAt,
                in: next
            )
        }
        return next
    }

    /// 合并远端解密后的快照（并集 + 墓碑并集，较新墓碑优先）。
    static func mergeRemote(
        local: BookmarkLedgerSnapshot,
        remote: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        let localFoldersByKey = Dictionary(uniqueKeysWithValues: local.folders.map { ($0.pathKey, $0) })
        // 先并夹墓碑，再 union，避免远程空夹复活已删路径。
        // 若本地已有更新的夹记录（create 晚于墓碑），丢弃该墓碑，避免 pull 盖掉刚建的空夹。
        var folderTombstones = Dictionary(
            uniqueKeysWithValues: local.folderTombstones.map { ($0.pathKey, $0) }
        )
        for stone in remote.folderTombstones {
            if let localFolder = localFoldersByKey[stone.pathKey],
               localFolder.updatedAt >= stone.deletedAt {
                folderTombstones.removeValue(forKey: stone.pathKey)
                continue
            }
            if let existing = folderTombstones[stone.pathKey] {
                if stone.deletedAt > existing.deletedAt {
                    folderTombstones[stone.pathKey] = stone
                }
            } else {
                folderTombstones[stone.pathKey] = stone
            }
        }
        for (key, stone) in folderTombstones {
            if let localFolder = localFoldersByKey[key],
               localFolder.updatedAt >= stone.deletedAt {
                folderTombstones.removeValue(forKey: key)
            }
        }
        var seeded = local
        seeded.folderTombstones = folderTombstones.values.sorted { $0.pathKey < $1.pathKey }

        let merged = unionMerge(
            ledger: seeded,
            incoming: remote.entries,
            incomingFolders: remote.folders,
            browserKey: nil
        )
        // union 之后再保一次：本地仍持有的较新夹记录不得被墓碑滤掉。
        var foldersByKey = Dictionary(uniqueKeysWithValues: merged.folders.map { ($0.pathKey, $0) })
        for (key, localFolder) in localFoldersByKey {
            if let stone = folderTombstones[key], localFolder.updatedAt >= stone.deletedAt {
                folderTombstones.removeValue(forKey: key)
                if foldersByKey[key] == nil {
                    foldersByKey[key] = localFolder
                }
            }
        }
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
        // URL 对称 LWW：较新 entry 打掉墓碑。
        var keptEntries: [BookmarkEntry] = []
        for entry in merged.entries {
            if let stone = tombstones[entry.url] {
                if entry.updatedAt >= stone.deletedAt {
                    tombstones.removeValue(forKey: entry.url)
                    keptEntries.append(entry)
                }
            } else {
                keptEntries.append(entry)
            }
        }
        // 远端夹若已打掉墓碑，确保 foldersByKey 持有（含仅在 remote 的 recreate）。
        for folder in remote.folders {
            let key = folder.pathKey
            if let stone = folderTombstones[key], folder.updatedAt >= stone.deletedAt {
                folderTombstones.removeValue(forKey: key)
            }
            if folderTombstones[key] == nil {
                if let existing = foldersByKey[key] {
                    foldersByKey[key] = preferFolder(existing, folder)
                } else {
                    foldersByKey[key] = folder
                }
            }
        }
        let canonical = canonicalizeSiblingIndices(
            entries: keptEntries,
            folders: Array(foldersByKey.values)
        )
        var joined = Set(local.joinedBrowserKeys)
        remote.joinedBrowserKeys.forEach { joined.insert($0) }
        return BookmarkLedgerSnapshot(
            version: max(local.version, remote.version),
            entries: canonical.entries.sorted { $0.url < $1.url },
            folders: canonical.folders.sorted { $0.pathKey < $1.pathKey },
            tombstones: tombstones.values.sorted { $0.url < $1.url },
            folderTombstones: folderTombstones.values.sorted { $0.pathKey < $1.pathKey },
            remoteRevision: max(local.remoteRevision, remote.remoteRevision),
            joinedBrowserKeys: joined.sorted()
        )
    }

    /// 为 path 及其祖先 upsert 夹记录，并清除对应夹墓碑。
    static func upsertFolderAncestors(
        _ path: BookmarkFolderPath,
        siblingIndex: Int?,
        updatedAt: Double,
        in ledger: BookmarkLedgerSnapshot
    ) -> BookmarkLedgerSnapshot {
        let normalized = normalizeFolderPath(path)
        // 根（segments 空）不单独建夹记录。
        guard !normalized.segments.isEmpty || normalized.kind == .named else {
            return ledger
        }
        var byFolder = Dictionary(uniqueKeysWithValues: ledger.folders.map { ($0.pathKey, $0) })
        var folderTombstones = Dictionary(
            uniqueKeysWithValues: ledger.folderTombstones.map { ($0.pathKey, $0) }
        )

        var chain: [BookmarkFolderPath] = []
        var cursor = normalized
        while true {
            if !cursor.segments.isEmpty || cursor.kind == .named {
                chain.append(cursor)
            }
            guard let parent = parentPath(of: cursor) else { break }
            cursor = parent
        }
        for (i, folderPath) in chain.enumerated() {
            let key = folderPath.sortKey
            // 重建时间必须严格新于旧墓碑，避免紧随其后的 remote merge 用同秒墓碑盖掉。
            let priorTombstoneAt = folderTombstones[key]?.deletedAt
            folderTombstones.removeValue(forKey: key)
            let bump = priorTombstoneAt.map { max(updatedAt, $0 + 0.001) } ?? updatedAt
            let indexForThis: Int?
            if i == 0 { indexForThis = siblingIndex } else { indexForThis = nil }
            if var existing = byFolder[key] {
                if let indexForThis { existing.siblingIndex = indexForThis }
                existing.updatedAt = max(existing.updatedAt, bump)
                byFolder[key] = existing
            } else {
                byFolder[key] = BookmarkFolderRecord(
                    path: folderPath,
                    siblingIndex: indexForThis ?? 0,
                    updatedAt: bump
                )
            }
        }

        let canonical = canonicalizeSiblingIndices(
            entries: ledger.entries,
            folders: Array(byFolder.values)
        )
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: canonical.entries.sorted { $0.url < $1.url },
            folders: canonical.folders.sorted { $0.pathKey < $1.pathKey },
            tombstones: ledger.tombstones,
            folderTombstones: folderTombstones.values.sorted { $0.pathKey < $1.pathKey },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    static func isRootFolderPath(_ path: BookmarkFolderPath) -> Bool {
        path.segments.isEmpty && (path.kind == .toolbar || path.kind == .other || path.kind == .mobile)
    }

    static func isUnder(path: BookmarkFolderPath, ancestor: BookmarkFolderPath) -> Bool {
        guard path.kind == ancestor.kind else { return false }
        if ancestor.segments.isEmpty { return !path.segments.isEmpty || path == ancestor }
        guard path.segments.count >= ancestor.segments.count else { return false }
        return Array(path.segments.prefix(ancestor.segments.count)) == ancestor.segments
    }

    static func hasBookmarks(under path: BookmarkFolderPath, in ledger: BookmarkLedgerSnapshot) -> Bool {
        ledger.entries.contains { entry in
            isUnder(path: entry.folder, ancestor: path)
        }
    }

    static func directChildFolders(of path: BookmarkFolderPath, in ledger: BookmarkLedgerSnapshot) -> [BookmarkFolderRecord] {
        ledger.folders.filter { child in
            guard child.path.kind == path.kind else { return false }
            if path.segments.isEmpty {
                return child.path.segments.count == 1
            }
            return child.path.segments.count == path.segments.count + 1
                && Array(child.path.segments.prefix(path.segments.count)) == path.segments
        }
    }

    /// 删除空夹；recursive 时删整棵空夹树（树下不得有书签）。
    static func deleteFolder(
        _ path: BookmarkFolderPath,
        recursive: Bool,
        now: Double = Date().timeIntervalSince1970,
        in ledger: BookmarkLedgerSnapshot
    ) throws -> BookmarkLedgerSnapshot {
        let normalized = normalizeFolderPath(path)
        if isRootFolderPath(normalized) {
            throw TocodeCommandError.invalidArguments("不可删除书签根（toolbar/other/mobile）")
        }
        if hasBookmarks(under: normalized, in: ledger) {
            throw TocodeCommandError.operationFailed("夹下仍有书签，请先搬迁或删除书签：\(normalized.sortKey)")
        }
        if !recursive {
            let children = directChildFolders(of: normalized, in: ledger)
            if !children.isEmpty {
                throw TocodeCommandError.operationFailed(
                    "夹下仍有子夹（\(children.count)），请加 --recursive 或先删子夹"
                )
            }
        }

        let toRemove: [BookmarkFolderPath]
        if recursive {
            toRemove = ledger.folders
                .map(\.path)
                .filter { isUnder(path: $0, ancestor: normalized) }
                .sorted { $0.segments.count > $1.segments.count }
        } else {
            toRemove = ledger.folders.contains(where: { $0.pathKey == normalized.sortKey })
                ? [normalized]
                : []
        }
        // 即使账本无记录（仅浏览器有），也写墓碑以便下行删除。
        var removeKeys = Set(toRemove.map(\.sortKey))
        removeKeys.insert(normalized.sortKey)

        var folders = ledger.folders.filter { !removeKeys.contains($0.pathKey) }
        var folderTombstones = Dictionary(
            uniqueKeysWithValues: ledger.folderTombstones.map { ($0.pathKey, $0) }
        )
        for key in removeKeys {
            let pathForStone = toRemove.first(where: { $0.sortKey == key }) ?? normalized
            folderTombstones[key] = BookmarkFolderTombstone(path: pathForStone, deletedAt: now)
        }

        let canonical = canonicalizeSiblingIndices(entries: ledger.entries, folders: folders)
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: canonical.entries.sorted { $0.url < $1.url },
            folders: canonical.folders.sorted { $0.pathKey < $1.pathKey },
            tombstones: ledger.tombstones,
            folderTombstones: folderTombstones.values.sorted { $0.pathKey < $1.pathKey },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
        )
    }

    /// 剪掉空壳夹（无书签、无子夹）；可限定 under 前缀。
    static func pruneEmptyFolders(
        under: BookmarkFolderPath?,
        now: Double = Date().timeIntervalSince1970,
        in ledger: BookmarkLedgerSnapshot
    ) throws -> (ledger: BookmarkLedgerSnapshot, removed: [BookmarkFolderPath]) {
        var current = ledger
        var removed: [BookmarkFolderPath] = []
        // 反复从最深空夹删起，直到稳定。
        while true {
            let candidates = current.folders
                .map(\.path)
                .filter { path in
                    if isRootFolderPath(path) { return false }
                    if let under {
                        return isUnder(path: path, ancestor: under)
                    }
                    return true
                }
                .filter { path in
                    !hasBookmarks(under: path, in: current)
                        && directChildFolders(of: path, in: current).isEmpty
                }
                .sorted { $0.segments.count > $1.segments.count }
            if candidates.isEmpty { break }
            for path in candidates {
                // 可能已被上一轮删掉
                guard current.folders.contains(where: { $0.pathKey == path.sortKey }) else { continue }
                current = try deleteFolder(path, recursive: false, now: now, in: current)
                removed.append(path)
            }
        }
        return (current, removed)
    }

    /// 同父改序，或改路径（rename/move）并迁移子书签/子夹。
    static func moveFolder(
        from: BookmarkFolderPath,
        to: BookmarkFolderPath?,
        siblingIndex: Int?,
        now: Double = Date().timeIntervalSince1970,
        in ledger: BookmarkLedgerSnapshot
    ) throws -> BookmarkLedgerSnapshot {
        let source = normalizeFolderPath(from)
        if isRootFolderPath(source) {
            throw TocodeCommandError.invalidArguments("不可移动书签根")
        }
        guard ledger.folders.contains(where: { $0.pathKey == source.sortKey })
                || hasBookmarks(under: source, in: ledger) else {
            throw TocodeCommandError.operationFailed("找不到夹：\(source.sortKey)")
        }

        let destination: BookmarkFolderPath
        if let to {
            destination = normalizeFolderPath(to)
            if isRootFolderPath(destination) {
                throw TocodeCommandError.invalidArguments("--to 不能是书签根本身")
            }
            if destination.kind != source.kind {
                // 允许跨根，但需显式路径
            }
            if isUnder(path: destination, ancestor: source), destination != source {
                throw TocodeCommandError.invalidArguments("不能把夹移到自身子路径下")
            }
        } else {
            destination = source
        }

        var entries = ledger.entries
        var folders = ledger.folders
        var folderTombstones = Dictionary(
            uniqueKeysWithValues: ledger.folderTombstones.map { ($0.pathKey, $0) }
        )

        if destination.sortKey != source.sortKey {
            func remap(_ path: BookmarkFolderPath) -> BookmarkFolderPath {
                guard path.kind == source.kind,
                      path.segments.count >= source.segments.count,
                      Array(path.segments.prefix(source.segments.count)) == source.segments else {
                    return path
                }
                let suffix = Array(path.segments.dropFirst(source.segments.count))
                return BookmarkFolderPath(kind: destination.kind, segments: destination.segments + suffix)
            }
            for i in entries.indices {
                let before = entries[i].folder
                let after = remap(before)
                if after != before {
                    entries[i].folder = after
                    entries[i].updatedAt = now
                }
            }
            var remapped: [String: BookmarkFolderRecord] = [:]
            for folder in folders {
                let after = remap(folder.path)
                if after.sortKey != folder.pathKey {
                    folderTombstones[folder.pathKey] = BookmarkFolderTombstone(
                        path: folder.path,
                        deletedAt: now
                    )
                }
                folderTombstones.removeValue(forKey: after.sortKey)
                var record = folder
                record.path = after
                record.updatedAt = now
                if after.sortKey == destination.sortKey, let siblingIndex {
                    record.siblingIndex = siblingIndex
                }
                if let existing = remapped[after.sortKey] {
                    remapped[after.sortKey] = preferFolder(existing, record)
                } else {
                    remapped[after.sortKey] = record
                }
            }
            // 确保目标夹存在
            if remapped[destination.sortKey] == nil {
                remapped[destination.sortKey] = BookmarkFolderRecord(
                    path: destination,
                    siblingIndex: siblingIndex ?? 0,
                    updatedAt: now
                )
            }
            folders = Array(remapped.values)
        } else if let siblingIndex {
            guard let idx = folders.firstIndex(where: { $0.pathKey == source.sortKey }) else {
                throw TocodeCommandError.operationFailed("找不到夹记录：\(source.sortKey)")
            }
            folders[idx].siblingIndex = siblingIndex
            folders[idx].updatedAt = now
        }

        let canonical = canonicalizeSiblingIndices(entries: entries, folders: folders)
        return BookmarkLedgerSnapshot(
            version: ledger.version,
            entries: canonical.entries.sorted { $0.url < $1.url },
            folders: canonical.folders.sorted { $0.pathKey < $1.pathKey },
            tombstones: ledger.tombstones,
            folderTombstones: folderTombstones.values.sorted { $0.pathKey < $1.pathKey },
            remoteRevision: ledger.remoteRevision,
            joinedBrowserKeys: ledger.joinedBrowserKeys
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
    /// 例外：`other/书签栏`、`other/toolbar` 等「仅一段别名」的空壳保留字面路径，避免收成不可删的根。
    /// `other/书签工具栏/官网` 仍归一到 `toolbar/官网`。
    static func normalizeFolderPath(_ path: BookmarkFolderPath) -> BookmarkFolderPath {
        guard path.kind == .other || path.kind == .named,
              let first = path.segments.first,
              isToolbarAliasTitle(first) else {
            return path
        }
        let rest = Array(path.segments.dropFirst())
        if path.kind == .other, rest.isEmpty {
            return path
        }
        return BookmarkFolderPath(kind: .toolbar, segments: rest)
    }

    private static func mapRoot(_ title: String) -> BookmarkFolderKind {
        if isToolbarAliasTitle(title) {
            return .toolbar
        }
        let lower = title.lowercased()
        // Firefox「书签菜单 / Bookmarks Menu」与「其他书签」同属 other 根别名。
        if ["其他书签", "other bookmarks", "其他收藏夹", "other favorites", "书签菜单", "bookmarks menu"]
            .contains(where: { lower == $0 || title == $0 })
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
