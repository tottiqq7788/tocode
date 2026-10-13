import Foundation
import SQLite3

/// Hermes 当前选中的正式项目。
struct HermesProject: Equatable {
    let name: String
    let rootPath: String
}

/// 只读解析 ~/.hermes/projects.db 的当前项目，绝不写回。
struct HermesProjectService {
    private let databasePath: String
    private let fs: FileSystemService

    init(
        home: String = NSHomeDirectory(),
        fs: FileSystemService = FileSystemService(),
        databasePath: String? = nil
    ) {
        self.databasePath = databasePath
            ?? (home as NSString).appendingPathComponent(".hermes/projects.db")
        self.fs = fs
    }

    /// active_id → 未归档项目的 primary_path；主目录为空时用 is_primary 文件夹。
    /// 库缺失、读失败、无当前项目、已归档或路径不是现存目录时返回 nil。
    func resolveProject() -> HermesProject? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        guard let row = queryOne(
            database,
            sql: """
            SELECT name, primary_path, archived, id
            FROM projects
            WHERE id = (SELECT value FROM project_meta WHERE key = 'active_id')
            LIMIT 1
            """
        ) else { return nil }
        guard row.count == 4, row[2] == "0", let projectID = row[3], !projectID.isEmpty else { return nil }

        let primary = (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if !primary.isEmpty {
            candidate = primary
        } else {
            let folder = (queryOne(
                database,
                sql: "SELECT path FROM project_folders WHERE project_id = ? AND is_primary = 1 LIMIT 1",
                bindings: [projectID]
            )?.first ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !folder.isEmpty else { return nil }
            candidate = folder
        }

        let standardized = (candidate as NSString).standardizingPath
        guard fs.isExistingDirectory(standardized) else { return nil }
        let name = row[0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HermesProject(name: name.isEmpty ? "未命名项目" : name, rootPath: standardized)
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
        return (0..<sqlite3_column_count(statement)).map { column in
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let bytes = sqlite3_column_text(statement, column) else {
                return nil
            }
            return String(cString: bytes)
        }
    }
}
