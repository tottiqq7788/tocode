import Foundation
import SQLite3
import Darwin

enum AnkerCredentialError: LocalizedError {
    case invalidKey
    case configuration(String)
    case changed
    case writeFailed
    case database
    case recoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "请输入完整的安克 API 密钥，不要包含空格、换行或 Bearer 前缀。"
        case .configuration(let target): return "\(target) 配置不符合预期，尚未保存。请检查该工具的安克配置。"
        case .changed: return "配置已被其他程序修改，本次保存已取消。请关闭相关设置窗口后重试。"
        case .writeFailed: return "密钥保存失败，已恢复本次修改。请检查配置文件的写入权限。"
        case .database: return "无法更新 CC Switch 数据库，已取消本次保存。"
        case .recoveryFailed: return "保存失败，且部分配置无法恢复。请检查四个工具的配置后重新保存，不要继续使用可能不一致的密钥。"
        }
    }
}

protocol AnkerCredentialUpdating: AnyObject, Sendable {
    func update(_ input: String) throws
}

/// Only the four default user configurations are in scope. No credentials leave this process.
final class AnkerCredentialService: AnkerCredentialUpdating, @unchecked Sendable {
    static let endpoint = "https://ai-router.anker-in.com/v1"
    static let hermesModel = "apps/v_model/deepseek-v4-pro"
    private static let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let home: URL
    private let writer: (Data, URL) throws -> Void
    private let beforeCommit: () throws -> Void

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         writer: @escaping (Data, URL) throws -> Void = AnkerCredentialService.atomicWrite,
         beforeCommit: @escaping () throws -> Void = {}) {
        self.home = home
        self.writer = writer
        self.beforeCommit = beforeCommit
    }

    static func normalizedKey(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.range(of: "^[A-Za-z0-9._~+/-]+=*$", options: .regularExpression) != nil else {
            throw AnkerCredentialError.invalidKey
        }
        return key
    }

    private struct FileEdit {
        let url: URL
        let original: Data
        let updated: Data
    }

    private struct Provider {
        let id: String
        let original: String
        let updated: String
        let backup: String?
        let updatedBackup: String?
    }

    /// Read-only inspection used by local diagnostics; never attempts an API request.
    func validateConfiguration() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let db = try openDatabase(readOnly: true)
        defer { sqlite3_close(db) }
        let key = "tocode-preflight-placeholder"
        _ = try prepareFiles(key: key)
        _ = try prepareProvider(db: db, key: key)
    }

    func update(_ input: String) throws {
        let key = try Self.normalizedKey(input)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let db = try openDatabase(readOnly: false)
        defer { sqlite3_close(db) }
        var attempted: [FileEdit] = []
        var transaction = false
        do {
            try execute("BEGIN IMMEDIATE", db: db)
            transaction = true
            let files = try prepareFiles(key: key)
            let provider = try prepareProvider(db: db, key: key)
            let settings = try read(".cc-switch/settings.json", target: "CC Switch")
            let codexConfig = try read(".codex/config.toml", target: "Codex")
            try updateRow(db: db, sql: "UPDATE providers SET settings_config = ? WHERE id = ? AND app_type = 'codex' AND is_current = 1 AND settings_config = ?",
                          values: [provider.updated, provider.id, provider.original])
            if let backup = provider.backup, let updated = provider.updatedBackup {
                try updateRow(db: db, sql: "UPDATE proxy_live_backup SET original_config = ? WHERE app_type = 'codex' AND original_config = ?", values: [updated, backup])
            }
            for edit in files {
                guard try Data(contentsOf: edit.url) == edit.original else { throw AnkerCredentialError.changed }
                // Track BEFORE writing: a writer may replace the file and then report an error.
                attempted.append(edit)
                try writer(edit.updated, edit.url)
            }
            try beforeCommit()
            for edit in files {
                guard try Data(contentsOf: edit.url) == edit.updated,
                      let mode = try FileManager.default.attributesOfItem(atPath: edit.url.path)[.posixPermissions] as? NSNumber,
                      mode.intValue & 0o777 == 0o600 else { throw AnkerCredentialError.writeFailed }
            }
            guard try read(".cc-switch/settings.json", target: "CC Switch") == settings,
                  try read(".codex/config.toml", target: "Codex") == codexConfig else { throw AnkerCredentialError.changed }
            let verified = try prepareProvider(db: db, key: key)
            guard verified.id == provider.id, verified.original == provider.updated,
                  verified.backup == provider.updatedBackup else { throw AnkerCredentialError.changed }
            try execute("COMMIT", db: db)
            transaction = false
        } catch {
            var recovered = true
            if transaction { do { try execute("ROLLBACK", db: db) } catch { recovered = false } }
            for edit in attempted.reversed() {
                do {
                    let current = try Data(contentsOf: edit.url)
                    if current == edit.original { continue }
                    guard current == edit.updated else { throw AnkerCredentialError.changed }
                    try writer(edit.original, edit.url)
                    guard try Data(contentsOf: edit.url) == edit.original else { throw AnkerCredentialError.recoveryFailed }
                } catch { recovered = false }
            }
            guard recovered else { throw AnkerCredentialError.recoveryFailed }
            throw (error as? AnkerCredentialError) ?? AnkerCredentialError.writeFailed
        }
    }

    private func read(_ relative: String, target: String) throws -> Data {
        let url = home.appendingPathComponent(relative)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url) else { throw AnkerCredentialError.configuration(target) }
        return data
    }

    private func object(_ data: Data, target: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnkerCredentialError.configuration(target)
        }
        return value
    }

    private func encoded(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    private func prepareFiles(key: String) throws -> [FileEdit] {
        var result: [FileEdit] = []
        func editJSON(_ path: String, target: String, transform: (inout [String: Any]) throws -> Void) throws {
            let original = try read(path, target: target)
            var value = try object(original, target: target)
            try transform(&value)
            result.append(FileEdit(url: home.appendingPathComponent(path), original: original, updated: try encoded(value)))
        }
        try editJSON(".config/opencode/opencode.json", target: "OpenCode") { value in
            guard var providers = value["provider"] as? [String: Any],
                  var anker = providers["anker"] as? [String: Any],
                  var options = anker["options"] as? [String: Any],
                  options["baseURL"] as? String == Self.endpoint else { throw AnkerCredentialError.configuration("OpenCode") }
            options["apiKey"] = key
            anker["options"] = options; providers["anker"] = anker; value["provider"] = providers
        }
        try editJSON(".pi/agent/models.json", target: "pi") { value in
            guard var providers = value["providers"] as? [String: Any],
                  var anker = providers["anker"] as? [String: Any],
                  anker["baseUrl"] as? String == Self.endpoint else { throw AnkerCredentialError.configuration("pi") }
            // Resolve on every pi request so later rotations do not depend on an in-memory key.
            let path = home.appendingPathComponent(".config/opencode/opencode.json").path
            let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            anker["apiKey"] = "!/usr/bin/plutil -extract provider.anker.options.apiKey raw -o - \(quotedPath)"
            providers["anker"] = anker; value["providers"] = providers
        }
        for (path, target, type, field) in [
            (".pi/agent/auth.json", "pi", "api_key", "key"),
            (".local/share/opencode/auth.json", "OpenCode", "api", "key")
        ] {
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) else { continue }
            let data = try read(path, target: target)
            let value = try object(data, target: target)
            guard value["anker"] != nil else { continue }
            try editJSON(path, target: target) { value in
                guard var auth = value["anker"] as? [String: Any], auth["type"] as? String == type else {
                    throw AnkerCredentialError.configuration(target)
                }
                auth[field] = key; value["anker"] = auth
            }
        }
        let authPath = ".hermes/auth.json"
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(authPath).path) {
            let auth = try object(read(authPath, target: "Hermes"), target: "Hermes")
            let pool = auth["credential_pool"] as? [String: Any] ?? [:]
            guard !pool.keys.contains(where: { $0.lowercased().contains("custom") || $0.lowercased().contains("anker") }) else {
                throw AnkerCredentialError.configuration("Hermes 凭据池")
            }
        }
        for (path, transform) in [
            (".hermes/.env", { (text: String) throws in try Self.replaceEnvironment(text, key: key) }),
            (".hermes/config.yaml", { (text: String) throws in try Self.replaceHermesModel(text) })
        ] {
            let original = try read(path, target: "Hermes")
            guard let text = String(data: original, encoding: .utf8) else { throw AnkerCredentialError.configuration("Hermes") }
            result.append(FileEdit(url: home.appendingPathComponent(path), original: original, updated: Data(try transform(text).utf8)))
        }
        return result
    }

    static func replaceEnvironment(_ text: String, key: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let indices = lines.indices.filter {
            lines[$0].range(of: "^\\s*(?:export\\s+)?ANKER_API_KEY\\s*=", options: .regularExpression) != nil
        }
        guard indices.count <= 1 else { throw AnkerCredentialError.configuration("Hermes 环境变量") }
        let assignment = "ANKER_API_KEY=\(key)"
        if let index = indices.first { lines[index] = assignment }
        else {
            if lines.last == "" { lines.removeLast() }
            lines.append(assignment); lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Patch simple scalar keys in the existing model block; do not reserialize unrelated YAML.
    static func replaceHermesModel(_ text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].range(of: "^model\\s*:", options: .regularExpression) != nil }
        guard starts.count == 1, let start = starts.first,
              lines[start].range(of: "^model:\\s*(?:#.*)?$", options: .regularExpression) != nil else { throw AnkerCredentialError.configuration("Hermes 模型") }
        let end = ((start + 1)..<lines.count).first {
            let line = lines[$0]
            return !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#")
        } ?? lines.count
        let fields = ["default", "provider", "base_url", "api_key", "api_mode", "api"]
        var found: [String: Int] = [:]
        for index in (start + 1)..<end {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            guard !line.contains("\t"), !line.contains("<<:") else { throw AnkerCredentialError.configuration("Hermes 模型") }
            for field in fields {
                if line.range(of: "^  \(field):", options: .regularExpression) != nil {
                    guard found[field] == nil else { throw AnkerCredentialError.configuration("Hermes 模型") }
                    found[field] = index
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("\(field):") {
                    throw AnkerCredentialError.configuration("Hermes 模型缩进")
                }
            }
        }
        func scalar(_ field: String) -> String? {
            guard let index = found[field], let colon = lines[index].firstIndex(of: ":") else { return nil }
            let value = lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
            if value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()) }
            return value
        }
        let provider = scalar("provider")
        guard (provider == "deepseek" && (scalar("base_url") ?? "").isEmpty)
                || (provider == "custom" && scalar("base_url") == endpoint),
              found["default"] != nil else { throw AnkerCredentialError.configuration("Hermes 模型") }
        let replacements = [
            ("default", hermesModel), ("provider", "custom"), ("base_url", endpoint),
            ("api_key", "\"${ANKER_API_KEY}\""), ("api_mode", "chat_completions")
        ]
        var additions: [String] = []
        for (field, value) in replacements {
            let replacement = "  \(field): \(value)"
            if let index = found[field] { lines[index] = replacement }
            else { additions.append(replacement) }
        }
        // The legacy alias must not retain a second, stale credential.
        if let index = found["api"] { lines[index] = "  api: \"${ANKER_API_KEY}\"" }
        lines.insert(contentsOf: additions, at: start + 1)
        return lines.joined(separator: "\n")
    }

    /// Read only the selected provider's URL, not a matching hostname elsewhere in the document.
    static func selectedBaseURL(_ text: String) throws -> String {
        try selectedCodexProvider(text).url
    }

    private static func selectedCodexProvider(_ text: String) throws -> (name: String, url: String) {
        var section = ""
        var provider: String?
        var urls: [String: String] = [:]
        func value(_ line: String) throws -> String {
            guard let equal = line.firstIndex(of: "=") else { throw AnkerCredentialError.configuration("Codex") }
            let raw = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            let pattern = "^[\"']([^\"'\\r\\n]+)[\"']\\s*(?:#.*)?$"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { throw AnkerCredentialError.configuration("Codex") }
            return String(raw[range])
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let closing = line.firstIndex(of: "]") else { throw AnkerCredentialError.configuration("Codex") }
                section = String(line[line.index(after: line.startIndex)..<closing])
            } else if section.isEmpty && line.range(of: "^model_provider\\s*=", options: .regularExpression) != nil {
                guard provider == nil else { throw AnkerCredentialError.configuration("Codex") }
                provider = try value(line)
            } else if section.hasPrefix("model_providers.") && line.range(of: "^base_url\\s*=", options: .regularExpression) != nil {
                guard urls[section] == nil else { throw AnkerCredentialError.configuration("Codex") }
                urls[section] = try value(line)
            }
        }
        guard let provider, let url = urls["model_providers.\(provider)"] else { throw AnkerCredentialError.configuration("Codex") }
        return (provider, url)
    }

    static func rotateEmbeddedBearer(_ text: String, key: String) throws -> String {
        let selected = try selectedCodexProvider(text)
        var lines = text.components(separatedBy: "\n")
        var section = ""
        var count = 0
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<end])
            }
            guard section == "model_providers.\(selected.name)" else { continue }
            if line.range(of: "^env_key\\s*=", options: .regularExpression) != nil {
                throw AnkerCredentialError.configuration("CC Switch 环境变量凭据覆盖")
            }
            guard line.range(of: "^experimental_bearer_token\\s*=", options: .regularExpression) != nil else { continue }
            count += 1
            let regex = try NSRegularExpression(pattern: "^(\\s*experimental_bearer_token\\s*=\\s*)(?:\"[^\"]*\"|'[^']*')(\\s*(?:#.*)?)$")
            let range = NSRange(lines[index].startIndex..., in: lines[index])
            guard count == 1, regex.firstMatch(in: lines[index], range: range) != nil else {
                throw AnkerCredentialError.configuration("CC Switch 模板密钥")
            }
            lines[index] = regex.stringByReplacingMatches(in: lines[index], range: range, withTemplate: "$1\"\(key)\"$2")
        }
        return lines.joined(separator: "\n")
    }

    private func prepareProvider(db: OpaquePointer, key: String) throws -> Provider {
        let rows = try query("SELECT id, settings_config FROM providers WHERE app_type = 'codex' AND is_current = 1", db: db)
        guard rows.count == 1, let row = rows.first else { throw AnkerCredentialError.configuration("CC Switch 当前服务商") }
        let settings = try object(read(".cc-switch/settings.json", target: "CC Switch"), target: "CC Switch")
        guard settings["currentProviderCodex"] as? String == row[0] else { throw AnkerCredentialError.configuration("CC Switch 当前服务商") }
        func rotated(_ json: String) throws -> String {
            var value = try object(Data(json.utf8), target: "CC Switch")
            guard let template = value["config"] as? String,
                  try Self.selectedBaseURL(template) == Self.endpoint,
                  var auth = value["auth"] as? [String: Any] else { throw AnkerCredentialError.configuration("CC Switch 安克服务商") }
            let env = value["env"] as? [String: Any]
            guard (env?["OPENAI_API_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnkerCredentialError.configuration("CC Switch 环境变量凭据覆盖")
            }
            auth["OPENAI_API_KEY"] = key; value["auth"] = auth
            value["config"] = try Self.rotateEmbeddedBearer(template, key: key)
            return String(decoding: try encoded(value), as: UTF8.self)
        }
        let proxy = try query("SELECT listen_port, enabled, auto_failover_enabled FROM proxy_config WHERE app_type = 'codex'", db: db)
        guard proxy.count == 1, proxy[0][1] == "1", proxy[0][2] == "0",
              let port = Int(proxy[0][0]),
              let text = String(data: try read(".codex/config.toml", target: "Codex"), encoding: .utf8),
              let url = URLComponents(string: try Self.selectedBaseURL(text)),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              url.port == port, url.path == "/v1", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw AnkerCredentialError.configuration("Codex 的 CC Switch 代理") }
        let backups = try query("SELECT original_config FROM proxy_live_backup WHERE app_type = 'codex'", db: db)
        guard backups.count <= 1 else { throw AnkerCredentialError.configuration("CC Switch 恢复备份") }
        let backup = backups.first?.first
        return Provider(id: row[0], original: row[1], updated: try rotated(row[1]),
                        backup: backup, updatedBackup: try backup.map(rotated))
    }

    private func openDatabase(readOnly: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let path = home.appendingPathComponent(".cc-switch/cc-switch.db").path
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw AnkerCredentialError.database
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AnkerCredentialError.database }
    }

    private func query(_ sql: String, db: OpaquePointer) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AnkerCredentialError.database }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
            })
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw AnkerCredentialError.database }
        return result
    }

    private func updateRow(db: OpaquePointer, sql: String, values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AnkerCredentialError.database }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient) == SQLITE_OK else { throw AnkerCredentialError.database }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnkerCredentialError.database }
        guard sqlite3_changes(db) == 1 else { throw AnkerCredentialError.changed }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".tocode-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AnkerCredentialError.writeFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw AnkerCredentialError.writeFailed }
    }
}
