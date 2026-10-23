import AppKit
import Foundation

struct PhoneHermesHTTPError: Error {
    let status: Int
    let body: Data
}

/// Hermes 不允许两个会话同名；手机默认都叫「新会话」。
enum PhoneHermesSessionTitle {
    static let attempts = 20

    static func candidate(_ base: String, attempt: Int) -> String {
        attempt <= 1 ? base : "\(base) \(attempt)"
    }

    static func isTaken(_ error: PhoneHermesHTTPError) -> Bool {
        guard error.status == 400,
              let json = try? JSONSerialization.jsonObject(with: error.body) as? [String: Any],
              let detail = json["error"] as? [String: Any] else { return false }
        return detail["code"] as? String == "invalid_title"
            && (detail["message"] as? String)?.contains("already in use") == true
    }

    static func isBusy(_ error: PhoneHermesHTTPError) -> Bool {
        guard error.status == 409,
              let json = try? JSONSerialization.jsonObject(with: error.body) as? [String: Any],
              let detail = json["error"] as? [String: Any] else { return false }
        return detail["code"] as? String == "session_active_turn"
    }
}

/// 只连本机 Hermes 接口。密钥留在这台 Mac，不交给手机或中转。
final class PhoneHermesLiveRuntime: PhoneHermesRuntime {
    private let envURL: URL
    private let session: URLSession
    private let isInstalled: () -> Bool

