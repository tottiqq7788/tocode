import Foundation
import SQLite3

/// 把手机建的 Hermes 会话工作目录写成项目主目录，桌面侧边栏才归入项目而不是主页。
enum PhoneHermesSessionWorkspace {
    static func stateDatabasePath(projectsDatabase: String) -> String {
        (projectsDatabase as NSString).deletingLastPathComponent + "/state.db"
    }

    /// 只给 cwd 为空的会话写上目录。写失败返回 0，不抛错。
    @discardableResult
    static func stampEmptyCwd(stateDatabase: String, sessionIDs: [String], cwd: String) -> Int {
        let root = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !root.isEmpty, !ids.isEmpty, FileManager.default.fileExists(atPath: stateDatabase) else { return 0 }
        var database: OpaquePointer?
        guard sqlite3_open_v2(stateDatabase, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return 0
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return 0 }
        var updated = 0
        for id in ids {
            if stampOne(database, sessionID: id, cwd: root) { updated += 1 }
        }
        if sqlite3_exec(database, "COMMIT", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            return 0
        }
        return updated
    }

    static func cwd(stateDatabase: String, sessionID: String) -> String? {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, FileManager.default.fileExists(atPath: stateDatabase) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(stateDatabase, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT cwd FROM sessions WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: cString)
    }

    private static func stampOne(_ database: OpaquePointer, sessionID: String, cwd: String) -> Bool {
        var statement: OpaquePointer?
        let sql = """
        UPDATE sessions
        SET cwd = ?
        WHERE id = ?
          AND (cwd IS NULL OR trim(cwd) = '')
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, cwd, -1, destructor)
        sqlite3_bind_text(statement, 2, sessionID, -1, destructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return sqlite3_changes(database) > 0
    }
}
