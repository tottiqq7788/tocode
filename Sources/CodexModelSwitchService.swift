import Foundation
import SQLite3

enum CodexModelCompatibility: Equatable {
    case verified
    case unverified
    case unsupported(String)
}

enum CodexModelSource: String, CaseIterable {
    case general = "GPT / 通用路由"
    case anthropic = "Anthropic"
    case apps = "Apps"
    case hackathon = "Hackathon"
    case privateModels = "Private"
    case redzone = "Redzone"
    case gemini = "Gemini"
    case other = "其他"

    var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

struct CodexModelDescriptor: Equatable {
    let id: String
    let displayName: String
    let source: CodexModelSource
    let compatibility: CodexModelCompatibility
}

struct CodexModelState: Equatable {
    let liveModelID: String
    let providerModelID: String
    let providerID: String
    let providerName: String

    var isConsistent: Bool {
        liveModelID == providerModelID
    }
}

enum CodexModelSwitchError: LocalizedError {
    case databaseUnavailable
    case database(String)
    case currentProviderCount(Int)
    case providerNotAnker
    case providerConfigurationInvalid
    case missingCredential
    case liveConfigurationUnavailable
    case invalidModelAssignment(String)
    case catalogResponseInvalid
    case catalogEmpty
    case catalogHTTP(Int)
    case catalogNetwork(String)
    case concurrentProviderChange
    case configurationWrite(String)
    case configurationVerification
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "无法读取 CC Switch 数据库"
        case .database:
            return "CC Switch 数据库操作失败"
        case .currentProviderCount:
            return "未检测到唯一的当前 Codex Provider"
        case .providerNotAnker:
            return "当前 Codex Provider 不是 Anker AI Router"
        case .providerConfigurationInvalid:
            return "Anker Provider 配置结构无效"
        case .missingCredential:
            return "Anker Provider 缺少可用凭据"
        case .liveConfigurationUnavailable:
            return "无法读取 Codex 实时配置"
        case .invalidModelAssignment(let location):
            return "\(location) 中必须恰好存在一个顶层 model 配置"
        case .catalogResponseInvalid:
            return "Anker 模型列表格式无效"
        case .catalogEmpty:
            return "Anker 返回了空模型列表"
        case .catalogHTTP(let status):
            return "Anker 模型列表请求失败（HTTP \(status)）"
        case .catalogNetwork:
            return "无法连接 Anker 模型服务"
        case .concurrentProviderChange:
            return "CC Switch 当前 Provider 已变化，请重新打开菜单"
        case .configurationWrite:
            return "模型配置写入失败"
        case .configurationVerification:
            return "模型配置复核失败"
        case .rollbackFailed:
            return "模型配置恢复失败，请立即检查 CC Switch 与 Codex 配置"
        }
    }
}

protocol CodexModelSwitching: AnyObject, Sendable {
    func currentState() throws -> CodexModelState
    func fetchModels(completion: @escaping (Result<[CodexModelDescriptor], Error>) -> Void)
    func switchModel(to modelID: String) throws
}

enum CodexModelCatalog {
    private static let verifiedIDs: Set<String> = [
        "v_model/gpt",
        "v_model/gpt-5.5",
        "v_model/gpt-6-astra",
        "gpt-5.6-luna",
        "anthropic/v_model/claude-opus",
        "anthropic/v_model/claude-opus-4-6",
        "anthropic/v_model/claude-sonnet",
        "anthropic/v_model/claude-sonnet-4-6",
        "apps/v_model/deepseek-v4-pro",
        "apps/v_model/deepseek-v4-flash",
        "apps/v_model/qwen-max",
        "apps/v_model/kimi",
        "hackathon/v_model/glm-5.2",
        "gemini/v_model/gemini-flash"
    ]

    private static let exactNames: [String: String] = [
        "v_model/gpt": "GPT 默认路由",
        "v_model/gpt-5.5": "GPT-5.6 Sol",
        "v_model/gpt-6-astra": "GPT-6 Astra",
        "gpt-5.6-luna": "GPT-5.6 Luna",
        "anthropic/v_model/claude-opus": "Claude Opus",
        "anthropic/v_model/claude-opus-4-6": "Claude Opus 4.6",
        "anthropic/v_model/claude-sonnet": "Claude Sonnet",
        "anthropic/v_model/claude-sonnet-4-6": "Claude Sonnet 4.6",
        "apps/v_model/deepseek-v4-pro": "DeepSeek V4 Pro",
        "apps/v_model/deepseek-v4-flash": "DeepSeek V4 Flash",
        "apps/v_model/qwen-max": "Qwen Max",
        "apps/v_model/kimi": "Kimi",
        "hackathon/v_model/glm-5.2": "GLM 5.2",
        "gemini/v_model/gemini-flash": "Gemini Flash"
    ]