    init(
        envURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env"),
        session: URLSession = .shared,
        isInstalled: @escaping () -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nousresearch.hermes") != nil
        }
    ) {
        self.envURL = envURL
        self.session = session
        self.isInstalled = isInstalled
    }

    func snapshot() async -> PhoneHermesSnapshot {
        let installed = isInstalled()
        guard installed else { return PhoneHermesSnapshot(installed: false, running: false) }
        let env = readEnv()
        let healthy = await health(port: PhoneHermesEnvironment.port(from: env))
        return PhoneHermesSnapshot(installed: true, running: healthy)
    }

    func listSessions() async throws -> [PhoneHermesSession] {
        try await listSessions(profile: "default")
    }

    func listSessions(profile: String) async throws -> [PhoneHermesSession] {
        let json = try await request(method: "GET", path: "/api/sessions?source=api_server&limit=50", body: nil, timeout: 15, profile: profile)
        let rows = json["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhoneHermesSession(id: id, title: title?.isEmpty == false ? title! : "未命名会话")
        }
    }

    func createSession(title: String) async throws -> PhoneHermesSession {
        try await createSession(title: title, profile: "default")
    }

    func createSession(title: String, profile: String) async throws -> PhoneHermesSession {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let json = try await request(
                method: "POST",
                path: "/api/sessions",
                body: ["source": "api_server"],
                timeout: 15,
                profile: profile
            )
            return try storedSession(from: json, fallbackTitle: "")
        }
        var attempt = 1
        var json: [String: Any] = [:]
        while true {
            let candidate = PhoneHermesSessionTitle.candidate(trimmed, attempt: attempt)
            do {
                json = try await request(
                    method: "POST",
                    path: "/api/sessions",
                    body: ["title": candidate, "source": "api_server"],
                    timeout: 15,
                    profile: profile
                )
                break
            } catch let error as PhoneHermesHTTPError
                where PhoneHermesSessionTitle.isTaken(error) && attempt < PhoneHermesSessionTitle.attempts {
                attempt += 1
            }
        }
        return try storedSession(from: json, fallbackTitle: trimmed)
    }

    func session(sessionID: String, profile: String) async throws -> PhoneHermesSession {
        let json = try await request(
            method: "GET",
            path: "/api/sessions/\(sessionID)",
            body: nil,
            timeout: 15,
            profile: profile
        )
        return try storedSession(from: json, fallbackTitle: "")
    }

    func deleteSession(sessionID: String, profile: String) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/api/sessions/\(sessionID)",
            body: nil,
            timeout: 20,
            profile: profile
        )
    }

    func renameSession(sessionID: String, title: String, profile: String) async throws -> String {
        let json = try await request(
            method: "PATCH",
            path: "/api/sessions/\(sessionID)",
            body: ["title": title],
            timeout: 15,
            profile: profile
        )
        return try storedSession(from: json, fallbackTitle: title).title
    }

    private func storedSession(from json: [String: Any], fallbackTitle: String) throws -> PhoneHermesSession {
        let row = json["session"] as? [String: Any] ?? [:]
        guard let id = row["id"] as? String, !id.isEmpty else { throw URLError(.badServerResponse) }
        let saved = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PhoneHermesSession(id: id, title: saved.isEmpty ? fallbackTitle : saved)
    }

    func messages(sessionID: String) async throws -> [PhoneHermesTurn] {
        try await messages(sessionID: sessionID, profile: "default")
    }

    func messages(sessionID: String, profile: String) async throws -> [PhoneHermesTurn] {
        let page = try await messagePage(sessionID: sessionID, profile: profile, offset: 0, limit: 200)
        return page.rows.compactMap { row in
            guard row.role == "user" || row.role == "assistant" else { return nil }
            return PhoneHermesTurn(role: row.role, text: row.text, interim: row.interim, id: row.id)
        }
    }

    func messagePage(sessionID: String, profile: String, offset: Int, limit: Int) async throws -> PhoneHermesMessagePage {
        let json = try await request(
            method: "GET",
            path: "/api/sessions/\(sessionID)/messages?inline_images=false&limit=\(limit)&offset=\(offset)&order=latest",
            body: nil,
            timeout: 20,
            profile: profile
        )
        let rows = json["data"] as? [[String: Any]] ?? []
        let parsed: [PhoneHermesRow] = rows.compactMap { row in
            let id = (row["id"] as? NSNumber)?.intValue ?? 0
            guard id > 0 else { return nil }
            return PhoneHermesRow(
                id: id,
                role: row["role"] as? String ?? "",
                text: Self.plainText(row["content"]),
                interim: (row["finish_reason"] as? String) == "tool_calls"
            )
        }
        return PhoneHermesMessagePage(rows: parsed, reachedStart: rows.count < limit)
    }

    func chat(sessionID: String, text: String, directory: String) async throws -> String {
        try await chat(sessionID: sessionID, text: text, directory: directory, profile: "default")
    }

    func chat(sessionID: String, text: String, directory: String, profile: String) async throws -> String {
        let json = try await request(
            method: "POST",
            path: "/api/sessions/\(sessionID)/chat",
            body: [
                "input": text,
                "instructions": PhoneHermesApp.instructions(for: directory)
            ],
            timeout: 600,
            profile: profile
        )
        let message = json["message"] as? [String: Any]
        let content = Self.plainText(message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? "没有回复" : content
    }

    func modelOptions(profile: String) async throws -> PhoneHermesModelOptions {
        let json = try await request(
            method: "GET",
            path: "/api/model/options?include_unconfigured=false",
            body: nil,
            timeout: 20,
            profile: profile
        )
        return PhoneHermesModelOptions.parse(json)
    }

    private func health(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["status"] as? String == "ok"
    }

    private func request(method: String, path: String, body: [String: Any]?, timeout: TimeInterval, profile: String) async throws -> [String: Any] {
        let name = profile.isEmpty ? "default" : profile
        guard HermesProfileCatalog.isSafe(name) else { throw URLError(.badURL) }
        let profileEnv = envFile(profile: name)
        let profileHome = profileEnv.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profileHome, isDirectory: &isDir), isDir.boolValue else {
            throw URLError(.badURL)
        }
        try HermesGatewayEnv.ensure(at: profileEnv)
        let key = PhoneHermesEnvironment.apiKey(from: read(profileEnv))
        guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let port = PhoneHermesEnvironment.port(from: read(envURL))
        let prefix = HermesProfileCatalog.prefix(for: name)
        guard let url = URL(string: "http://127.0.0.1:\(port)\(prefix)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw PhoneHermesHTTPError(status: http.statusCode, body: data)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func readEnv() -> String {
        read(envURL)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func envFile(profile: String) -> URL {
        guard profile != "default" else { return envURL }
        return envURL.deletingLastPathComponent()
            .appendingPathComponent("profiles/\(profile)/.env")
    }

    private static func plainText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = content as? [Any] ?? []
        return parts.compactMap { item -> String? in
            if let text = item as? String { return text }
            guard let part = item as? [String: Any] else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }
}
