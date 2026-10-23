import Foundation

@MainActor
final class BookmarkSyncService {
    private let ledgerStore: BookmarkLedgerStore
    private let keyStore: BookmarkSyncKeyStoring
    private var settings: BookmarkSyncSettingsStore
    private let roomClient: BookmarkRemoteRoomClient
    private let backupService: BookmarkBackupService
    private var ledger: BookmarkLedgerSnapshot
    private var pushWork: Task<Void, Never>?
    /// 远程 sync 单飞：合并前重读最新 ledger，串行化 create/prune 与 syncRemoteNow。
    private var remoteSyncWork: Task<Void, Never>?
    private var remoteSyncQueued = false
    private var connectedBrowsers: Set<String> = []
    /// 由 NativeBridge 注入：以活连接现扫为准，避免 Set 与真实 bridge 漂移。
    var liveConnectedBrowserKeysProvider: (() -> [String])?
    let activityLog: BookmarkSyncActivityLog

    /// 整本账变化时通知（远程合并、初次全量对账）。
    var onLedgerChanged: (() -> Void)?
    /// 单条写入后通知各浏览器增量补齐。
    var onEntryUpserted: ((BookmarkEntry) -> Void)?
    /// 单条删除（含改址时的旧网址）后通知各浏览器移除。
    var onURLRemoved: ((String) -> Void)?

