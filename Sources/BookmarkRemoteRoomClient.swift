import Foundation

struct BookmarkRemoteRoomGetResponse: Codable {
    var room_id: String
    var ciphertext: String
    var revision: Int
}

struct BookmarkRemoteRoomPutBody: Codable {
    var room_id: String
    var verifier: String
    var ciphertext: String
    var revision: Int
    var expected_revision: Int?
}

enum BookmarkRemoteRoomPutOutcome {
    case saved(revision: Int)
    case conflict(remote: BookmarkRemoteRoomGetResponse)
}

/// 书签密文房间 HTTP 客户端：只处理不透明密文，不感知 ledger/pack。
final class BookmarkRemoteRoomClient {
    private let relayBaseURL: URL
    private let session: URLSession

    init(
        relayBaseURL: URL = URL(string: "https://totti.xin")!,
        session: URLSession = .shared
    ) {
        self.relayBaseURL = relayBaseURL
        self.session = session
    }

    func fetch(roomID: String, verifier: String) async throws -> BookmarkRemoteRoomGetResponse? {
        var request = URLRequest(url: relayBaseURL.appendingPathComponent("v1/bookmark-rooms/\(roomID)"))
        request.httpMethod = "GET"
        request.setValue(verifier, forHTTPHeaderField: "X-Tocode-Bookmark-Verifier")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BookmarkSyncRemoteError.badResponse
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw BookmarkSyncRemoteError.http(http.statusCode)
        }
        return try JSONDecoder().decode(BookmarkRemoteRoomGetResponse.self, from: data)
    }

    func put(
        roomID: String,
        verifier: String,
        ciphertext: String,
        expectedRevision: Int
    ) async throws -> BookmarkRemoteRoomPutOutcome {
        let body = BookmarkRemoteRoomPutBody(
            room_id: roomID,
            verifier: verifier,
            ciphertext: ciphertext,
            revision: expectedRevision + 1,
            expected_revision: expectedRevision
        )
        var request = URLRequest(url: relayBaseURL.appendingPathComponent("v1/bookmark-rooms/\(roomID)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BookmarkSyncRemoteError.badResponse
        }
        if http.statusCode == 409 {
            guard let remote = try await fetch(roomID: roomID, verifier: verifier) else {
                throw BookmarkSyncRemoteError.conflict
            }
            return .conflict(remote: remote)
        }
        guard http.statusCode == 200 else {
            throw BookmarkSyncRemoteError.http(http.statusCode)
        }
        if let saved = try? JSONDecoder().decode(BookmarkRemoteRoomGetResponse.self, from: data) {
            return .saved(revision: saved.revision)
        }
        return .saved(revision: expectedRevision + 1)
    }
}

enum BookmarkSyncRemoteError: Error, LocalizedError {
    case badResponse
    case http(Int)
    case conflict

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "远程书签同步响应无效。"
        case .http(let code):
            return "远程书签同步失败（HTTP \(code)）。"
        case .conflict:
            return "远程书签修订冲突，请稍后重试。"
        }
    }
}
