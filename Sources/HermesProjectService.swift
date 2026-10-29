import AppKit
import ApplicationServices
import Foundation
import SQLite3

/// 侧边栏已经进入的项目，或当前打开的会话。本地存储还没落盘时，窗口上的标题已经是这个项目或会话。
enum HermesVisibleEntry: Equatable {
    case entered(String)
    case session(String)
    case home
}

/// Hermes 当前选中的正式项目。
struct HermesProject: Equatable {
    let name: String
    let rootPath: String
}

/// 只读解析 Hermes 当前打开的项目，绝不写回。
struct HermesProjectService {
    private static let routeMarker = Data("hermes.desktop.lastRoute.profile.".utf8)
    private static let remoteRouteSuffix = Data(".remote.".utf8)
    private static let openSessionMarkers: [Data] = [
        Data("hermes.desktop.rightRailActiveTab".utf8),
        Data("hermes.desktop.inflightTurnJournal.v2:".utf8)
    ]
    private static let scopeKey = "hermes.desktop.projectScope"
    private static let sessionKeyPrefix = "hermes.desktop.lastSessionId.profile."
    private static let ignoredScopes: Set<String> = ["__all_projects__", "__no_project__"]

    private let pinnedDatabasePath: String?
    private let home: String?
    private let storageDirectory: String?
    private let fs: FileSystemService
    private let visibleEntry: () -> HermesVisibleEntry?

    init(
        home: String = NSHomeDirectory(),
        fs: FileSystemService = FileSystemService(),
        databasePath: String? = nil,
        storageDirectory: String? = nil,
        visibleEntry: @escaping () -> HermesVisibleEntry? = { HermesVisibleEntryReader.current() }
    ) {
        self.fs = fs
        self.visibleEntry = visibleEntry
        if let databasePath {
            self.pinnedDatabasePath = databasePath
            self.home = nil
            self.storageDirectory = nil
        } else {
            self.pinnedDatabasePath = nil
            self.home = home
            self.storageDirectory = storageDirectory ?? (home as NSString).appendingPathComponent(
                "Library/Application Support/Hermes/Local Storage/leveldb"
            )
        }
    }

    /// default 与读不到档案时用 ~/.hermes/projects.db；具名档案用 profiles/<name>/projects.db。
    static func projectsDatabasePath(home: String, profile: String?) -> String {
        let hermes = (home as NSString).appendingPathComponent(".hermes")
        guard let profile, profile != "default" else {
            return (hermes as NSString).appendingPathComponent("projects.db")
        }
        return ((hermes as NSString).appendingPathComponent("profiles/\(profile)") as NSString)
            .appendingPathComponent("projects.db")
    }

    static func stateDatabasePath(home: String, profile: String?) -> String {
        let projects = projectsDatabasePath(home: home, profile: profile)
        return (projects as NSString).deletingLastPathComponent + "/state.db"
    }