    init(
        ledgerStore: BookmarkLedgerStore = .live,
        backupStore: BookmarkBackupStore = .live,
        keyStore: BookmarkSyncKeyStoring = KeychainBookmarkSyncKeyStore(),
        settings: BookmarkSyncSettingsStore = BookmarkSyncSettingsStore(),
        relayBaseURL: URL = URL(string: "https://totti.xin")!,
        session: URLSession = .shared,
        activityLog: BookmarkSyncActivityLog = BookmarkSyncActivityLog()
    ) {
        self.ledgerStore = ledgerStore
        self.keyStore = keyStore
        self.settings = settings
        self.activityLog = activityLog
        let roomClient = BookmarkRemoteRoomClient(relayBaseURL: relayBaseURL, session: session)
        self.roomClient = roomClient
        self.backupService = BookmarkBackupService(
            backupStore: backupStore,
            settings: settings,
            roomClient: roomClient,
            activityLog: activityLog
        )
        self.ledger = ledgerStore.load()
        self.backupService.bindCurrentLedger { [weak self] in
            self?.ledger ?? .empty
        }
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
        if let liveConnectedBrowserKeysProvider {
            return liveConnectedBrowserKeysProvider()
        }
        return connectedBrowsers.sorted()
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
        ledger = BookmarkLedgerMerge.upsertFolderAncestors(
            folder,
            siblingIndex: nil,
            updatedAt: updatedAt,
            in: ledger
        )
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
        if remoteSyncWork != nil {
            remoteSyncQueued = true
            await remoteSyncWork?.value
            return
        }
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.remoteSyncQueued = false
                await self.performRemoteSync()
            } while self.remoteSyncQueued
        }
        remoteSyncWork = work
        await work.value
        remoteSyncWork = nil
    }

    @MainActor
    private func performRemoteSync() async {
        guard settings.isRemoteEnabled else { return }
        guard let secret = await loadSecretOffMain(), !secret.isEmpty else { return }
        activityLog.append("开始远程同步…")
        do {
            let roomID = BookmarkSyncCrypto.roomID(for: secret)
            let verifier = BookmarkSyncCrypto.verifier(for: secret)
            // 合并前以当前内存账本为准（单飞期间本地写入已串行可见）。
            if let remote = try await roomClient.fetch(roomID: roomID, verifier: verifier) {
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
                folderTombstones: ledger.folderTombstones,
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
            if let remote = try await roomClient.fetch(roomID: roomID, verifier: verifier) {
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

    // MARK: - 七日备份（转调 BackupService；还原写正式账本）

    func scheduleDailyBackupMonitoring() {
        backupService.scheduleDailyBackupMonitoring { [weak self] in
            await self?.loadSecretOffMain()
        }
    }

    func backupStatusPayload() -> [String: Any] {
        backupService.statusPayload(remoteEnabled: isRemoteEnabled, hasRemoteKey: hasRemoteKey)
    }

    func backupListPayload() -> [[String: Any]] {
        backupService.listPayload()
    }

    func foldersTreePayload() -> [[String: Any]] {
        BookmarkCLIFolderTree.build(from: ledger)
    }

    func folderTombstonesForBrowser() -> [BookmarkFolderTombstone] {
        ledger.folderTombstones
    }

    @discardableResult
    func createFolderCLI(path: BookmarkFolderPath, siblingIndex: Int?) throws -> BookmarkFolderRecord {
        if BookmarkLedgerMerge.isRootFolderPath(path) {
            throw TocodeCommandError.invalidArguments("不可对书签根执行 folder create（请带路径段）")
        }
        let now = Date().timeIntervalSince1970
        ledger = BookmarkLedgerMerge.upsertFolderAncestors(
            path,
            siblingIndex: siblingIndex,
            updatedAt: now,
            in: ledger
        )
        try persist()
        activityLog.append("CLI 建夹：\(path.sortKey)")
        scheduleRemotePush()
        guard let saved = ledger.folders.first(where: { $0.pathKey == path.sortKey }) else {
            throw TocodeCommandError.operationFailed("建夹后无法读取")
        }
        return saved
    }

    @discardableResult
    func deleteFolderCLI(path: BookmarkFolderPath, recursive: Bool) throws -> BookmarkLedgerSnapshot {
        let now = Date().timeIntervalSince1970
        ledger = try BookmarkLedgerMerge.deleteFolder(path, recursive: recursive, now: now, in: ledger)
        try persist()
        activityLog.append("CLI 删夹：\(path.sortKey)\(recursive ? "（递归）" : "")")
        scheduleRemotePush()
        return ledger
    }

    func pruneEmptyFoldersCLI(under: BookmarkFolderPath?) throws -> [BookmarkFolderPath] {
        let now = Date().timeIntervalSince1970
        let result = try BookmarkLedgerMerge.pruneEmptyFolders(under: under, now: now, in: ledger)
        ledger = result.ledger
        try persist()
        activityLog.append("CLI 剪枝空夹：\(result.removed.count) 个")
        scheduleRemotePush()
        return result.removed
    }

    @discardableResult
    func moveFolderCLI(
        path: BookmarkFolderPath,
        to: BookmarkFolderPath?,
        siblingIndex: Int?
    ) throws -> BookmarkLedgerSnapshot {
        let now = Date().timeIntervalSince1970
        ledger = try BookmarkLedgerMerge.moveFolder(
            from: path,
            to: to,
            siblingIndex: siblingIndex,
            now: now,
            in: ledger
        )
        try persist()
        activityLog.append(
            "CLI 移夹：\(path.sortKey)"
                + (to.map { " → \($0.sortKey)" } ?? "")
                + (siblingIndex.map { " index=\($0)" } ?? "")
        )
        scheduleRemotePush()
        return ledger
    }

    func applyPlanCLI(ops: [[String: Any]], dryRun: Bool) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        let snapshotBefore = ledger
        for (i, op) in ops.enumerated() {
            let action = ((op["op"] as? String) ?? (op["action"] as? String) ?? "").lowercased()
            do {
                switch action {
                case "add":
                    guard let url = op["url"] as? String else {
                        throw TocodeCommandError.invalidArguments("apply[\(i)] add 缺 url")
                    }
                    let title = op["title"] as? String
                    let folder = try parseOptionalFolder(op["folder"], label: "apply[\(i)]")
                    let index = op["index"] as? Int ?? op["siblingIndex"] as? Int
                    if dryRun {
                        results.append([
                            "index": i, "op": "add", "url": url, "ok": true, "dryRun": true
                        ])
                    } else {
                        let entry = try addCLI(url: url, title: title, folder: folder, siblingIndex: index)
                        results.append([
                            "index": i, "op": "add", "url": entry.url, "ok": true, "id": entry.id
                        ])
                    }
                case "update":
                    guard let url = op["url"] as? String else {
                        throw TocodeCommandError.invalidArguments("apply[\(i)] update 缺 url")
                    }
                    let title = op["title"] as? String
                    let folder = try parseOptionalFolder(op["folder"], label: "apply[\(i)]")
                    let index = op["index"] as? Int ?? op["siblingIndex"] as? Int
                    let newURL = op["newUrl"] as? String ?? op["new_url"] as? String
                    if dryRun {
                        results.append([
                            "index": i, "op": "update", "url": url, "ok": true, "dryRun": true
                        ])
                    } else {
                        let entry = try updateCLI(
                            url: url,
                            title: title,
                            folder: folder,
                            siblingIndex: index,
                            newURL: newURL
                        )
                        results.append([
                            "index": i, "op": "update", "url": entry.url, "ok": true, "id": entry.id
                        ])
                    }
                case "delete":
                    guard let url = op["url"] as? String else {
                        throw TocodeCommandError.invalidArguments("apply[\(i)] delete 缺 url")
                    }
                    if dryRun {
                        results.append([
                            "index": i, "op": "delete", "url": url, "ok": true, "dryRun": true
                        ])
                    } else {
                        try deleteCLI(url: url)
                        results.append(["index": i, "op": "delete", "url": url, "ok": true])
                    }
                default:
                    throw TocodeCommandError.invalidArguments(
                        "apply[\(i)] 未知 op：\(action)（仅 add|update|delete）"
                    )
                }
            } catch {
                results.append([
                    "index": i,
                    "op": action,
                    "ok": false,
                    "error": error.localizedDescription
                ])
                if dryRun {
                    ledger = snapshotBefore
                }
                // 写模式下保留已成功条，便于续跑
                break
            }
        }
        if dryRun {
            ledger = snapshotBefore
        }
        return results
    }

    private func parseOptionalFolder(_ raw: Any?, label: String) throws -> BookmarkFolderPath? {
        guard let raw else { return nil }
        if let text = raw as? String {
            switch BookmarkCLIFolder.parse(text) {
            case .success(let path):
                return path
            case .failure(let err):
                throw err
            }
        }
        if let dict = raw as? [String: Any],
           let kindRaw = dict["kind"] as? String,
           let kind = BookmarkFolderKind(rawValue: kindRaw) {
            let segments = (dict["segments"] as? [String]) ?? []
            return BookmarkFolderPath(kind: kind, segments: segments)
        }
        throw TocodeCommandError.invalidArguments("\(label) folder 格式无效")
    }

    func backupNowForCLI() async -> Result<BookmarkBackupPack, Error> {
        do {
            let pack = try await backupService.runDailyBackup(force: true) { [weak self] in
                await self?.loadSecretOffMain()
            }
            return .success(pack)
        } catch {
            return .failure(error)
        }
    }

    func restoreBackupForCLI(day: String?) async -> Result<BookmarkLedgerSnapshot, Error> {
        do {
            let loadSecret: () async -> String? = { [weak self] in
                await self?.loadSecretOffMain()
            }
            let slot = try await backupService.resolveSlot(day: day, loadSecret: loadSecret)
            var formalRevision = ledger.remoteRevision
            if settings.isRemoteEnabled, let secret = await loadSecret() {
                formalRevision = try await backupService.fetchFormalRevision(
                    secret: secret,
                    fallback: formalRevision
                )
            }
            var restored = slot.ledger
            restored.remoteRevision = formalRevision
            ledger = restored
            try persist()
            activityLog.append(
                "已从 \(slot.day) 还原：账本 \(ledger.entries.count) 条，墓碑 \(ledger.tombstones.count) 条。"
            )
            if settings.isRemoteEnabled, let secret = await loadSecret() {
                try await pushRoomReplacingRemote(secret: secret)
                activityLog.append("还原后正式房间已强制推送，修订 \(ledger.remoteRevision)。")
            }
            return .success(ledger)
        } catch {
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

    private func loadSecretOffMain() async -> String? {
        let store = keyStore
        do {
            return try await Task.detached(priority: .utility) {
                try store.loadPlaintext()
            }.value
        } catch {
            activityLog.append("远程密钥暂时不可用：\(error.localizedDescription)")
            return nil
        }
    }

    private func pushRoom(secret: String) async throws {
        let roomID = BookmarkSyncCrypto.roomID(for: secret)
        let verifier = BookmarkSyncCrypto.verifier(for: secret)
        let ciphertext = try BookmarkSyncCrypto.encrypt(snapshot: ledger, secret: secret)
        switch try await roomClient.put(
            roomID: roomID,
            verifier: verifier,
            ciphertext: ciphertext,
            expectedRevision: ledger.remoteRevision
        ) {
        case .saved(let revision):
            ledger.remoteRevision = revision
            try persist()
        case .conflict(let remote):
            activityLog.append("远程推送冲突（409），拉回合并后重试。")
            let remoteLedger = try BookmarkSyncCrypto.decrypt(ciphertextBase64: remote.ciphertext, secret: secret)
            var merged = BookmarkLedgerMerge.mergeRemote(local: ledger, remote: remoteLedger)
            merged.remoteRevision = remote.revision
            ledger = merged
            try persist()
            switch try await roomClient.put(
                roomID: roomID,
                verifier: verifier,
                ciphertext: try BookmarkSyncCrypto.encrypt(snapshot: ledger, secret: secret),
                expectedRevision: remote.revision
            ) {
            case .saved(let revision):
                ledger.remoteRevision = revision
                try persist()
            case .conflict:
                throw BookmarkSyncRemoteError.conflict
            }
        }
    }

    /// 还原后强制推正式房间：409 时只取修订号，不把远端正式账本合并回来。
    private func pushRoomReplacingRemote(secret: String) async throws {
        let roomID = BookmarkSyncCrypto.roomID(for: secret)
        let verifier = BookmarkSyncCrypto.verifier(for: secret)
        var expected = ledger.remoteRevision
        for attempt in 0..<3 {
            switch try await roomClient.put(
                roomID: roomID,
                verifier: verifier,
                ciphertext: try BookmarkSyncCrypto.encrypt(snapshot: ledger, secret: secret),
                expectedRevision: expected
            ) {
            case .saved(let revision):
                ledger.remoteRevision = revision
                try persist(notifyBrowsers: false)
                return
            case .conflict(let remote):
                activityLog.append("还原推送冲突（409），取远端修订后强制覆盖（第 \(attempt + 1) 次）。")
                expected = remote.revision
                ledger.remoteRevision = remote.revision
            }
        }
        throw BookmarkSyncRemoteError.conflict
    }
}
