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
    let activityLog: BookmarkSyncActivityLog

    /// 整本账变化时通知（远程合并、初次全量对账）。
    var onLedgerChanged: (() -> Void)?
    /// 单条写入后通知各浏览器增量补齐。
    var onEntryUpserted: ((BookmarkEntry) -> Void)?
    /// 单条删除（含改址时的旧网址）后通知各浏览器移除。
    var onURLRemoved: ((String) -> Void)?

    init(
        ledgerStore: BookmarkLedgerStore = .live,
        keyStore: BookmarkSyncKeyStoring = KeychainBookmarkSyncKeyStore(),
        settings: BookmarkSyncSettingsStore = BookmarkSyncSettingsStore(),
        relayBaseURL: URL = URL(string: "https://totti.xin")!,
        session: URLSession = .shared,
        activityLog: BookmarkSyncActivityLog = BookmarkSyncActivityLog()
    ) {
        self.ledgerStore = ledgerStore
        self.keyStore = keyStore
        self.settings = settings
        self.relayBaseURL = relayBaseURL
        self.session = session
        self.activityLog = activityLog
        self.ledger = ledgerStore.load()
        activityLog.append("书签同步服务已启动，账本 \(ledger.entries.count) 条，墓碑 \(ledger.tombstones.count) 条。")
    }

    var snapshot: BookmarkLedgerSnapshot { ledger }

    var isRemoteEnabled: Bool { settings.isRemoteEnabled }

    /// 缓存远程密钥是否存在；禁止在 MainActor 同步读钥匙串（登录钥匙串锁定时会卡死 IPC）。
    private var remoteKeyCached: Bool?

    var hasRemoteKey: Bool {
        if let remoteKeyCached { return remoteKeyCached }
        return false
    }

    func refreshRemoteKeyCache() {
        let store = keyStore
        Task.detached(priority: .utility) { [weak self] in
            let present = (try? store.loadPlaintext())?.isEmpty == false
            await MainActor.run { self?.remoteKeyCached = present }
        }
    }

    var connectedBrowserKeys: [String] {
        connectedBrowsers.sorted()
    }

    func markBrowserConnected(_ key: String) {
        let isNew = connectedBrowsers.insert(key).inserted
        if isNew {
            activityLog.append("扩展上线：\(key)")
        }
    }

    func markBrowserDisconnected(_ key: String) {
        if connectedBrowsers.remove(key) != nil {
            activityLog.append("扩展离线：\(key)")
        }
    }

    func ingestBrowserTree(browserKey: String, nodes: [[String: Any]]) throws {
        let before = ledger.entries.count
        let alreadyJoined = ledger.joinedBrowserKeys.contains(browserKey)
        let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
        ledger = BookmarkLedgerMerge.unionMerge(
            ledger: ledger,
            incoming: layout.entries,
            incomingFolders: layout.folders,
            browserKey: browserKey
        )
        // 不在对账时广播：等扩展回 tree_ready 后再做布局对账。
        try persist(notifyBrowsers: false)
        let after = ledger.entries.count
        let phase = alreadyJoined ? "全量对账" : "初次并集"
        let deltaNote = after == before
            ? "无净增网址（对端独有网址已在账本或与现有网址重复）"
            : "净增 \(after - before) 条"
        activityLog.append(
            "\(phase)：\(browserKey) 推送 \(layout.entries.count) 条 → 账本 \(before)→\(after) 条（\(deltaNote)）。"
        )
        scheduleRemotePush()
    }

    func applyBrowserCreate(
        browserKey: String,
        url: String,
        title: String,
        folder: BookmarkFolderPath,
        siblingIndex: Int = 0,
        updatedAt: Double
    ) throws {
        let entry = BookmarkEntry(
            url: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            updatedAt: updatedAt
        )
        ledger = BookmarkLedgerMerge.unionMerge(ledger: ledger, incoming: [entry], browserKey: browserKey)
        try persist(notifyBrowsers: false)
        activityLog.append("新增：\(Self.shortURL(url))（\(browserKey)，\(title)）")
        if let saved = self.entry(url: url) {
            onEntryUpserted?(saved)
        }
        scheduleRemotePush()
    }

    func applyBrowserUpdate(
        url: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int? = nil,
        updatedAt: Double
    ) throws {
        ledger = BookmarkLedgerMerge.updateEntry(
            urlRaw: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            updatedAt: updatedAt,
            in: ledger
        )
        try persist(notifyBrowsers: false)
        var parts: [String] = [Self.shortURL(url)]
        if let title { parts.append("标题=\(title)") }
        if let folder { parts.append("文件夹=\(folder.kind.rawValue)") }
        if let siblingIndex { parts.append("序=\(siblingIndex)") }
        activityLog.append("更新：\(parts.joined(separator: "，"))")
        if let saved = entry(url: url) {
            onEntryUpserted?(saved)
        }
        scheduleRemotePush()
    }

    func applyBrowserChangeURL(
        from oldURL: String,
        to newURL: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int? = nil,
        updatedAt: Double
    ) throws {
        let oldCanonical = BookmarkURL.canonicalize(oldURL) ?? oldURL
        ledger = BookmarkLedgerMerge.changeURL(
            from: oldURL,
            to: newURL,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            updatedAt: updatedAt,
            in: ledger
        )
        try persist(notifyBrowsers: false)
        activityLog.append("改址：\(Self.shortURL(oldURL)) → \(Self.shortURL(newURL))")
        onURLRemoved?(oldCanonical)
        if let saved = entry(url: newURL) {
            onEntryUpserted?(saved)
        }
        scheduleRemotePush()
    }

    func applyBrowserDelete(url: String) throws {
        let canonical = BookmarkURL.canonicalize(url) ?? url
        ledger = BookmarkLedgerMerge.deleteURL(url, in: ledger)
        try persist(notifyBrowsers: false)
        activityLog.append("删除：\(Self.shortURL(url))（留墓碑）")
        onURLRemoved?(canonical)
        scheduleRemotePush()
    }

    func saveRemoteKey(_ secret: String, enable: Bool = true) throws {
        try keyStore.savePlaintext(secret)
        remoteKeyCached = true
        settings.isRemoteEnabled = enable
        activityLog.append(enable ? "已保存远程密钥并开启远程同步。" : "已保存远程密钥（远程同步未开启）。")
        if enable {
            Task { await syncRemoteNow() }
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        settings.isRemoteEnabled = enabled
        activityLog.append(enabled ? "已开启远程同步。" : "已关闭远程同步（密钥仍保留）。")
        if enabled {
            Task { await syncRemoteNow() }
        }
    }

    func loadRemoteKeyPlaintext() throws -> String? {
        try keyStore.loadPlaintext()
    }

    func deleteRemoteKey() throws {
        try keyStore.deletePlaintext()
        remoteKeyCached = false
        settings.isRemoteEnabled = false
        activityLog.append("已删除本机远程密钥并停止远程同步。")
    }

    func syncRemoteNow() async {
        guard settings.isRemoteEnabled else { return }
        // 钥匙串解密可能在登录钥匙串锁定时无限阻塞；必须离开 MainActor，否则 IPC/扩展桥全部卡死。
        let store = keyStore
        let secret: String?
        do {
            secret = try await Task.detached(priority: .utility) {
                try store.loadPlaintext()
            }.value
        } catch {
            activityLog.append("远程密钥暂时不可用：\(error.localizedDescription)")
            return
        }
        guard let secret, !secret.isEmpty else { return }
        activityLog.append("开始远程同步…")
        do {
            let roomID = BookmarkSyncCrypto.roomID(for: secret)
            let verifier = BookmarkSyncCrypto.verifier(for: secret)
            if let remote = try await fetchRoom(roomID: roomID, verifier: verifier) {
                let remoteLedger = try BookmarkSyncCrypto.decrypt(ciphertextBase64: remote.ciphertext, secret: secret)
                let before = ledger.entries.count
                var merged = BookmarkLedgerMerge.mergeRemote(local: ledger, remote: remoteLedger)
                merged.remoteRevision = remote.revision
                ledger = merged
                try persist()
                activityLog.append(
                    "远程拉取合并：账本 \(before)→\(ledger.entries.count) 条，修订 \(remote.revision)。"
                )
            } else {
                activityLog.append("远程房间尚不存在，准备首次推送。")
            }
            try await pushRoom(secret: secret)
            activityLog.append("远程推送完成，修订 \(ledger.remoteRevision)。")
        } catch {
            activityLog.append("远程同步失败：\(error.localizedDescription)")
            NSLog("Bookmark remote sync failed: %@", error.localizedDescription)
        }
    }

    /// 扩展需要的当前账本条目（不含墓碑）。
    func entriesForBrowser() -> [BookmarkEntry] {
        ledger.entries
    }

    func entry(url: String) -> BookmarkEntry? {
        guard let canonical = BookmarkURL.canonicalize(url) else { return nil }
        return ledger.entries.first { $0.url == canonical }
    }

    func foldersForBrowser() -> [BookmarkFolderRecord] {
        ledger.folders
    }

    func addCLI(
        url: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int? = nil
    ) throws -> BookmarkEntry {
        guard let canonical = BookmarkURL.canonicalize(url) else {
            throw TocodeCommandError.invalidArguments("bookmark add --url")
        }
        if ledger.tombstones.contains(where: { $0.url == canonical }) {
            ledger = BookmarkLedgerSnapshot(
                version: ledger.version,
                entries: ledger.entries,
                folders: ledger.folders,
                tombstones: ledger.tombstones.filter { $0.url != canonical },
                remoteRevision: ledger.remoteRevision,
                joinedBrowserKeys: ledger.joinedBrowserKeys
            )
        }
        let now = Date().timeIntervalSince1970
        let resolvedFolder = folder ?? BookmarkFolderPath(kind: .other, segments: [])
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : canonical
        try applyBrowserCreate(
            browserKey: "cli",
            url: canonical,
            title: resolvedTitle,
            folder: resolvedFolder,
            siblingIndex: siblingIndex ?? 0,
            updatedAt: now
        )
        guard let saved = entry(url: canonical) else {
            throw TocodeCommandError.operationFailed("书签写入后无法读取")
        }
        return saved
    }

    func updateCLI(
        url: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int? = nil,
        newURL: String?
    ) throws -> BookmarkEntry {
        guard entry(url: url) != nil else {
            throw TocodeCommandError.operationFailed("找不到该书签：\(url)")
        }
        let now = Date().timeIntervalSince1970
        if let newURL, !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try applyBrowserChangeURL(
                from: url,
                to: newURL,
                title: title,
                folder: folder,
                siblingIndex: siblingIndex,
                updatedAt: now
            )
            guard let saved = entry(url: newURL) else {
                throw TocodeCommandError.operationFailed("书签改址后无法读取")
            }
            return saved
        }
        try applyBrowserUpdate(
            url: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            updatedAt: now
        )
        guard let saved = entry(url: url) else {
            throw TocodeCommandError.operationFailed("书签更新后无法读取")
        }
        return saved
    }

    func deleteCLI(url: String) throws {
        guard entry(url: url) != nil else {
            throw TocodeCommandError.operationFailed("找不到该书签：\(url)")
        }
        try applyBrowserDelete(url: url)
    }

    /// CLI pull：有密钥即可拉；远程开启时再推回。
    func pullRemoteForCLI() async -> Result<BookmarkLedgerSnapshot, Error> {
        do {
            guard let secret = try keyStore.loadPlaintext(), !secret.isEmpty else {
                return .failure(TocodeCommandError.operationFailed(
                    "未设置远程同步密钥。请先在「工具 → 书签同步 → 远程同步」保存密钥。"
                ))
            }
            activityLog.append("CLI pull：开始拉取远程账本…")
            let roomID = BookmarkSyncCrypto.roomID(for: secret)
            let verifier = BookmarkSyncCrypto.verifier(for: secret)
            if let remote = try await fetchRoom(roomID: roomID, verifier: verifier) {
                let remoteLedger = try BookmarkSyncCrypto.decrypt(ciphertextBase64: remote.ciphertext, secret: secret)
                let before = ledger.entries.count
                var merged = BookmarkLedgerMerge.mergeRemote(local: ledger, remote: remoteLedger)
                merged.remoteRevision = remote.revision
                ledger = merged
                try persist()
                activityLog.append(
                    "CLI pull：合并完成 \(before)→\(ledger.entries.count) 条，修订 \(remote.revision)。"
                )
            } else {
                activityLog.append("CLI pull：远程房间不存在。")
            }
            if settings.isRemoteEnabled {
                try await pushRoom(secret: secret)
                activityLog.append("CLI pull：已按开启状态回推，修订 \(ledger.remoteRevision)。")
            }
            return .success(ledger)
        } catch {
            activityLog.append("CLI pull 失败：\(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func persist(notifyBrowsers: Bool = true) throws {
        try ledgerStore.save(ledger)
        if notifyBrowsers {
            onLedgerChanged?()
        }
    }

    private static func shortURL(_ url: String) -> String {
        if url.count <= 96 { return url }
        return String(url.prefix(93)) + "…"
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
            activityLog.append("远程推送冲突（409），拉回合并后重试。")
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