    /// 桌面本地会话路由里最新的档案名。远程路由、空目录和非法名字都忽略。
    static func currentProfileName(in storageDirectory: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storageDirectory) else { return nil }
        let files: [(path: String, modified: Date)] = names.compactMap { name in
            let path = (storageDirectory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            return (path, modified)
        }.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.path > rhs.path
        }
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)),
                  data.count <= 16 * 1024 * 1024,
                  data.range(of: routeMarker) != nil else { continue }
            return lastLocalProfileName(in: data)
        }
        return nil
    }

    /// 桌面当前打开的会话编号。旧路由缺失时用来找出所属档案。
    static func openSessionID(in storageDirectory: String) -> String? {
        for file in storageFiles(in: storageDirectory) {
            guard let data = readStorage(file), let sessionID = lastMarkedSessionID(in: data) else { continue }
            return sessionID
        }
        return nil
    }

    /// 最新一份含该键的本地存储里，最后一次写出的值。
    static func lastStorageValue(in storageDirectory: String, key: String) -> String? {
        let marker = Data(key.utf8)
        for file in storageFiles(in: storageDirectory) {
            guard let data = readStorage(file), data.range(of: marker) != nil else { continue }
            return lastValue(in: data, marker: marker)
        }
        return nil
    }

    /// 已进入的项目优先；否则用当前会话所属项目的主目录；都没有时才用 active_id。
    /// 会话落在项目文件夹内部时仍用该项目主目录。库缺失、路径失效时返回 nil。
    func resolveProject() -> HermesProject? {
        let entry = visibleEntry()
        guard let home, let storageDirectory else {
            let databasePath = pinnedDatabasePath ?? ""
            if case .entered(let label) = entry,
               let visible = project(matchingLabel: label, databasePath: databasePath, home: nil, profile: nil) {
                return visible
            }
            return activeProject(in: databasePath)
        }
        let profile = profileName(home: home, storageDirectory: storageDirectory)
        let databasePath = Self.projectsDatabasePath(home: home, profile: profile)
        if case .entered(let label) = entry,
           let visible = project(matchingLabel: label, databasePath: databasePath, home: home, profile: profile) {
            return visible
        }
        if case .session(let title) = entry,
           let visible = project(matchingVisibleSession: title, home: home)
            ?? project(matchingSessionTitle: title, databasePath: databasePath, home: home, profile: profile) {
            if let scoped = enteredScopeProject(home: home, storageDirectory: storageDirectory),
               !isPath(scoped.rootPath, prefixOf: visible.rootPath) {
                return scoped
            }
            return visible
        }
        let scopeAgrees = scopeAgreesWithVisibleEntry(entry, databasePath: databasePath)
        if entry == nil || scopeAgrees,
           let scope = Self.lastStorageValue(in: storageDirectory, key: Self.scopeKey),
           let entered = enteredProject(scope, databasePath: databasePath) {
            return entered
        }
        if let focused = focusedSessionProject(profile: profile, databasePath: databasePath, home: home, storage: storageDirectory) {
            return focused
        }
        return activeProject(in: databasePath)
    }

    /// 旧路由优先。没有旧路由时，用当前打开会话所属的唯一档案；对不上才用 default。
    private func profileName(home: String, storageDirectory: String) -> String {
        if let routed = Self.currentProfileName(in: storageDirectory) {
            return routed
        }
        if let sessionID = Self.openSessionID(in: storageDirectory),
           let owner = profileOwning(sessionID, home: home) {
            return owner
        }
        return "default"
    }

    private func profileOwning(_ sessionID: String, home: String) -> String? {
        let profilesRoot = (home as NSString).appendingPathComponent(".hermes/profiles")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []
        let matches = names.filter { Self.isProfileName($0) && stateContains(sessionID, home: home, profile: $0) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }
        if stateContains(sessionID, home: home, profile: nil) { return "default" }
        return nil
    }

    private func stateContains(_ sessionID: String, home: String, profile: String?) -> Bool {
        let path = Self.stateDatabasePath(home: home, profile: profile)
        guard let database = openReadOnly(path) else { return false }
        defer { sqlite3_close(database) }
        return queryOne(
            database,
            sql: "SELECT id FROM sessions WHERE id = ? LIMIT 1",
            bindings: [sessionID]
        ) != nil
    }

    /// 窗口已经进入别的项目时，磁盘上的旧 projectScope 不能继续挡住新项目。
    private func scopeAgreesWithVisibleEntry(_ entry: HermesVisibleEntry?, databasePath: String) -> Bool {
        guard let entry else { return true }
        guard case .entered(let label) = entry else { return false }
        guard let scope = Self.lastStorageValue(in: storageDirectory ?? "", key: Self.scopeKey),
              let entered = enteredProject(scope, databasePath: databasePath) else {
            return false
        }
        return entered.name == label || (entered.rootPath as NSString).lastPathComponent == label
    }

    private func enteredProject(_ scope: String, databasePath: String) -> HermesProject? {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.ignoredScopes.contains(trimmed) else { return nil }
        if trimmed.hasPrefix("/") {
            let path = (trimmed as NSString).standardizingPath
            guard fs.isExistingDirectory(path) else { return nil }
            let name = (path as NSString).lastPathComponent
            return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: path)
        }
        guard trimmed.hasPrefix("p_"), trimmed.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }) else { return nil }
        return project(id: trimmed, in: databasePath)
    }

    /// 窗口标题是项目名或目录名。重名时不猜，交给后面的磁盘记录。
    private func project(matchingLabel label: String, databasePath: String, home: String?, profile: String?) -> HermesProject? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        if trimmed.hasPrefix("/") {
            let path = (trimmed as NSString).standardizingPath
            guard fs.isExistingDirectory(path) else { return nil }
            let name = (path as NSString).lastPathComponent
            return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: path)
        }
        if let named = namedProject(trimmed, databasePath: databasePath) {
            return named
        }
        guard let home else { return nil }
        return sessionRoot(named: trimmed, home: home, profile: profile)
    }

    private func namedProject(_ label: String, databasePath: String) -> HermesProject? {
        guard let database = openReadOnly(databasePath) else { return nil }
        defer { sqlite3_close(database) }
        let rows = queryAll(
            database,
            sql: "SELECT id, name, primary_path, archived FROM projects"
        )
        let active = rows.filter { $0.count == 4 && $0[3] == "0" && !($0[0] ?? "").isEmpty }
        let byName = active.filter { ($0[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == label }
        if byName.count > 1 { return nil }
        if byName.count == 1, let id = byName[0][0] {
            return project(id: id, database: database)
        }
        let byFolder = active.filter { folder in
            let path = (folder[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !path.isEmpty && (path as NSString).lastPathComponent == label
        }
        guard byFolder.count == 1, let id = byFolder[0][0] else { return nil }
        return project(id: id, database: database)
    }

    private func sessionRoot(named label: String, home: String, profile: String?) -> HermesProject? {
        let statePath = Self.stateDatabasePath(home: home, profile: profile)
        guard let database = openReadOnly(statePath) else { return nil }
        defer { sqlite3_close(database) }
        let rows = queryAll(database, sql: "SELECT git_repo_root, cwd FROM sessions")
        var matches: [String] = []
        for row in rows where row.count == 2 {
            let repo = (row[0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = !repo.isEmpty ? repo : cwd
            guard !candidate.isEmpty, (candidate as NSString).lastPathComponent == label else { continue }
            let path = (candidate as NSString).standardizingPath
            guard fs.isExistingDirectory(path), !matches.contains(path) else { continue }
            matches.append(path)
            if matches.count > 1 { return nil }
        }
        guard let path = matches.first else { return nil }
        return HermesProject(name: label, rootPath: path)
    }

    /// 侧边栏当前会话的标题。重名时不猜。目录落在项目内部时仍用项目主目录。
    private func project(
        matchingSessionTitle title: String,
        databasePath: String,
        home: String,
        profile: String?
    ) -> HermesProject? {
        let statePath = Self.stateDatabasePath(home: home, profile: profile)
        guard let database = openReadOnly(statePath) else { return nil }
        defer { sqlite3_close(database) }
        let rows = queryAll(
            database,
            sql: "SELECT cwd, git_repo_root, title, archived FROM sessions"
        )
        var matches: [(cwd: String, repo: String)] = []
        for row in rows where row.count == 4 {
            if row[3] == "1" { continue }
            let name = (row[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == title else { continue }
            matches.append((
                (row[0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        guard matches.count == 1 else { return nil }
        let cwd = matches[0].cwd
        let repo = matches[0].repo
        if let owned = owningProject(cwd: cwd, repoRoot: repo, databasePath: databasePath) {
            return owned
        }
        for candidate in [repo, cwd] where !candidate.isEmpty {
            let path = (candidate as NSString).standardizingPath
            if fs.isExistingDirectory(path) {
                let name = (path as NSString).lastPathComponent
                return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: path)
            }
        }
        return nil
    }

    /// 当前会话标题只属于一个档案时，用那个档案。多个档案都有同名会话时不猜。
    private func project(matchingVisibleSession title: String, home: String) -> HermesProject? {
        var found: HermesProject?
        for profile in candidateProfiles(home: home) {
            let databasePath = Self.projectsDatabasePath(home: home, profile: profile)
            guard let project = project(
                matchingSessionTitle: title,
                databasePath: databasePath,
                home: home,
                profile: profile
            ) else { continue }
            if found != nil { return nil }
            found = project
        }
        return found
    }

    private func candidateProfiles(home: String) -> [String?] {
        let profilesRoot = (home as NSString).appendingPathComponent(".hermes/profiles")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? [])
            .filter { Self.isProfileName($0) }
            .sorted()
        return names.map { Optional.some($0) } + [nil]
    }

    /// 侧边栏已经点进的项目。会话标签可能还留着上一个会话，项目编号可能在另一个档案。
    private func enteredScopeProject(home: String, storageDirectory: String) -> HermesProject? {
        guard let scope = Self.lastStorageValue(in: storageDirectory, key: Self.scopeKey) else { return nil }
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.ignoredScopes.contains(trimmed) else { return nil }
        if trimmed.hasPrefix("/") {
            let path = (trimmed as NSString).standardizingPath
            guard fs.isExistingDirectory(path) else { return nil }
            let name = (path as NSString).lastPathComponent
            return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: path)
        }
        guard trimmed.hasPrefix("p_") else { return nil }
        for profile in candidateProfiles(home: home) {
            let databasePath = Self.projectsDatabasePath(home: home, profile: profile)
            if let project = project(id: trimmed, in: databasePath) { return project }
        }
        return nil
    }

    private func focusedSessionProject(profile: String, databasePath: String, home: String, storage: String) -> HermesProject? {
        guard let sessionID = Self.lastStorageValue(in: storage, key: Self.sessionKeyPrefix + profile),
              Self.isSessionID(sessionID) else { return nil }
        let statePath = Self.stateDatabasePath(home: home, profile: profile)
        guard let database = openReadOnly(statePath) else { return nil }
        defer { sqlite3_close(database) }
        guard let row = queryOne(
            database,
            sql: "SELECT cwd, git_repo_root FROM sessions WHERE id = ? LIMIT 1",
            bindings: [sessionID]
        ), row.count == 2 else { return nil }
        let cwd = (row[0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let repoRoot = (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let owned = owningProject(cwd: cwd, repoRoot: repoRoot, databasePath: databasePath) {
            return owned
        }
        for candidate in [repoRoot, cwd] where !candidate.isEmpty {
            let path = (candidate as NSString).standardizingPath
            if fs.isExistingDirectory(path) {
                let name = (path as NSString).lastPathComponent
                return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: path)
            }
        }
        return nil
    }

    private func owningProject(cwd: String, repoRoot: String, databasePath: String) -> HermesProject? {
        guard let database = openReadOnly(databasePath) else { return nil }
        defer { sqlite3_close(database) }
        let rows = queryAll(
            database,
            sql: """
            SELECT projects.id, projects.name, projects.primary_path, projects.archived, project_folders.path
            FROM projects
            LEFT JOIN project_folders ON project_folders.project_id = projects.id
            """
        )
        var best: (project: HermesProject, length: Int)?
        var projects: [String: (name: String, primary: String, archived: String)] = [:]
        var folders: [String: [String]] = [:]
        for row in rows {
            guard row.count == 5, let id = row[0], !id.isEmpty else { continue }
            projects[id] = (row[1] ?? "", row[2] ?? "", row[3] ?? "")
            if let folder = row[4]?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                folders[id, default: []].append(folder)
            }
        }
        for (id, project) in projects where project.archived == "0" {
            var paths = folders[id] ?? []
            let primary = project.primary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !primary.isEmpty { paths.append(primary) }
            for folder in paths {
                let matches = [cwd, repoRoot].contains { isPath(folder, prefixOf: $0) }
                let length = (folder as NSString).standardizingPath.count
                guard matches, best == nil || length > best!.length else { continue }
                guard let resolved = self.project(id: id, database: database) else { continue }
                best = (resolved, length)
            }
        }
        return best?.project
    }

    private func activeProject(in databasePath: String) -> HermesProject? {
        guard let database = openReadOnly(databasePath) else { return nil }
        defer { sqlite3_close(database) }
        guard let row = queryOne(
            database,
            sql: "SELECT value FROM project_meta WHERE key = 'active_id' LIMIT 1"
        ), let id = row.first ?? nil, !id.isEmpty else { return nil }
        return project(id: id, database: database)
    }

    private func project(id: String, in databasePath: String) -> HermesProject? {
        guard let database = openReadOnly(databasePath) else { return nil }
        defer { sqlite3_close(database) }
        return project(id: id, database: database)
    }

    private func project(id: String, database: OpaquePointer) -> HermesProject? {
        guard let row = queryOne(
            database,
            sql: "SELECT name, primary_path, archived FROM projects WHERE id = ? LIMIT 1",
            bindings: [id]
        ), row.count == 3, row[2] == "0" else { return nil }
        let primary = (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if !primary.isEmpty {
            candidate = primary
        } else {
            let folder = (queryOne(
                database,
                sql: "SELECT path FROM project_folders WHERE project_id = ? AND is_primary = 1 LIMIT 1",
                bindings: [id]
            )?.first ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !folder.isEmpty else { return nil }
            candidate = folder
        }
        let standardized = (candidate as NSString).standardizingPath
        guard fs.isExistingDirectory(standardized) else { return nil }
        let name = row[0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: standardized)
    }

    private func isPath(_ root: String, prefixOf target: String) -> Bool {
        let base = (root as NSString).standardizingPath
        let path = (target as NSString).standardizingPath
        guard !base.isEmpty, !path.isEmpty else { return false }
        if base == path { return true }
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// WAL 项目库在没有 -shm 时，普通只读打开会在查询阶段失败。immutable 只读主文件，不创建 -shm，也不写库。
    private func openReadOnly(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let uri = Self.readOnlyURI(path)
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        return database
    }

    private static func readOnlyURI(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.~"))
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(encoded)?immutable=1"
    }

    private func queryOne(_ database: OpaquePointer, sql: String, bindings: [String] = []) -> [String?]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                return nil
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columns(statement)
    }

    private func queryAll(_ database: OpaquePointer, sql: String) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(columns(statement))
        }
        return rows
    }

    private func columns(_ statement: OpaquePointer) -> [String?] {
        (0..<sqlite3_column_count(statement)).map { column in
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let bytes = sqlite3_column_text(statement, column) else {
                return nil
            }
            return String(cString: bytes)
        }
    }

    /// 同一文件里后出现的当前会话覆盖先出现的。只认右侧栏和进行中回合上的会话编号。
    private static func lastMarkedSessionID(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var found: String?
        var cursor = 0
        while cursor < bytes.count {
            guard let markerEnd = nextOpenSessionMarkerEnd(in: bytes, from: cursor) else { break }
            let windowEnd = min(bytes.count, markerEnd + 256)
            if let sessionID = sessionID(in: bytes, from: markerEnd, until: windowEnd) {
                found = sessionID
            }
            cursor = markerEnd
        }
        return found
    }

    private static func nextOpenSessionMarkerEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var chosen: (start: Int, end: Int)?
        for marker in openSessionMarkers {
            let needle = [UInt8](marker)
            guard let index = range(of: needle, in: bytes, from: start) else { continue }
            if chosen == nil || index < chosen!.start {
                chosen = (index, index + needle.count)
            }
        }
        return chosen?.end
    }

    private static func range(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start < bytes.count else { return nil }
        var index = start
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index..<index + needle.count].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    private static func sessionID(in bytes: [UInt8], from start: Int, until end: Int) -> String? {
        var index = start
        while index < end {
            if let sessionID = parseSessionID(bytes, at: index) { return sessionID }
            index += 1
        }
        return nil
    }

    /// 形如 20261013_193152_02ef04。
    private static func parseSessionID(_ bytes: [UInt8], at index: Int) -> String? {
        func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        func isHex(_ byte: UInt8) -> Bool {
            isDigit(byte) || (byte >= 97 && byte <= 102) || (byte >= 65 && byte <= 70)
        }
        guard index + 20 <= bytes.count else { return nil }
        for offset in 0..<8 where !isDigit(bytes[index + offset]) { return nil }
        guard bytes[index + 8] == 0x5f else { return nil }
        for offset in 9..<15 where !isDigit(bytes[index + offset]) { return nil }
        guard bytes[index + 15] == 0x5f else { return nil }
        var hexEnd = index + 16
        while hexEnd < bytes.count, isHex(bytes[hexEnd]) { hexEnd += 1 }
        guard hexEnd - (index + 16) >= 4 else { return nil }
        return String(bytes: bytes[index..<hexEnd], encoding: .utf8)
    }

    /// 同一文件里后出现的本地路由覆盖先出现的。`.remote.` 后缀属于远程连接，不采用。
    private static func lastLocalProfileName(in data: Data) -> String? {
        var found: String?
        var search = data.startIndex
        while let range = data.range(of: routeMarker, in: search..<data.endIndex) {
            let nameEnd = profileNameEnd(in: data, from: range.upperBound)
            if nameEnd > range.upperBound,
               let name = String(data: data.subdata(in: range.upperBound..<nameEnd), encoding: .utf8),
               isProfileName(name),
               !hasRemoteSuffix(data, at: nameEnd) {
                found = name
            }
            search = range.upperBound
        }
        return found
    }

    private static func profileNameEnd(in data: Data, from start: Data.Index) -> Data.Index {
        var end = start
        while end < data.endIndex, end - start < 64, isProfileByte(data[end]) {
            end = data.index(after: end)
        }
        return end
    }

    private static func hasRemoteSuffix(_ data: Data, at index: Data.Index) -> Bool {
        let suffix = remoteRouteSuffix
        guard let limit = data.index(index, offsetBy: suffix.count, limitedBy: data.endIndex),
              data.distance(from: index, to: limit) == suffix.count else { return false }
        return data.subdata(in: index..<limit) == suffix
    }

    private static func isProfileByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5f || byte == 0x2d
    }

    private static func isProfileName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first else { return false }
        let firstIsAlphanumeric = (first >= 0x61 && first <= 0x7a) || (first >= 0x30 && first <= 0x39)
        guard firstIsAlphanumeric else { return false }
        return name.utf8.allSatisfy(isProfileByte)
    }

    private static func isSessionID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF_")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func storageFiles(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let dated: [(String, Date)] = names.compactMap { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            return (path, modified)
        }
        return dated.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 > rhs.0
        }.map(\.0)
    }

    private static func readStorage(_ path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 16 * 1024 * 1024 else {
            return nil
        }
        return data
    }

    private static func lastValue(in data: Data, marker: Data) -> String? {
        var found: String?
        var search = data.startIndex
        while let range = data.range(of: marker, in: search..<data.endIndex) {
            if let value = storageValue(in: data, at: range.upperBound) {
                found = value
            }
            search = range.upperBound
        }
        return found
    }

    /// Chromium 本地存储：键后面是「1 + 文本长度」的单字节，再跟 0x01 和文本。
    private static func storageValue(in data: Data, at index: Data.Index) -> String? {
        guard index < data.endIndex else { return nil }
        let length = Int(data[index])
        guard (1...127).contains(length) else { return nil }
        let start = data.index(after: index)
        guard let end = data.index(start, offsetBy: length, limitedBy: data.endIndex),
              data[start] == 0x01 else { return nil }
        let textStart = data.index(after: start)
        guard textStart <= end,
              let value = String(data: data.subdata(in: textStart..<end), encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }
}

/// 只看 Hermes 窗口前部的侧边栏标题。进入项目后标题会立刻变成项目名，本地存储要晚几秒。
enum HermesVisibleEntryReader {
    private static let backTitles: Set<String> = ["全部项目", "全部項目", "All projects"]
    private static let homeTitles: Set<String> = ["主页", "主頁", "Home"]
    private static let chromeTitles: Set<String> = [
        "会话", "機器人", "机器人", "项目", "專案", "Projects", "Sessions",
        "已置顶", "已置頂", "Pinned",
        "显示项目", "顯示項目", "Show projects",
        "全部项目", "全部項目", "All projects",
        "新建会话", "新建會話", "New session",
        "技能与工具", "消息平台", "产物", "定时任务",
        "操作", "新建工作树", "筛选", "新建项目"
    ]

    static func current() -> HermesVisibleEntry? {
        guard Bundle.main.bundleIdentifier == "com.tocode.mac" else { return nil }
        return readWindow()
    }

    /// 从已按界面顺序排好的标题里找出「已经进入」的项目或当前会话。供测试和窗口读取共用。
    static func entry(fromTitles titles: [String]) -> HermesVisibleEntry? {
        if let backIndex = titles.lastIndex(where: { backTitles.contains($0) }) {
            for title in titles[..<backIndex].reversed() {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.count > 80 || chromeTitles.contains(trimmed) || hasChromePrefix(trimmed) {
                    continue
                }
                if homeTitles.contains(trimmed) { return .home }
                return .entered(trimmed)
            }
        }
        for title in titles {
            if let session = openSessionTitle(title) { return .session(session) }
        }
        return nil
    }

    /// 侧边栏正在打开的会话行带关闭标记，例如「写入背景与规范内容 关闭」。
    private static func openSessionTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" 关闭", " 關閉", " Close"] where trimmed.hasSuffix(suffix) {
            let name = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 80 || chromeTitles.contains(name) || hasChromePrefix(name) { return nil }
            return name
        }
        return nil
    }

    private static func hasChromePrefix(_ title: String) -> Bool {
        ["打开 ", "打開 ", "Open ", "展开 ", "收起 ", "重新排序 ", "Expand ", "Collapse "].contains { title.hasPrefix($0) }
    }

    static func readWindow() -> HermesVisibleEntry? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.nousresearch.hermes").first else {
            return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let started = Date()
        guard let window = firstWindow(application) else { return nil }
        var titles: [String] = []
        var seen = 0
        var stop = false
        func walk(_ element: AXUIElement, depth: Int) {
            if stop || depth > 24 || seen > 240 || Date().timeIntervalSince(started) > 0.25 { return }
            seen += 1
            if let title = attribute(element, kAXTitleAttribute), !title.isEmpty {
                titles.append(title)
                if backTitles.contains(title) || title == "显示更早的消息" || title == "已思考" {
                    stop = true
                    return
                }
            }
            for child in children(element) where !stop {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return entry(fromTitles: titles)
    }

    private static func firstWindow(_ application: AXUIElement) -> AXUIElement? {
        elements(application, kAXWindowsAttribute).first
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    private static func elements(_ element: AXUIElement, _ attributeName: String) -> [AXUIElement] {
        guard let raw = copied(element, attributeName) else { return [] }
        if let list = raw as? [AXUIElement] { return list }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap {
            guard let item = CFArrayGetValueAtIndex(array, $0) else { return nil }
            let object = Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue()
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        copied(element, name) as? String
    }

    private static func copied(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
