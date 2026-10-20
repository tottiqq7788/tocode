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
        let json = try await request(method: "GET", path: "/api/sessions?source=api_server&limit=50", body: nil, timeout: 15)
        let rows = json["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhoneHermesSession(id: id, title: title?.isEmpty == false ? title! : "未命名会话")
        }
    }

    func createSession(title: String) async throws -> PhoneHermesSession {
        var attempt = 1
        var json: [String: Any] = [:]
        while true {
            let candidate = PhoneHermesSessionTitle.candidate(title, attempt: attempt)
            do {
                json = try await request(
                    method: "POST",
                    path: "/api/sessions",
                    body: ["title": candidate, "source": "api_server"],
                    timeout: 15
                )
                break
            } catch let error as PhoneHermesHTTPError
                where PhoneHermesSessionTitle.isTaken(error) && attempt < PhoneHermesSessionTitle.attempts {
                attempt += 1
            }
        }
        let row = json["session"] as? [String: Any] ?? [:]
        guard let id = row["id"] as? String, !id.isEmpty else { throw URLError(.badServerResponse) }
        let saved = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PhoneHermesSession(id: id, title: saved?.isEmpty == false ? saved! : title)
    }

    func messages(sessionID: String) async throws -> [PhoneHermesTurn] {
        let json = try await request(
            method: "GET",
            path: "/api/sessions/\(sessionID)/messages?inline_images=false&limit=80&order=oldest",
            body: nil,
            timeout: 20
        )
        let rows = json["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let role = row["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { return nil }
            return PhoneHermesTurn(role: role, text: Self.plainText(row["content"]))
        }
    }

    func chat(sessionID: String, text: String, directory: String) async throws -> String {
        let json = try await request(
            method: "POST",
            path: "/api/sessions/\(sessionID)/chat",
            body: [
                "input": text,
                "instructions": PhoneHermesApp.instructions(for: directory)
            ],
            timeout: 180
        )
        let message = json["message"] as? [String: Any]
        let content = Self.plainText(message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? "没有回复" : content
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

    private func request(method: String, path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let env = readEnv()
        let key = PhoneHermesEnvironment.apiKey(from: env)
        guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let port = PhoneHermesEnvironment.port(from: env)
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
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
        (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
    }

    private static func plainText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return ""
    }
}
