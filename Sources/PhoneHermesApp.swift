import Foundation

struct PhoneHermesSnapshot: Equatable {
    var installed: Bool
    var running: Bool
}

struct PhoneHermesSession: Equatable {
    var id: String
    var title: String
}

struct PhoneHermesTurn: Equatable {
    var role: String
    var text: String
}

protocol PhoneHermesRuntime: AnyObject {
    func snapshot() async -> PhoneHermesSnapshot
    func listSessions() async throws -> [PhoneHermesSession]
    func createSession(title: String) async throws -> PhoneHermesSession
    func messages(sessionID: String) async throws -> [PhoneHermesTurn]
    func chat(sessionID: String, text: String, directory: String) async throws -> String
}

struct PhoneHermesAppReply {
    var ok: Bool
    var text: String
    var body: [String: Any]

    static func failure(_ text: String) -> PhoneHermesAppReply {
        PhoneHermesAppReply(ok: false, text: text, body: [:])
    }

    static func success(_ text: String, body: [String: Any] = [:]) -> PhoneHermesAppReply {
        PhoneHermesAppReply(ok: true, text: text, body: body)
    }
}

enum PhoneHermesEnvironment {
    static func apiKey(from envText: String) -> String {
        value(named: "API_SERVER_KEY", in: envText)
    }

    static func port(from envText: String) -> Int {
        let raw = value(named: "API_SERVER_PORT", in: envText)
        return Int(raw) ?? 8642
    }

    static func value(named name: String, in envText: String) -> String {
        for line in envText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let prefix = name + "="
            guard trimmed.hasPrefix(prefix) else { continue }
            var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }
}

enum PhoneHermesDirectory {
    static let maxEntries = 300
    static let maxDepth = 4

    static func list(root: String, fileManager: FileManager = .default) -> PhoneHermesAppReply {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .failure("还没配置项目目录")
        }
        let rootReal = canonical(root)
        var entries: [[String: String]] = []
        var truncated = false
        func visit(_ path: String, depth: Int) {
            guard depth <= maxDepth, !truncated else {
                truncated = true
                return
            }
            let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if entries.count >= maxEntries {
                    truncated = true
                    return
                }
                let child = (path as NSString).appendingPathComponent(name)
                let real = canonical(child)
                guard real == rootReal || real.hasPrefix(rootReal + "/") else { continue }
                var childIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: real, isDirectory: &childIsDir) else { continue }
                let relative = String(real.dropFirst(rootReal.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                let kind = childIsDir.boolValue ? "directory" : "file"
                entries.append(["path": relative, "name": name, "kind": kind])
                if childIsDir.boolValue {
                    visit(real, depth: depth + 1)
                }
            }
        }
        visit(rootReal, depth: 1)
        return .success(truncated ? "只显示了前 \(maxEntries) 项" : "", body: ["entries": entries])
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

enum PhoneHermesApp {
    static let missingHermes = "这台电脑没有 Hermes"
    static let hermesClosed = "这台电脑的 Hermes 没开"
    static let missingPath = "还没配置项目目录"

    static func instructions(for directory: String) -> String {
        "工作目录是 \(directory)。请在这个目录里完成请求。"
    }

    static func handle(
        kind: String,
        sessionID: String,
        title: String,
        text: String,
        directory: String?,
        runtime: PhoneHermesRuntime
    ) async -> PhoneHermesAppReply {
        let snapshot = await runtime.snapshot()
        switch kind {
        case "status":
            return .success("", body: [
                "hermes_installed": snapshot.installed,
                "hermes_running": snapshot.running,
                "path_configured": directory != nil
            ])
        case "tree":
            guard let directory else { return .failure(missingPath) }
            return PhoneHermesDirectory.list(root: directory)
        case "sessions", "session_create", "messages", "chat":
            guard snapshot.installed else { return .failure(missingHermes) }
            guard snapshot.running else { return .failure(hermesClosed) }
            return await sessionCall(kind: kind, sessionID: sessionID, title: title, text: text, directory: directory, runtime: runtime)
        default:
            return .failure("无法处理")
        }
    }

    private static func sessionCall(
        kind: String,
        sessionID: String,
        title: String,
        text: String,
        directory: String?,
        runtime: PhoneHermesRuntime
    ) async -> PhoneHermesAppReply {
        do {
            switch kind {
            case "sessions":
                let sessions = try await runtime.listSessions()
                return .success("", body: ["sessions": sessions.map { ["id": $0.id, "title": $0.title] }])
            case "session_create":
                let created = try await runtime.createSession(title: title.isEmpty ? "新会话" : title)
                return .success("", body: ["session": ["id": created.id, "title": created.title]])
            case "messages":
                guard validSession(sessionID) else { return .failure("会话不存在") }
                let turns = try await runtime.messages(sessionID: sessionID)
                return .success("", body: ["messages": turns.map { ["role": $0.role, "text": $0.text] }])
            case "chat":
                guard let directory else { return .failure(missingPath) }
                guard validSession(sessionID) else { return .failure("会话不存在") }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .failure("请输入内容") }
                let answer = try await runtime.chat(sessionID: sessionID, text: trimmed, directory: directory)
                return .success(answer)
            default:
                return .failure("无法处理")
            }
        } catch {
            return .failure("这台电脑的 Hermes 还不能接收手机消息")
        }
    }

    private static func validSession(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID.count <= 256 && sessionID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}
