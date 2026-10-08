import Foundation
import SQLite3

struct TogentStagedBatchStatus: Equatable {
    let batchKey: String
    let waitsForText: Bool
    let oldestReceivedAt: Date
}

final class TogentStore: @unchecked Sendable {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct StagedBatchPart {
        let id: UUID
        let fromUserID: String
        let contextToken: String
        let messageText: String
    }

    let databaseURL: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var startupError: Error?

    init(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.databaseURL = databaseURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.tocode.app", isDirectory: true)
            .appendingPathComponent("togent.sqlite")
        do {
            try bootstrap()
        } catch {
            startupError = error
        }
    }

    func roles() throws -> [TogentRole] {
        try withDatabase { database in
            try queryRoles(
                database,
                sql: """
                SELECT id, name, workspace_path, prompt, model_id, is_active, created_at, updated_at
                FROM roles
                ORDER BY name COLLATE NOCASE, created_at
                """
            )
        }
    }

    func role(id: UUID) throws -> TogentRole? {
        try withDatabase { database in
            try queryRoles(
                database,
                sql: """
                SELECT id, name, workspace_path, prompt, model_id, is_active, created_at, updated_at
                FROM roles WHERE id = ? LIMIT 1
                """,
                bindings: [.text(id.uuidString)]
            ).first
        }
    }

    func activeRole() throws -> TogentRole? {
        try withDatabase { database in
            try queryRoles(
                database,
                sql: """
                SELECT id, name, workspace_path, prompt, model_id, is_active, created_at, updated_at
                FROM roles WHERE is_active = 1 LIMIT 1
                """
            ).first
        }
    }

