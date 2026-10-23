import Foundation

enum BookmarkCLIFolder {
    /// 合法根别名（小写键 → kind）。多字中文别名按「最长优先」匹配前缀。
    private static let rootAliases: [(alias: String, kind: BookmarkFolderKind)] = {
        let pairs: [(String, BookmarkFolderKind)] = [
            ("toolbar", .toolbar),
            ("bar", .toolbar),
            ("书签栏", .toolbar),
            ("other", .other),
            ("其他书签", .other),
            ("其他", .other),
            ("mobile", .mobile),
            ("移动设备书签", .mobile),
            ("移动", .mobile)
        ]
        return pairs.sorted { $0.0.count > $1.0.count }.map { (alias: $0.0, kind: $0.1) }
    }()

    static var helpHint: String {
        "合法 --folder：toolbar|other|mobile|书签栏|其他书签|移动设备书签（可单独或作前缀，如 toolbar/工作/a）；named:a/b 为具名；无前缀 a/b 亦为 named"
    }

    static func parse(_ raw: String?) -> Result<BookmarkFolderPath?, TocodeCommandError> {
        guard let raw else { return .success(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidArguments("bookmark --folder（空路径）。\(helpHint)"))
        }

        // 显式 named:
        if trimmed.lowercased().hasPrefix("named:") {
            let path = String(trimmed.dropFirst(6))
            let segments = splitSegments(path)
            guard !segments.isEmpty else {
                return .failure(.invalidArguments("bookmark --folder named: 后须有路径段。\(helpHint)"))
            }
            return .success(BookmarkFolderPath(kind: .named, segments: segments))
        }

        // 整串恰为根别名
        let lower = trimmed.lowercased()
        for entry in rootAliases {
            if lower == entry.alias.lowercased() || trimmed == entry.alias {
                return .success(BookmarkFolderPath(kind: entry.kind, segments: []))
            }
        }

        // 根前缀 + /segments
        if let rooted = parseRootedPrefix(trimmed) {
            return rooted
        }

        // 无根前缀：具名路径 a/b
        let segments = splitSegments(trimmed)
        guard !segments.isEmpty else {
            return .failure(.invalidArguments("bookmark --folder。\(helpHint)"))
        }
        // 若第一段看起来像根别名但写法非法（例如 toolbarX），仍当 named；若第一段正好是根别名却无斜杠已在上面处理。
        return .success(BookmarkFolderPath(kind: .named, segments: segments))
    }

    /// 解析 `toolbar/a/b`、`书签栏/工作` 等；失败返回 error Result。
    private static func parseRootedPrefix(_ trimmed: String) -> Result<BookmarkFolderPath?, TocodeCommandError>? {
        for entry in rootAliases {
            let alias = entry.alias
            let aliasLower = alias.lowercased()
            // 前缀匹配：alias/ 或 大小写不敏感英文根/
            let hasSlashPrefix: Bool
            let rest: String
            if trimmed.hasPrefix(alias + "/") {
                hasSlashPrefix = true
                rest = String(trimmed.dropFirst(alias.count + 1))
            } else if trimmed.lowercased().hasPrefix(aliasLower + "/") {
                hasSlashPrefix = true
                let drop = aliasLower.count + 1
                rest = String(trimmed.dropFirst(drop))
            } else {
                hasSlashPrefix = false
                rest = ""
            }
            guard hasSlashPrefix else { continue }
            let segments = splitSegments(rest)
            guard !segments.isEmpty else {
                return .failure(.invalidArguments(
                    "bookmark --folder \(alias)/ 后须有路径段。\(helpHint)"
                ))
            }
            return .success(BookmarkFolderPath(kind: entry.kind, segments: segments))
        }
        return nil
    }