    static func descriptor(for id: String) -> CodexModelDescriptor {
        let source = source(for: id)
        let baseName = exactNames[id] ?? generatedName(for: id)
        let displayName = source == .general || source == .other
            ? baseName
            : "\(baseName) · \(source.rawValue)"
        return CodexModelDescriptor(
            id: id,
            displayName: displayName,
            source: source,
            compatibility: compatibility(for: id)
        )
    }

    static func displayName(for id: String) -> String {
        descriptor(for: id).displayName
    }

    static func descriptors(for ids: [String]) -> [CodexModelDescriptor] {
        var seen = Set<String>()
        return ids
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map(descriptor(for:))
            .sorted {
                if $0.source.sortOrder != $1.source.sortOrder {
                    return $0.source.sortOrder < $1.source.sortOrder
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    static func source(for id: String) -> CodexModelSource {
        if id.hasPrefix("anthropic/v_model/") { return .anthropic }
        if id.hasPrefix("apps/v_model/") { return .apps }
        if id.hasPrefix("hackathon/v_model/") { return .hackathon }
        if id.hasPrefix("private/v_model/") { return .privateModels }
        if id.hasPrefix("redzone/v_model/") { return .redzone }
        if id.hasPrefix("gemini/v_model/") { return .gemini }
        if id.hasPrefix("v_model/") || id.hasPrefix("gpt-") { return .general }
        return .other
    }

    static func compatibility(for id: String) -> CodexModelCompatibility {
        let lower = id.lowercased()
        if id == "anthropic/v_model/deepseek-v4-pro" {
            return .unsupported("该 ID 已确认不兼容 Codex /responses")
        }
        if lower.contains("image") || lower.contains("vision") || lower.contains("/tag-") {
            return .unsupported("图片、视觉或标签模型不能作为 Codex 主模型")
        }
        return verifiedIDs.contains(id) ? .verified : .unverified
    }

    private static func generatedName(for id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        return leaf.split(separator: "-").map { token in
            let value = String(token)
            switch value.lowercased() {
            case "gpt": return "GPT"
            case "glm": return "GLM"
            case "qwen": return "Qwen"
            case "kimi": return "Kimi"
            case "deepseek": return "DeepSeek"
            case "claude": return "Claude"
            case "gemini": return "Gemini"
            case "opus": return "Opus"
            case "sonnet": return "Sonnet"
            case "flash": return "Flash"
            case "max": return "Max"
            case "plus": return "Plus"
            case "pro": return "Pro"
            case "preview": return "Preview"
            case "private": return "Private"
            case "anthropic": return "Anthropic"
            default:
                if value.first?.isNumber == true { return value.uppercased() }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
        }.joined(separator: " ")
    }
}

enum CodexTOMLModel {
    static func read(from text: String, location: String) throws -> String {
        let match = try uniqueMatch(in: text, location: location)
        return match.value
    }

    static func replacing(in text: String, with modelID: String, location: String) throws -> String {
        guard !modelID.contains("\""), !modelID.contains("\n"), !modelID.contains("\r") else {
            throw CodexModelSwitchError.invalidModelAssignment(location)
        }
        let match = try uniqueMatch(in: text, location: location)
        var lines = text.components(separatedBy: "\n")
        let line = lines[match.lineIndex]
        lines[match.lineIndex] = String(line[..<match.valueRange.lowerBound])
            + modelID
            + String(line[match.valueRange.upperBound...])
        return lines.joined(separator: "\n")
    }

    private struct Match {
        let lineIndex: Int
        let value: String
        let valueRange: Range<String.Index>
    }

    private static func uniqueMatch(in text: String, location: String) throws -> Match {
        let pattern = #"^[ \t]*model[ \t]*=[ \t]*"([^"\\\r\n]*)"[ \t]*(?:#[^\r\n]*)?\r?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let lines = text.components(separatedBy: "\n")
        var matches: [Match] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                break
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let result = regex.firstMatch(in: line, range: range),
                  result.range.location != NSNotFound,
                  let valueRange = Range(result.range(at: 1), in: line) else {
                continue
            }
            matches.append(Match(
                lineIndex: index,
                value: String(line[valueRange]),
                valueRange: valueRange
            ))
        }

        guard matches.count == 1, let match = matches.first else {
            throw CodexModelSwitchError.invalidModelAssignment(location)
        }
        return match
    }
}

final class CodexModelSwitchService: CodexModelSwitching, @unchecked Sendable {
    private struct ProviderSnapshot {
        let id: String
        let name: String
        let settingsJSON: String
        let template: String
        let apiKey: String?
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
        }
        let data: [Item]
    }

    private static let catalogURL = URL(string: "https://ai-router.anker-in.com/v1/models")!
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databasePath: String
    private let liveConfigPath: String
    private let session: URLSession
    private let fileReader: (String) -> Data?
    private let fileWriter: (String, String) throws -> Void

    init(
        home: String = NSHomeDirectory(),
        databasePath: String? = nil,
        liveConfigPath: String? = nil,
        session: URLSession? = nil,
        fileReader: @escaping (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        fileWriter: @escaping (String, String) throws -> Void = CodexModelSwitchService.defaultAtomicWrite
    ) {
        self.databasePath = databasePath
            ?? (home as NSString).appendingPathComponent(".cc-switch/cc-switch.db")
        self.liveConfigPath = liveConfigPath
            ?? (home as NSString).appendingPathComponent(".codex/config.toml")
        self.session = session ?? Self.makeCatalogSession()
        self.fileReader = fileReader
        self.fileWriter = fileWriter
    }

    func currentState() throws -> CodexModelState {
        let database = try openDatabase(readOnly: true)
        defer { sqlite3_close(database) }
        let provider = try currentProvider(in: database)
        try validateAnker(provider)
        guard let liveData = fileReader(liveConfigPath),
              let liveText = String(data: liveData, encoding: .utf8) else {
            throw CodexModelSwitchError.liveConfigurationUnavailable
        }
        return CodexModelState(
            liveModelID: try CodexTOMLModel.read(from: liveText, location: "Codex 实时配置"),
            providerModelID: try CodexTOMLModel.read(from: provider.template, location: "CC Switch Provider 模板"),
            providerID: provider.id,
            providerName: provider.name
        )
    }

    func fetchModels(completion: @escaping (Result<[CodexModelDescriptor], Error>) -> Void) {
        let apiKey: String
        do {
            let database = try openDatabase(readOnly: true)
            defer { sqlite3_close(database) }
            let provider = try currentProvider(in: database)
            try validateAnker(provider)
            guard let credential = provider.apiKey, !credential.isEmpty else {
                throw CodexModelSwitchError.missingCredential
            }
            apiKey = credential
        } catch {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: Self.catalogURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(CodexModelSwitchError.catalogNetwork(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(CodexModelSwitchError.catalogResponseInvalid))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(CodexModelSwitchError.catalogHTTP(http.statusCode)))
                return
            }
            guard let data,
                  let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
                completion(.failure(CodexModelSwitchError.catalogResponseInvalid))
                return
            }
            let models = CodexModelCatalog.descriptors(for: decoded.data.map(\.id))
            guard !models.isEmpty else {
                completion(.failure(CodexModelSwitchError.catalogEmpty))
                return
            }
            completion(.success(models))
        }.resume()
    }

    func switchModel(to modelID: String) throws {
        guard let originalLiveData = fileReader(liveConfigPath),
              let originalLive = String(data: originalLiveData, encoding: .utf8) else {
            throw CodexModelSwitchError.liveConfigurationUnavailable
        }
        let updatedLive = try CodexTOMLModel.replacing(
            in: originalLive,
            with: modelID,
            location: "Codex 实时配置"
        )

        let database = try openDatabase(readOnly: false)
        defer { sqlite3_close(database) }
        var originalProvider: ProviderSnapshot?
        var committedSettingsJSON: String?
        var liveWasWritten = false
        var transactionOpen = false

        do {
            try execute("BEGIN IMMEDIATE", in: database)
            transactionOpen = true
            let provider = try currentProvider(in: database)
            originalProvider = provider
            try validateAnker(provider)
            let updatedTemplate = try CodexTOMLModel.replacing(
                in: provider.template,
                with: modelID,
                location: "CC Switch Provider 模板"
            )

            try updateProvider(
                id: provider.id,
                expectedSettingsJSON: provider.settingsJSON,
                template: updatedTemplate,
                in: database
            )
            let updatedProvider = try currentProvider(in: database)
            guard updatedProvider.id == provider.id else {
                throw CodexModelSwitchError.concurrentProviderChange
            }
            committedSettingsJSON = updatedProvider.settingsJSON

            try atomicWrite(updatedLive, to: liveConfigPath)
            liveWasWritten = true
            guard try readLiveModel() == modelID,
                  try CodexTOMLModel.read(
                    from: updatedProvider.template,
                    location: "CC Switch Provider 模板"
                  ) == modelID else {
                throw CodexModelSwitchError.configurationVerification
            }

            try execute("COMMIT", in: database)
            transactionOpen = false
        } catch {
            if transactionOpen {
                try? execute("ROLLBACK", in: database)
            }
            if liveWasWritten {
                do {
                    try restoreLive(originalLive, expectedCurrent: updatedLive)
                } catch {
                    throw CodexModelSwitchError.rollbackFailed
                }
            }
            throw error
        }

        do {
            let verifiedProvider = try currentProvider(in: database)
            guard let originalProvider,
                  verifiedProvider.id == originalProvider.id,
                  try CodexTOMLModel.read(
                    from: verifiedProvider.template,
                    location: "CC Switch Provider 模板"
                  ) == modelID,
                  try readLiveModel() == modelID else {
                throw CodexModelSwitchError.configurationVerification
            }
        } catch {
            guard let originalProvider, let committedSettingsJSON else {
                throw CodexModelSwitchError.rollbackFailed
            }
            do {
                try restoreCommittedProvider(
                    original: originalProvider,
                    expectedCurrentSettingsJSON: committedSettingsJSON,
                    in: database
                )
                try restoreLive(originalLive, expectedCurrent: updatedLive)
            } catch {
                throw CodexModelSwitchError.rollbackFailed
            }
            throw error
        }
    }

    private static func makeCatalogSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: AnkerCatalogRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private func openDatabase(readOnly: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw CodexModelSwitchError.databaseUnavailable
        }
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    private func currentProvider(in database: OpaquePointer) throws -> ProviderSnapshot {
        let sql = """
        SELECT id, name, settings_config
        FROM providers
        WHERE app_type = 'codex' AND is_current = 1
        ORDER BY id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [(String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((
                stringColumn(statement, index: 0),
                stringColumn(statement, index: 1),
                stringColumn(statement, index: 2)
            ))
        }
        guard rows.count == 1, let row = rows.first else {
            throw CodexModelSwitchError.currentProviderCount(rows.count)
        }
        guard let data = row.2.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = object["config"] as? String else {
            throw CodexModelSwitchError.providerConfigurationInvalid
        }
        let auth = object["auth"] as? [String: Any]
        return ProviderSnapshot(
            id: row.0,
            name: row.1,
            settingsJSON: row.2,
            template: template,
            apiKey: auth?["OPENAI_API_KEY"] as? String
        )
    }

    private func validateAnker(_ provider: ProviderSnapshot) throws {
        let nameMatches = provider.name.caseInsensitiveCompare("Anker AI Router") == .orderedSame
        let configMatches = provider.template.contains("ai-router.anker-in.com")
        guard nameMatches || configMatches else {
            throw CodexModelSwitchError.providerNotAnker
        }
    }

    private func updateProvider(
        id: String,
        expectedSettingsJSON: String,
        template: String,
        in database: OpaquePointer
    ) throws {
        let sql = """
        UPDATE providers
        SET settings_config = json_set(settings_config, '$.config', ?)
        WHERE id = ? AND app_type = 'codex' AND is_current = 1 AND settings_config = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }
        bind(template, to: 1, in: statement)
        bind(id, to: 2, in: statement)
        bind(expectedSettingsJSON, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database)
        }
        guard sqlite3_changes(database) == 1 else {
            throw CodexModelSwitchError.concurrentProviderChange
        }
    }

    private func restoreCommittedProvider(
        original: ProviderSnapshot,
        expectedCurrentSettingsJSON: String,
        in database: OpaquePointer
    ) throws {
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            let sql = """
            UPDATE providers
            SET settings_config = ?
            WHERE id = ? AND app_type = 'codex' AND is_current = 1 AND settings_config = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }
            bind(original.settingsJSON, to: 1, in: statement)
            bind(original.id, to: 2, in: statement)
            bind(expectedCurrentSettingsJSON, to: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                throw CodexModelSwitchError.concurrentProviderChange
            }
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private static func defaultAtomicWrite(_ text: String, _ path: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw CodexModelSwitchError.configurationWrite("UTF-8")
        }
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: path)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tocode-\(UUID().uuidString)")
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let permissions = attributes[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: permissions]
            ) else {
                throw CodexModelSwitchError.configurationWrite("temporary file")
            }
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CodexModelSwitchError.configurationWrite(error.localizedDescription)
        }
    }

    private func atomicWrite(_ text: String, to path: String) throws {
        try fileWriter(text, path)
    }

    private func readLiveModel() throws -> String {
        guard let data = fileReader(liveConfigPath),
              let text = String(data: data, encoding: .utf8) else {
            throw CodexModelSwitchError.liveConfigurationUnavailable
        }
        return try CodexTOMLModel.read(from: text, location: "Codex 实时配置")
    }

    private func restoreLive(_ original: String, expectedCurrent: String) throws {
        guard let data = fileReader(liveConfigPath),
              let current = String(data: data, encoding: .utf8),
              current == expectedCurrent else {
            throw CodexModelSwitchError.concurrentProviderChange
        }
        try atomicWrite(original, to: liveConfigPath)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    private func databaseError(_ database: OpaquePointer) -> CodexModelSwitchError {
        CodexModelSwitchError.database(String(cString: sqlite3_errmsg(database)))
    }
}

private final class AnkerCatalogRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
