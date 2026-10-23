import Foundation

@MainActor
final class BookmarkSyncService {
    private let ledgerStore: BookmarkLedgerStore
    private let keyStore: BookmarkSyncKeyStoring
    private var settings: BookmarkSyncSettingsStore
    private let relayBaseURL: URL
    private let session: URLSession
    private var ledger: BookmarkLedgerSnapshot
    private var pushWork: Task<Void, Never>?
    private var connectedBrowsers: Set<String> = []

    var onLedgerChanged: (() -> Void)?

    init(
        ledgerStore: BookmarkLedgerStore = .live,
        keyStore: BookmarkSyncKeyStoring = KeychainBookmarkSyncKeyStore(),
        settings: BookmarkSyncSettingsStore = BookmarkSyncSettingsStore(),
        relayBaseURL: URL = URL(string: "https://totti.xin")!,
        session: URLSession = .shared
    ) {
        self.ledgerStore = ledgerStore
        self.keyStore = keyStore
        self.settings = settings
        self.relayBaseURL = relayBaseURL
        self.session = session
        self.ledger = ledgerStore.load()
    }

    var snapshot: BookmarkLedgerSnapshot { ledger }

    var isRemoteEnabled: Bool { settings.isRemoteEnabled }

    var hasRemoteKey: Bool {
        (try? keyStore.loadPlaintext())?.isEmpty == false
    }

    var connectedBrowserKeys: [String] {
        connectedBrowsers.sorted()
    }

    func markBrowserConnected(_ key: String) {
        connectedBrowsers.insert(key)
    }

    func markBrowserDisconnected(_ key: String) {
        connectedBrowsers.remove(key)
    }

    func ingestBrowserTree(browserKey: String, nodes: [[String: Any]]) throws {
        let entries = BookmarkLedgerMerge.entries(fromBrowserNodes: nodes)
        ledger = BookmarkLedgerMerge.unionMerge(ledger: ledger, incoming: entries, browserKey: browserKey)
        try persist()
        scheduleRemotePush()
    }

    func applyBrowserCreate(browserKey: String, url: String, title: String, folder: BookmarkFolderPath, updatedAt: Double) throws {
        let entry = BookmarkEntry(url: url, title: title, folder: folder, updatedAt: updatedAt)
        ledger = BookmarkLedgerMerge.unionMerge(ledger: ledger, incoming: [entry], browserKey: browserKey)
        try persist()
        scheduleRemotePush()
    }

    func applyBrowserUpdate(url: String, title: String?, folder: BookmarkFolderPath?, updatedAt: Double) throws {
        ledger = BookmarkLedgerMerge.updateEntry(
            urlRaw: url,
            title: title,
            folder: folder,
            updatedAt: updatedAt,
            in: ledger
        )
        try persist()
        scheduleRemotePush()
    }

    func applyBrowserChangeURL(from oldURL: String, to newURL: String, title: String?, folder: BookmarkFolderPath?, updatedAt: Double) throws {
        ledger = BookmarkLedgerMerge.changeURL(
            from: oldURL,
            to: newURL,
            title: title,
            folder: folder,
            updatedAt: updatedAt,
            in: ledger
        )
        try persist()
        scheduleRemotePush()
    }

    func applyBrowserDelete(url: String) throws {
        ledger = BookmarkLedgerMerge.deleteURL(url, in: ledger)
        try persist()
        scheduleRemotePush()
    }

    func saveRemoteKey(_ secret: String, enable: Bool = true) throws {
        try keyStore.savePlaintext(secret)
        settings.isRemoteEnabled = enable
        if enable {
            Task { await syncRemoteNow() }
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        settings.isRemoteEnabled = enabled
        if enabled {
            Task { await syncRemoteNow() }
        }
    }

    func loadRemoteKeyPlaintext() throws -> String? {
        try keyStore.loadPlaintext()
    }

    func deleteRemoteKey() throws {
        try keyStore.deletePlaintext()
        settings.isRemoteEnabled = false
    }

    func syncRemoteNow() async {
        guard settings.isRemoteEnabled,
              let secret = try? keyStore.loadPlaintext(),
              !secret.isEmpty else {
            return
        }
        do {
            let roomID = BookmarkSyncCrypto.roomID(for: secret)
            let verifier = BookmarkSyncCrypto.verifier(for: secret)
            if let remote = try await fetchRoom(roomID: roomID, verifier: verifier) {
                let remoteLedger = try BookmarkSyncCrypto.decrypt(ciphertextBase64: remote.ciphertext, secret: secret)
                var merged = BookmarkLedgerMerge.mergeRemote(local: ledger, remote: remoteLedger)
                merged.remoteRevision = remote.revision
                ledger = merged
                try persist()
            }
            try await pushRoom(secret: secret)
        } catch {
            NSLog("Bookmark remote sync failed: %@", error.localizedDescription)
        }
    }

    /// 扩展需要的当前账本条目（不含墓碑）。
    func entriesForBrowser() -> [BookmarkEntry] {
        ledger.entries
    }

    private func persist() throws {
        try ledgerStore.save(ledger)
        onLedgerChanged?()
    }

    private func scheduleRemotePush() {
        guard settings.isRemoteEnabled else { return }
        pushWork?.cancel()
        pushWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncRemoteNow()
        }
    }

    private struct RoomPayload: Codable {
        var room_id: String
        var verifier: String
        var ciphertext: String
        var revision: Int
        var expected_revision: Int?
    }

    private struct RoomGetResponse: Codable {
        var room_id: String
        var ciphertext: String
        var revision: Int
    }

    private func fetchRoom(roomID: String, verifier: String) async throws -> RoomGetResponse? {
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
        return try JSONDecoder().decode(RoomGetResponse.self, from: data)
    }

    private func pushRoom(secret: String) async throws {
        let roomID = BookmarkSyncCrypto.roomID(for: secret)
        let verifier = BookmarkSyncCrypto.verifier(for: secret)
        let ciphertext = try BookmarkSyncCrypto.encrypt(snapshot: ledger, secret: secret)
        let expected = ledger.remoteRevision
        var body = RoomPayload(
            room_id: roomID,
            verifier: verifier,
            ciphertext: ciphertext,
            revision: expected + 1,
            expected_revision: expected
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
            // 旧修订：拉回合并后再推。
            if let remote = try await fetchRoom(roomID: roomID, verifier: verifier) {
                let remoteLedger = try BookmarkSyncCrypto.decrypt(ciphertextBase64: remote.ciphertext, secret: secret)
                var merged = BookmarkLedgerMerge.mergeRemote(local: ledger, remote: remoteLedger)
                merged.remoteRevision = remote.revision
                ledger = merged
                try persist()
                body = RoomPayload(
                    room_id: roomID,
                    verifier: verifier,
                    ciphertext: try BookmarkSyncCrypto.encrypt(snapshot: ledger, secret: secret),
                    revision: remote.revision + 1,
                    expected_revision: remote.revision
                )
                request.httpBody = try JSONEncoder().encode(body)
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode == 200 else {
                    throw BookmarkSyncRemoteError.conflict
                }
                if let saved = try? JSONDecoder().decode(RoomGetResponse.self, from: retryData) {
                    ledger.remoteRevision = saved.revision
                    try persist()
                }
            }
            return
        }
        guard http.statusCode == 200 else {
            throw BookmarkSyncRemoteError.http(http.statusCode)
        }
        if let saved = try? JSONDecoder().decode(RoomGetResponse.self, from: data) {
            ledger.remoteRevision = saved.revision
            try persist()
        } else {
            ledger.remoteRevision = expected + 1
            try persist()
        }
        _ = data
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