    private static func splitSegments(_ path: String) -> [String] {
        path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func encode(_ folder: BookmarkFolderPath) -> [String: Any] {
        [
            "kind": folder.kind.rawValue,
            "segments": folder.segments
        ]
    }
}

enum BookmarkCLIFolderTree {
    /// 由账本 folders + entries 组装可审计夹树。
    static func build(from snapshot: BookmarkLedgerSnapshot) -> [[String: Any]] {
        var recordsByKey: [String: BookmarkFolderRecord] = [:]
        for folder in snapshot.folders {
            recordsByKey[folder.pathKey] = folder
        }

        // 从书签路径推导祖先夹
        for entry in snapshot.entries {
            var segs = entry.folder.segments
            while true {
                let path = BookmarkFolderPath(kind: entry.folder.kind, segments: segs)
                if recordsByKey[path.sortKey] == nil {
                    recordsByKey[path.sortKey] = BookmarkFolderRecord(
                        path: path,
                        siblingIndex: 0,
                        updatedAt: entry.updatedAt
                    )
                }
                if segs.isEmpty { break }
                segs.removeLast()
            }
        }

        func childBookmarkCount(of path: BookmarkFolderPath) -> Int {
            snapshot.entries.filter { $0.folder == path }.count
        }

        func childFolderCount(of path: BookmarkFolderPath) -> Int {
            recordsByKey.values.filter { child in
                guard child.path.kind == path.kind else { return false }
                if path.segments.isEmpty {
                    return child.path.segments.count == 1
                }
                return child.path.segments.count == path.segments.count + 1
                    && Array(child.path.segments.prefix(path.segments.count)) == path.segments
            }.count
        }

        let nodes: [[String: Any]] = recordsByKey.values.map { record in
            let bookmarks = childBookmarkCount(of: record.path)
            let folders = childFolderCount(of: record.path)
            return [
                "kind": record.path.kind.rawValue,
                "segments": record.path.segments,
                "siblingIndex": record.siblingIndex,
                "order": record.siblingIndex,
                "updatedAt": record.updatedAt,
                "childBookmarkCount": bookmarks,
                "childFolderCount": folders,
                "isEmpty": bookmarks == 0 && folders == 0
            ]
        }

        return nodes.sorted { a, b in
            let ka = a["kind"] as? String ?? ""
            let kb = b["kind"] as? String ?? ""
            if ka != kb { return ka < kb }
            let sa = a["segments"] as? [String] ?? []
            let sb = b["segments"] as? [String] ?? []
            if sa.count != sb.count { return sa.count < sb.count }
            if sa != sb { return sa.lexicographicallyPrecedes(sb) }
            let oa = a["siblingIndex"] as? Int ?? 0
            let ob = b["siblingIndex"] as? Int ?? 0
            return oa < ob
        }
    }
}

enum BookmarkCLIJSON {
    static func entry(_ entry: BookmarkEntry) -> [String: Any] {
        [
            "id": entry.id,
            "url": entry.url,
            "title": entry.title,
            "folder": BookmarkCLIFolder.encode(entry.folder),
            "index": entry.siblingIndex,
            "siblingIndex": entry.siblingIndex,
            "updatedAt": entry.updatedAt
        ]
    }

    static func encode(_ value: Any) -> Result<String, TocodeCommandError> {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(.operationFailed("无法编码书签 JSON"))
        }
        return .success(text)
    }
}

protocol BookmarkSyncCommanding: AnyObject {
    var isRemoteEnabled: Bool { get }
    var hasRemoteKey: Bool { get }
    var connectedBrowserKeys: [String] { get }
    var snapshot: BookmarkLedgerSnapshot { get }
    var activityLog: BookmarkSyncActivityLog { get }

    func entry(url: String) -> BookmarkEntry?
    func addCLI(url: String, title: String?, folder: BookmarkFolderPath?, siblingIndex: Int?) throws -> BookmarkEntry
    func updateCLI(url: String, title: String?, folder: BookmarkFolderPath?, siblingIndex: Int?, newURL: String?) throws -> BookmarkEntry
    func deleteCLI(url: String) throws
    func pullRemoteForCLI() async -> Result<BookmarkLedgerSnapshot, Error>
    func backupStatusPayload() -> [String: Any]
    func backupListPayload() -> [[String: Any]]
    func backupNowForCLI() async -> Result<BookmarkBackupPack, Error>
    func restoreBackupForCLI(day: String?) async -> Result<BookmarkLedgerSnapshot, Error>
    func foldersTreePayload() -> [[String: Any]]
}

extension BookmarkSyncService: BookmarkSyncCommanding {}