    @discardableResult
    func insertRole(_ role: TogentRole) throws -> TogentRole {
        try withDatabase { database in
            try transaction(database) {
                let roleCount = try scalarInt(database, sql: "SELECT COUNT(*) FROM roles")
                let activate = role.isActive || roleCount == 0
                if activate {
                    try execute(database, sql: "UPDATE roles SET is_active = 0")
                }
                try execute(
                    database,
                    sql: """
                    INSERT INTO roles
                    (id, name, workspace_path, prompt, model_id, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(role.id.uuidString),
                        .text(role.name),
                        .text(role.workspacePath),
                        .text(role.prompt),
                        .text(role.publishedModelID),
                        .integer(activate ? 1 : 0),
                        .double(role.createdAt.timeIntervalSince1970),
                        .double(role.updatedAt.timeIntervalSince1970)
                    ]
                )
            }
            applyPermissions()
            guard let inserted = try self.role(id: role.id) else {
                throw TogentError.database("角色写入后无法读取")
            }
            return inserted
        }
    }

    @discardableResult
    func updateRole(_ role: TogentRole) throws -> TogentRole {
        try withDatabase { database in
            try transaction(database) {
                if role.isActive {
                    try execute(
                        database,
                        sql: "UPDATE roles SET is_active = 0 WHERE id <> ?",
                        bindings: [.text(role.id.uuidString)]
                    )
                }
                try execute(
                    database,
                    sql: """
                    UPDATE roles
                    SET name = ?, workspace_path = ?, prompt = ?, model_id = ?,
                        is_active = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .text(role.name),
                        .text(role.workspacePath),
                        .text(role.prompt),
                        .text(role.publishedModelID),
                        .integer(role.isActive ? 1 : 0),
                        .double(role.updatedAt.timeIntervalSince1970),
                        .text(role.id.uuidString)
                    ],
                    requireChange: true
                )
            }
            guard let updated = try self.role(id: role.id) else {
                throw TogentError.roleNotFound
            }
            return updated
        }
    }

    func setActiveRole(id: UUID?) throws {
        try withDatabase { database in
            try transaction(database) {
                if let id {
                    guard try scalarInt(
                        database,
                        sql: "SELECT COUNT(*) FROM roles WHERE id = ?",
                        bindings: [.text(id.uuidString)]
                    ) == 1 else {
                        throw TogentError.roleNotFound
                    }
                }
                try execute(database, sql: "UPDATE roles SET is_active = 0")
                if let id {
                    try execute(
                        database,
                        sql: "UPDATE roles SET is_active = 1, updated_at = ? WHERE id = ?",
                        bindings: [.double(Date().timeIntervalSince1970), .text(id.uuidString)],
                        requireChange: true
                    )
                }
            }
        }
    }

    @discardableResult
    func stageJob(
        deduplicationKey: String,
        roleID: UUID?,
        fromUserID: String,
        contextToken: String,
        messageText: String,
        receivedAt: Date,
        batchKey: String = "",
        waitsForText: Bool = false,
        channel: TogentChannel = .wechat
    ) throws -> TogentJob {
        try withDatabase { database in
            let now = Date()
            try execute(
                database,
                sql: """
                INSERT OR IGNORE INTO jobs
                (id, dedupe_key, role_id, from_user_id, context_token, message_text,
                 batch_key, waits_for_text, received_at, state, attempt_count,
                 last_error, created_at, updated_at, channel)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'staged', 0, NULL, ?, ?, ?)
                """,
                bindings: [
                    .text(UUID().uuidString),
                    .text(deduplicationKey),
                    roleID.map { .text($0.uuidString) } ?? .null,
                    .text(fromUserID),
                    .text(contextToken),
                    .text(messageText),
                    .text(batchKey.isEmpty ? "single:\(deduplicationKey)" : batchKey),
                    .integer(waitsForText ? 1 : 0),
                    .double(receivedAt.timeIntervalSince1970),
                    .double(now.timeIntervalSince1970),
                    .double(now.timeIntervalSince1970),
                    .text(channel.rawValue)
                ]
            )
            guard let job = try job(database, deduplicationKey: deduplicationKey) else {
                throw TogentError.database("任务暂存失败")
            }
            return job
        }
    }

    func queueStagedJob(deduplicationKey: String) throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                UPDATE jobs SET state = 'queued', updated_at = ?
                WHERE dedupe_key = ? AND state = 'staged'
                """,
                bindings: [.double(Date().timeIntervalSince1970), .text(deduplicationKey)]
            )
        }
    }

    func stagedBatchStatus(
        deduplicationKey: String
    ) throws -> TogentStagedBatchStatus? {
        try withDatabase { database in
            let keys = try textColumn(
                database,
                sql: """
                SELECT batch_key FROM jobs
                WHERE dedupe_key = ? AND state = 'staged'
                LIMIT 1
                """,
                bindings: [.text(deduplicationKey)]
            )
            guard let batchKey = keys.first else { return nil }
            return try stagedBatchStatus(database, batchKey: batchKey)
        }
    }

    func stagedBatchStatus(batchKey: String) throws -> TogentStagedBatchStatus? {
        try withDatabase {
            try stagedBatchStatus($0, batchKey: batchKey)
        }
    }

    func queueStagedBatch(batchKey: String) throws {
        try withDatabase { database in
            try transaction(database) {
                try queueStagedBatch(database, batchKey: batchKey)
            }
        }
    }

    func expireStagedBatch(batchKey: String) throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                UPDATE jobs
                SET state = 'completed', from_user_id = '', context_token = '',
                    message_text = '', last_error = NULL, updated_at = ?
                WHERE batch_key = ? AND state = 'staged'
                """,
                bindings: [
                    .double(Date().timeIntervalSince1970),
                    .text(batchKey)
                ]
            )
        }
    }

    func discardStagedJob(deduplicationKey: String) throws {
        try withDatabase { database in
            try execute(
                database,
                sql: "DELETE FROM jobs WHERE dedupe_key = ? AND state = 'staged'",
                bindings: [.text(deduplicationKey)]
            )
        }
    }

    func reconcileStagedJobs(
        committedKeys: Set<String>
    ) throws -> [TogentStagedBatchStatus] {
        var pendingImageBatches: [TogentStagedBatchStatus] = []
        try withDatabase { database in
            try transaction(database) {
                let staged = try textColumn(
                    database,
                    sql: "SELECT dedupe_key FROM jobs WHERE state = 'staged'"
                )
                for key in staged {
                    if !committedKeys.contains(key) {
                        try execute(
                            database,
                            sql: "DELETE FROM jobs WHERE dedupe_key = ? AND state = 'staged'",
                            bindings: [.text(key)]
                        )
                    }
                }
                let batchKeys = try textColumn(
                    database,
                    sql: """
                    SELECT batch_key FROM jobs
                    WHERE state = 'staged'
                    GROUP BY batch_key
                    ORDER BY MIN(created_at)
                    """
                )
                for batchKey in batchKeys {
                    guard let status = try stagedBatchStatus(
                        database,
                        batchKey: batchKey
                    ) else {
                        continue
                    }
                    if status.waitsForText {
                        pendingImageBatches.append(status)
                    } else {
                        try queueStagedBatch(database, batchKey: batchKey)
                    }
                }
            }
        }
        return pendingImageBatches
    }

    func recoverInterruptedJobs() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                UPDATE jobs
                SET state = 'queued', last_error = 'App 在任务运行期间退出，已恢复排队',
                    updated_at = ?
                WHERE state = 'running'
                """,
                bindings: [.double(Date().timeIntervalSince1970)]
            )
        }
    }

    func nextQueuedJob() throws -> TogentJob? {
        try withDatabase { database in
            try queryJobs(
                database,
                sql: """
                SELECT id, dedupe_key, role_id, from_user_id, context_token, message_text,
                       received_at, state, attempt_count, last_error, created_at, updated_at,
                       channel
                FROM jobs WHERE state = 'queued'
                ORDER BY created_at, rowid LIMIT 1
                """
            ).first
        }
    }

    func markRunning(id: UUID) throws {
        try updateJob(
            id: id,
            state: .running,
            incrementAttempt: true,
            error: nil
        )
    }

    func markCompleted(id: UUID) throws {
        try finalizeJob(id: id, state: .completed, error: nil)
    }

    func markFailed(id: UUID, error: String) throws {
        try finalizeJob(id: id, state: .failed, error: error)
    }

    func hasPendingWork() throws -> Bool {
        try withDatabase { database in
            try scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM jobs WHERE state IN ('staged', 'queued', 'running')"
            ) > 0
        }
    }

    func jobs() throws -> [TogentJob] {
        try withDatabase { database in
            try queryJobs(
                database,
                sql: """
                SELECT id, dedupe_key, role_id, from_user_id, context_token, message_text,
                       received_at, state, attempt_count, last_error, created_at, updated_at,
                       channel
                FROM jobs ORDER BY created_at, rowid
                """
            )
        }
    }

    private func bootstrap() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try withOpenedDatabase { database in
            try executeScript(database, sql: "PRAGMA journal_mode = WAL")
            try executeScript(database, sql: "PRAGMA foreign_keys = ON")
            try execute(
                database,
                sql: """
                CREATE TABLE IF NOT EXISTS roles (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    workspace_path TEXT NOT NULL UNIQUE,
                    prompt TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            try execute(
                database,
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS roles_one_active
                ON roles(is_active) WHERE is_active = 1
                """
            )
            try execute(
                database,
                sql: """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    dedupe_key TEXT NOT NULL UNIQUE,
                    role_id TEXT,
                    from_user_id TEXT NOT NULL,
                    context_token TEXT NOT NULL,
                    message_text TEXT NOT NULL,
                    batch_key TEXT NOT NULL,
                    waits_for_text INTEGER NOT NULL DEFAULT 0
                        CHECK (waits_for_text IN (0, 1)),
                    received_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('staged', 'queued', 'running', 'completed', 'failed')
                    ),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY(role_id) REFERENCES roles(id)
                )
                """
            )
            try ensureBatchColumns(database)
            try ensureChannelColumn(database)
            try execute(
                database,
                sql: "CREATE INDEX IF NOT EXISTS jobs_state_order ON jobs(state, created_at)"
            )
            try execute(
                database,
                sql: """
                CREATE INDEX IF NOT EXISTS jobs_staged_batch
                ON jobs(batch_key, state, created_at)
                """
            )
        }
        applyPermissions()
    }

    private func ensureChannelColumn(_ database: OpaquePointer) throws {
        let columns = try columnNames(database, table: "jobs")
        if !columns.contains("channel") {
            try executeScript(
                database,
                sql: "ALTER TABLE jobs ADD COLUMN channel TEXT NOT NULL DEFAULT 'wechat'"
            )
        }
    }

    private func ensureBatchColumns(_ database: OpaquePointer) throws {
        let columns = try columnNames(database, table: "jobs")
        if !columns.contains("batch_key") {
            try executeScript(
                database,
                sql: "ALTER TABLE jobs ADD COLUMN batch_key TEXT NOT NULL DEFAULT ''"
            )
        }
        if !columns.contains("waits_for_text") {
            try executeScript(
                database,
                sql: """
                ALTER TABLE jobs ADD COLUMN waits_for_text INTEGER NOT NULL DEFAULT 0
                CHECK (waits_for_text IN (0, 1))
                """
            )
        }
        try execute(
            database,
            sql: """
            UPDATE jobs SET batch_key = 'legacy:' || id
            WHERE batch_key = ''
            """
        )
    }

    private func columnNames(
        _ database: OpaquePointer,
        table: String
    ) throws -> Set<String> {
        let statement = try prepare(
            database,
            sql: "PRAGMA table_info(\(table))",
            bindings: []
        )
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.insert(text(statement, 1))
        }
        return names
    }

    private func updateJob(
        id: UUID,
        state: TogentJobState,
        incrementAttempt: Bool,
        error: String?
    ) throws {
        try withDatabase { database in
            let attempts = incrementAttempt ? "attempt_count + 1" : "attempt_count"
            try execute(
                database,
                sql: """
                UPDATE jobs SET state = ?, attempt_count = \(attempts),
                    last_error = ?, updated_at = ? WHERE id = ?
                """,
                bindings: [
                    .text(state.rawValue),
                    error.map(SQLiteValue.text) ?? .null,
                    .double(Date().timeIntervalSince1970),
                    .text(id.uuidString)
                ],
                requireChange: true
            )
        }
    }

    private func finalizeJob(
        id: UUID,
        state: TogentJobState,
        error: String?
    ) throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                UPDATE jobs
                SET state = ?, from_user_id = '', context_token = '', message_text = '',
                    last_error = ?, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(state.rawValue),
                    error.map(SQLiteValue.text) ?? .null,
                    .double(Date().timeIntervalSince1970),
                    .text(id.uuidString)
                ],
                requireChange: true
            )
        }
    }

    private func stagedBatchStatus(
        _ database: OpaquePointer,
        batchKey: String
    ) throws -> TogentStagedBatchStatus? {
        let statement = try prepare(
            database,
            sql: """
            SELECT batch_key, MIN(received_at),
                   SUM(CASE WHEN waits_for_text = 0 THEN 1 ELSE 0 END),
                   COUNT(*)
            FROM jobs
            WHERE batch_key = ? AND state = 'staged'
            GROUP BY batch_key
            """,
            bindings: [.text(batchKey)]
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int64(statement, 3) > 0 else {
            return nil
        }
        return TogentStagedBatchStatus(
            batchKey: text(statement, 0),
            waitsForText: sqlite3_column_int64(statement, 2) == 0,
            oldestReceivedAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 1)
            )
        )
    }

    private func queueStagedBatch(
        _ database: OpaquePointer,
        batchKey: String
    ) throws {
        guard let status = try stagedBatchStatus(database, batchKey: batchKey) else {
            return
        }
        guard !status.waitsForText else {
            throw TogentError.database("纯图片批次仍在等待后续文字")
        }
        let statement = try prepare(
            database,
            sql: """
            SELECT id, from_user_id, context_token, message_text
            FROM jobs
            WHERE batch_key = ? AND state = 'staged'
            ORDER BY created_at, rowid
            """,
            bindings: [.text(batchKey)]
        )
        defer { sqlite3_finalize(statement) }
        var parts: [StagedBatchPart] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else {
                throw TogentError.database("批次任务 UUID 损坏")
            }
            parts.append(StagedBatchPart(
                id: id,
                fromUserID: text(statement, 1),
                contextToken: text(statement, 2),
                messageText: text(statement, 3)
            ))
        }
        guard let primary = parts.first, let latest = parts.last else { return }
        let replyPart = parts.reversed().first {
            !$0.contextToken.isEmpty
        } ?? latest
        let combined: String
        if parts.count == 1 {
            combined = primary.messageText
        } else {
            combined = parts.enumerated().map { index, part in
                "【连续消息 \(index + 1)/\(parts.count)】\n\(part.messageText)"
            }.joined(separator: "\n\n")
        }
        let now = Date().timeIntervalSince1970
        try execute(
            database,
            sql: """
            UPDATE jobs
            SET from_user_id = ?, context_token = ?, message_text = ?,
                state = 'queued', updated_at = ?
            WHERE id = ? AND state = 'staged'
            """,
            bindings: [
                .text(replyPart.fromUserID),
                .text(replyPart.contextToken),
                .text(combined),
                .double(now),
                .text(primary.id.uuidString)
            ],
            requireChange: true
        )
        for follower in parts.dropFirst() {
            try execute(
                database,
                sql: """
                UPDATE jobs
                SET state = 'completed', from_user_id = '', context_token = '',
                    message_text = '', last_error = NULL, updated_at = ?
                WHERE id = ? AND state = 'staged'
                """,
                bindings: [
                    .double(now),
                    .text(follower.id.uuidString)
                ],
                requireChange: true
            )
        }
    }

    private func job(
        _ database: OpaquePointer,
        deduplicationKey: String
    ) throws -> TogentJob? {
        try queryJobs(
            database,
            sql: """
            SELECT id, dedupe_key, role_id, from_user_id, context_token, message_text,
                   received_at, state, attempt_count, last_error, created_at, updated_at,
                   channel
            FROM jobs WHERE dedupe_key = ? LIMIT 1
            """,
            bindings: [.text(deduplicationKey)]
        ).first
    }

    private func queryRoles(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [TogentRole] {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var values: [TogentRole] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else {
                throw TogentError.database("角色 UUID 损坏")
            }
            values.append(TogentRole(
                id: id,
                name: text(statement, 1),
                workspacePath: text(statement, 2),
                prompt: text(statement, 3),
                publishedModelID: text(statement, 4),
                isActive: sqlite3_column_int(statement, 5) == 1,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            ))
        }
        return values
    }

    private func queryJobs(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [TogentJob] {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var values: [TogentJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)),
                  let state = TogentJobState(rawValue: text(statement, 7)) else {
                throw TogentError.database("任务记录损坏")
            }
            let rawRole = optionalText(statement, 2)
            values.append(TogentJob(
                id: id,
                deduplicationKey: text(statement, 1),
                roleID: rawRole.flatMap(UUID.init(uuidString:)),
                fromUserID: text(statement, 3),
                contextToken: text(statement, 4),
                messageText: text(statement, 5),
                receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                state: state,
                attemptCount: Int(sqlite3_column_int(statement, 8)),
                lastError: optionalText(statement, 9),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                channel: text(statement, 12) == TogentChannel.app.rawValue ? .app : .wechat
            ))
        }
        return values
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let startupError {
            throw TogentError.unavailable(startupError.localizedDescription)
        }
        return try withOpenedDatabase(body)
    }

    private func withOpenedDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw TogentError.database("无法打开数据库")
        }
        defer {
            sqlite3_close(database)
            applyPermissions()
        }
        sqlite3_busy_timeout(database, 3_000)
        return try body(database)
    }

    private func transaction(_ database: OpaquePointer, _ body: () throws -> Void) throws {
        try execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try body()
            try execute(database, sql: "COMMIT")
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw mapSQLiteError(error)
        }
    }

    private enum SQLiteValue {
        case text(String)
        case integer(Int)
        case double(Double)
        case null
    }

    private func prepare(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        do {
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text):
                    result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
                case .integer(let integer):
                    result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
                case .double(let double):
                    result = sqlite3_bind_double(statement, index, double)
                case .null:
                    result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else {
                    throw databaseError(database)
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func execute(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue] = [],
        requireChange: Bool = false
    ) throws {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw mapConstraint(database)
        }
        if requireChange, sqlite3_changes(database) != 1 {
            throw TogentError.roleNotFound
        }
    }

    private func executeScript(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func scalarInt(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> Int {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func textColumn(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [String] {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(text(statement, 0))
        }
        return result
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func databaseError(_ database: OpaquePointer) -> TogentError {
        TogentError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func mapConstraint(_ database: OpaquePointer) -> Error {
        let message = String(cString: sqlite3_errmsg(database))
        if message.contains("roles.name") {
            return TogentError.duplicateRoleName
        }
        if message.contains("roles.workspace_path") {
            return TogentError.duplicateWorkspacePath
        }
        return TogentError.database(message)
    }

    private func mapSQLiteError(_ error: Error) -> Error {
        error
    }

    private func applyPermissions() {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        }
    }
}
