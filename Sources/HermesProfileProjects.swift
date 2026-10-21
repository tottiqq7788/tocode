import Foundation
import Security
import SQLite3

/// 只读写某个已有档案自己的 projects.db。桌面端跟随逻辑不走这里。
enum HermesProfileProjects {
    struct Project: Equatable {
        var id: String
        var name: String
        var rootPath: String
    }

    enum Failure: Error, Equatable {
        case invalidName
        case missingFolder
        case duplicateFolder
        case unreadable
    }

    static func databasePath(home: String, profile: String) -> String {
        (HermesProfileCatalog.home(userHome: home, profile: profile) as NSString).appendingPathComponent("projects.db")
    }

    static func isProjectID(_ value: String) -> Bool {
        value.range(of: #"^p_[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    static func list(databasePath: String) -> [Project] {
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = open(databasePath, create: false) else { return [] }
        defer { sqlite3_close(database) }
        let sql = """
        SELECT p.id, p.name,
               COALESCE(NULLIF(p.primary_path, ''), (
                   SELECT f.path FROM project_folders f
                   WHERE f.project_id = p.id AND f.is_primary = 1 LIMIT 1
               ))
        FROM projects p
        WHERE p.archived = 0
        ORDER BY p.created_at ASC
        """
        return query(database, sql: sql).compactMap { row in
            guard let id = row[0], let name = row[1], !id.isEmpty else { return nil }
            return Project(id: id, name: name.isEmpty ? "未命名项目" : name, rootPath: row[2] ?? "")
        }
    }

    static func project(databasePath: String, id: String) -> Project? {
        list(databasePath: databasePath).first { $0.id == id }
    }

    static func create(
        databasePath: String,
        name: String,
        folder: String,
        isDirectory: (String) -> Bool,
        now: Int = Int(Date().timeIntervalSince1970),
        makeID: () -> String = { "p_" + randomHex(4) }
    ) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw Failure.invalidName }
        let root = normalized(folder)
        guard !root.isEmpty, isDirectory(root) else { throw Failure.missingFolder }
        guard let database = open(databasePath, create: true) else { throw Failure.unreadable }
        defer { sqlite3_close(database) }
        if existingFolder(database, key: pathKey(root)) { throw Failure.duplicateFolder }
        let taken = Set(query(database, sql: "SELECT slug FROM projects").compactMap { $0[0] })
        let slug = uniqueSlug(for: trimmed, taken: taken)
        var identifier = makeID()
        var guardCount = 0
        while query(database, sql: "SELECT id FROM projects WHERE id = ?", bindings: [identifier]).isEmpty == false {
            identifier = makeID()
            guardCount += 1
            if guardCount > 5 { throw Failure.unreadable }
        }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw Failure.unreadable }
        let inserted = insert(
            database,
            sql: """
            INSERT INTO projects
            (id, slug, name, description, icon, color, board_slug, primary_path, created_at, archived)
            VALUES (?, ?, ?, '', NULL, NULL, NULL, ?, ?, 0)
            """,
            bindings: [identifier, slug, trimmed, root, String(now)]
        ) && insert(
            database,
            sql: """
            INSERT INTO project_folders (project_id, path, label, is_primary, added_at)
            VALUES (?, ?, NULL, 1, ?)
            """,
            bindings: [identifier, root, String(now)]
        )
        if inserted, sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK {
            sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            return Project(id: identifier, name: trimmed, rootPath: root)
        }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        throw Failure.unreadable
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        slug TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        description TEXT,
        icon TEXT,
        color TEXT,
        board_slug TEXT,
        primary_path TEXT,
        created_at INTEGER NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS project_folders (
        project_id TEXT NOT NULL,
        path TEXT NOT NULL,
        label TEXT,
        is_primary INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (project_id, path)
    );
    """

    private static func readOnlyURI(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.~"))
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(encoded)?immutable=1"
    }

    private static func open(_ path: String, create: Bool) -> OpaquePointer? {
        if create {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var database: OpaquePointer?
        let flags: Int32
        let filename: String
        if create {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            filename = path
        } else {
            // WAL 库在普通只读打开时，查询阶段会因为建不了共享内存而失败。immutable 只读主文件。
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            filename = Self.readOnlyURI(path)
        }
        guard sqlite3_open_v2(filename, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 2000)
        if create, sqlite3_exec(database, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func existingFolder(_ database: OpaquePointer, key: String) -> Bool {
        let rows = query(
            database,
            sql: """
            SELECT p.primary_path, f.path
            FROM projects p
            LEFT JOIN project_folders f ON f.project_id = p.id AND f.is_primary = 1
            WHERE p.archived = 0
            """
        )
        return rows.contains { row in
            pathKey(row[0] ?? "") == key || pathKey(row[1] ?? "") == key
        }
    }

    private static func uniqueSlug(for name: String, taken: Set<String>) -> String {
        var raw = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let character = Character(scalar)
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !raw.isEmpty { raw.append("-") }
                pendingDash = false
                raw.append(character)
            } else {
                pendingDash = true
            }
            if raw.count >= 64 { break }
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if raw.isEmpty { raw = "project" }
        var candidate = String(raw.prefix(64))
        var index = 2
        while taken.contains(candidate) {
            let suffix = "-\(index)"
            candidate = String(raw.prefix(max(1, 64 - suffix.count))) + suffix
            index += 1
        }
        return candidate
    }

    private static func normalized(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func pathKey(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return normalized(path).lowercased()
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func query(_ database: OpaquePointer, sql: String, bindings: [String] = []) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        guard bind(statement, bindings) else { return [] }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String?] = []
            for index in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, index) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func insert(_ database: OpaquePointer, sql: String, bindings: [String]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(statement, bindings) else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func bind(_ statement: OpaquePointer, _ bindings: [String]) -> Bool {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            if sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) != SQLITE_OK { return false }
        }
        return true
    }
}
