import Foundation

/// 七日备份包：本机落盘、远程备份房间推拉、日备定时；不拥有正式账本。
@MainActor
final class BookmarkBackupService {
    private let backupStore: BookmarkBackupStore
    private var settings: BookmarkSyncSettingsStore
    private let roomClient: BookmarkRemoteRoomClient
    private let activityLog: BookmarkSyncActivityLog
    private var backupWork: Task<Void, Never>?
    private var dailyBackupTimer: Timer?
    private var currentLedger: () -> BookmarkLedgerSnapshot = { .empty }

    init(
        backupStore: BookmarkBackupStore = .live,
        settings: BookmarkSyncSettingsStore = BookmarkSyncSettingsStore(),
        roomClient: BookmarkRemoteRoomClient,
        activityLog: BookmarkSyncActivityLog
    ) {
        self.backupStore = backupStore
        self.settings = settings
        self.roomClient = roomClient
        self.activityLog = activityLog
    }

    deinit {
        dailyBackupTimer?.invalidate()
    }

    func bindCurrentLedger(_ provider: @escaping () -> BookmarkLedgerSnapshot) {
        currentLedger = provider
    }

    func scheduleDailyBackupMonitoring(loadSecret: @escaping () async -> String?) {
        ensureDailyBackupIfNeeded(loadSecret: loadSecret)
        dailyBackupTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureDailyBackupIfNeeded(loadSecret: loadSecret)
            }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        dailyBackupTimer = timer
    }

    func ensureDailyBackupIfNeeded(loadSecret: @escaping () async -> String?) {
        let today = BookmarkBackupPackLogic.dayString()
        if settings.lastBackupDay == today {
            return
        }
        backupWork?.cancel()
        backupWork = Task { [weak self] in
            _ = try? await self?.runDailyBackup(force: false, loadSecret: loadSecret)
        }
    }

    func statusPayload(remoteEnabled: Bool, hasRemoteKey: Bool) -> [String: Any] {
        let pack = backupStore.load()
        let sorted = pack.slots.sorted { $0.day < $1.day }
        var payload: [String: Any] = [
            "slotCount": sorted.count,
            "maxSlots": BookmarkBackupPack.maxSlots,
            "days": sorted.map(\.day),
            "today": BookmarkBackupPackLogic.dayString(),
            "remoteEnabled": remoteEnabled,
            "hasRemoteKey": hasRemoteKey,
            "packRemoteRevision": pack.remoteRevision
        ]
        if let last = settings.lastBackupDay {
            payload["lastBackupDay"] = last
        }
        return payload
    }

    func listPayload() -> [[String: Any]] {
        backupStore.load().slots.sorted { $0.day < $1.day }.map { slot in
            [
                "day": slot.day,
                "takenAt": slot.takenAt,
                "entries": slot.ledger.entries.count,
                "tombstones": slot.ledger.tombstones.count,
                "folders": slot.ledger.folders.count
            ]
        }
    }

    @discardableResult
    func runDailyBackup(force: Bool, loadSecret: () async -> String?) async throws -> BookmarkBackupPack {
        let today = BookmarkBackupPackLogic.dayString()
        if !force, settings.lastBackupDay == today {
            return backupStore.load()
        }
        let ledger = currentLedger()
        activityLog.append(force ? "开始立即日备…" : "开始每日日备…")
        do {
            var pack = backupStore.load()
            pack = BookmarkBackupPackLogic.upsert(
                pack: pack,
                day: today,
                ledger: ledger,
                takenAt: Date().timeIntervalSince1970,
                today: today
            )
            if settings.isRemoteEnabled, let secret = await loadSecret() {
                pack = try await syncBackupPackRemote(local: pack, secret: secret, today: today)
            }
            try backupStore.save(pack)
            settings.lastBackupDay = today
            activityLog.append(
                "日备完成：\(today)，槽位 \(pack.slots.count)/\(BookmarkBackupPack.maxSlots)，账本 \(ledger.entries.count) 条。"
            )
            return pack
        } catch {
            activityLog.append("日备失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// 解析日备槽（本机缺失且远程开启时拉备份房间）；不写正式账本。
    func resolveSlot(
        day: String?,
        loadSecret: () async -> String?
    ) async throws -> BookmarkBackupSlot {
        var pack = backupStore.load()
        var slot = BookmarkBackupPackLogic.slot(in: pack, day: day)
        if slot == nil, settings.isRemoteEnabled, let secret = await loadSecret() {
            activityLog.append("本机无该日备槽，尝试拉取备份房间…")
            pack = try await syncBackupPackRemote(
                local: pack,
                secret: secret,
                today: BookmarkBackupPackLogic.dayString()
            )
            try backupStore.save(pack)
            slot = BookmarkBackupPackLogic.slot(in: pack, day: day)
        }
        guard let slot else {
            let label = day ?? "最近一日"
            throw TocodeCommandError.operationFailed("找不到备份槽：\(label)")
        }
        return slot
    }

    func fetchFormalRevision(secret: String, fallback: Int) async throws -> Int {
        let roomID = BookmarkSyncCrypto.roomID(for: secret)
        let verifier = BookmarkSyncCrypto.verifier(for: secret)
        if let remote = try await roomClient.fetch(roomID: roomID, verifier: verifier) {
            return remote.revision
        }
        return fallback
    }

    private func syncBackupPackRemote(
        local: BookmarkBackupPack,
        secret: String,
        today: String
    ) async throws -> BookmarkBackupPack {
        let roomID = BookmarkSyncCrypto.backupRoomID(for: secret)
        let verifier = BookmarkSyncCrypto.backupVerifier(for: secret)
        var pack = local
        if let remote = try await roomClient.fetch(roomID: roomID, verifier: verifier) {
            let remotePack = try BookmarkSyncCrypto.decryptPack(ciphertextBase64: remote.ciphertext, secret: secret)
            pack = BookmarkBackupPackLogic.mergePreferringLocal(local: pack, remote: remotePack, today: today)
            pack.remoteRevision = remote.revision
        }

        switch try await roomClient.put(
            roomID: roomID,
            verifier: verifier,
            ciphertext: try BookmarkSyncCrypto.encryptPack(pack, secret: secret),
            expectedRevision: pack.remoteRevision
        ) {
        case .saved(let revision):
            pack.remoteRevision = revision
            return pack
        case .conflict(let remote):
            activityLog.append("备份房间推送冲突（409），拉回合并后重试。")
            let remotePack = try BookmarkSyncCrypto.decryptPack(ciphertextBase64: remote.ciphertext, secret: secret)
            pack = BookmarkBackupPackLogic.mergePreferringLocal(local: pack, remote: remotePack, today: today)
            pack.remoteRevision = remote.revision
            switch try await roomClient.put(
                roomID: roomID,
                verifier: verifier,
                ciphertext: try BookmarkSyncCrypto.encryptPack(pack, secret: secret),
                expectedRevision: remote.revision
            ) {
            case .saved(let revision):
                pack.remoteRevision = revision
                return pack
            case .conflict:
                throw BookmarkSyncRemoteError.conflict
            }
        }
    }
}
