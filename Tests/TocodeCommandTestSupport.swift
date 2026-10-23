import AppKit
import Foundation

final class MockTocodeWheel: TocodeWheelCommanding, @unchecked Sendable {
    var vertical: Bool = false
    var horizontal: Bool = false
    var setCalls: [(String, Bool)] = []

    var isVerticalEffective: Bool { vertical }
    var isHorizontalEffective: Bool { horizontal }

    func setVerticalEnabled(_ enabled: Bool) -> Bool {
        setCalls.append(("vertical", enabled))
        vertical = enabled
        return true
    }

    func setHorizontalEnabled(_ enabled: Bool) -> Bool {
        setCalls.append(("horizontal", enabled))
        horizontal = enabled
        return true
    }
}

final class MockTocodeShortcuts: TocodeShortcutCommanding, @unchecked Sendable {
    var finderMove = false
    var doubleCmdQ = false
    var finderCmdQ = false
    var setCalls: [(String, Bool)] = []

    var isFinderMoveEffective: Bool { finderMove }
    var isDoubleCommandQEffective: Bool { doubleCmdQ }
    var isFinderCommandQEffective: Bool { finderCmdQ }

    func setFinderMoveEnabled(_ enabled: Bool) -> Bool {
        setCalls.append(("finder-move", enabled)); finderMove = enabled; return true
    }
    func setDoubleCommandQEnabled(_ enabled: Bool) -> Bool {
        setCalls.append(("double-cmdq", enabled)); doubleCmdQ = enabled; return true
    }
    func setFinderCommandQEnabled(_ enabled: Bool) -> Bool {
        setCalls.append(("finder-cmdq", enabled)); finderCmdQ = enabled; return true
    }
}

final class MockTocodeVisibility: TocodeVisibilityCommanding, @unchecked Sendable {
    var showAll = false
    var lastSet: Bool?
    var setResult = true

    func currentShowAllFiles() -> Bool { showAll }
    func setShowAllFiles(_ show: Bool) -> Bool {
        lastSet = show
        if setResult { showAll = show }
        return setResult
    }
}

final class MockTocodeRootChooser: TocodeRootChoosing {
    var result: String?

    func chooseRoot() -> String? { result }
}

final class MockTocodeLaunchAtLogin: LaunchAtLoginControlling {
    var enabled = false
    var setResult: Result<Void, LaunchAtLoginError> = .success(())

    var isEnabled: Bool { enabled }

    func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError> {
        if case .success = setResult {
            self.enabled = enabled
        }
        return setResult
    }
}

final class MockTocodeWeChat: WeChatAssociationControlling {
    var bound = false
    var bindCalls = 0
    var locationCalls = 0

    var isBound: Bool { bound }
    var sendPayloads: [TocodeWechatSendPayload] = []
    var sendResult: TocodeCommandResult = .success(TocodeCommandOutput("已发送"))

    func startBinding() { bindCalls += 1 }
    func startBoundListener() {}
    func openArchiveLocation() { locationCalls += 1 }
    func stop() {}
    func sendOutbound(_ payload: TocodeWechatSendPayload) async -> TocodeCommandResult {
        sendPayloads.append(payload)
        return sendResult
    }
}

final class MockTocodeScreenBlackout: ScreenBlackoutOverlaying {
    var presented = false
    var activateCount = 0

    var isPresented: Bool { presented }
    func show() { presented = true; activateCount += 1 }
    func dismiss() { presented = false }
}

final class MockTocodeFinderSelection: TocodeFinderSelectionCommanding {
    var result: Result<String, FinderSelectionError> = .success("/tmp/selected")
    var selectedItemResult: Result<String, FinderSelectionError> = .success("/tmp/selected-item")

    func resolveInitializationDirectory() -> Result<String, FinderSelectionError> {
        result
    }

    func resolveSelectedItemPath() -> Result<String, FinderSelectionError> {
        selectedItemResult
    }
}

final class MockTocodeClipboard: TocodeClipboardCommanding {
    var text: String?
    var copiedPaths: [String] = []

    func read() -> String? { text }
    func copyPath(_ path: String) {
        copiedPaths.append(path)
        text = ClipboardService.formatPath(path)
    }
}

final class MockBookmarkSync: BookmarkSyncCommanding {
    var ledger = BookmarkLedgerSnapshot.empty
    var remoteEnabled = false
    var remoteKey = false
    var connected: [String] = []
    var pullResult: Result<BookmarkLedgerSnapshot, Error>?
    let activityLog = BookmarkSyncActivityLog(capacity: 50, fileURL: nil)

    var isRemoteEnabled: Bool { remoteEnabled }
    var hasRemoteKey: Bool { remoteKey }
    var connectedBrowserKeys: [String] { connected }
    var snapshot: BookmarkLedgerSnapshot { ledger }

    func entry(url: String) -> BookmarkEntry? {
        guard let canonical = BookmarkURL.canonicalize(url) else { return nil }
        return ledger.entries.first { $0.url == canonical }
    }

    func addCLI(url: String, title: String?, folder: BookmarkFolderPath?, siblingIndex: Int?) throws -> BookmarkCLIAddResult {
        guard let canonical = BookmarkURL.canonicalize(url) else {
            throw TocodeCommandError.invalidArguments("bookmark add --url")
        }
        let existed = ledger.entries.contains { $0.url == canonical }
        let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : canonical
        let resolvedFolder = folder ?? BookmarkFolderPath(kind: .other, segments: [])
        let now = Date().timeIntervalSince1970
        ledger = BookmarkLedgerMerge.unionMerge(
            ledger: ledger,
            incoming: [
                BookmarkEntry(
                    url: canonical,
                    title: resolvedTitle,
                    folder: resolvedFolder,
                    siblingIndex: siblingIndex ?? 0,
                    updatedAt: now
                )
            ],
            browserKey: "cli"
        )
        ledger = BookmarkLedgerMerge.upsertFolderAncestors(
            resolvedFolder,
            siblingIndex: nil,
            updatedAt: now,
            in: ledger
        )
        guard let saved = entry(url: canonical) else {
            throw TocodeCommandError.operationFailed("mock add failed")
        }
        return BookmarkCLIAddResult(entry: saved, created: !existed)
    }

    func updateCLI(
        url: String,
        title: String?,
        folder: BookmarkFolderPath?,
        siblingIndex: Int?,
        newURL: String?
    ) throws -> BookmarkEntry {
        guard entry(url: url) != nil else {
            throw TocodeCommandError.operationFailed("找不到该书签：\(url)")
        }
        if let newURL {
            ledger = BookmarkLedgerMerge.changeURL(
                from: url,
                to: newURL,
                title: title,
                folder: folder,
                siblingIndex: siblingIndex,
                updatedAt: Date().timeIntervalSince1970,
                in: ledger
            )
            guard let saved = entry(url: newURL) else {
                throw TocodeCommandError.operationFailed("mock update failed")
            }
            return saved
        }
        ledger = BookmarkLedgerMerge.updateEntry(
            urlRaw: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            updatedAt: Date().timeIntervalSince1970,
            in: ledger
        )
        guard let saved = entry(url: url) else {
            throw TocodeCommandError.operationFailed("mock update failed")
        }
        return saved
    }

    func deleteCLI(url: String) throws {
        guard entry(url: url) != nil else {
            throw TocodeCommandError.operationFailed("找不到该书签：\(url)")
        }
        ledger = BookmarkLedgerMerge.deleteURL(url, in: ledger)
    }

    func pullRemoteForCLI() async -> Result<BookmarkLedgerSnapshot, Error> {
        if let pullResult { return pullResult }
        if !remoteKey {
            return .failure(TocodeCommandError.operationFailed("未设置远程同步密钥。请先在「工具 → 书签同步 → 远程同步」保存密钥。"))
        }
        return .success(ledger)
    }

    var backupPack = BookmarkBackupPack.empty

    func backupStatusPayload() -> [String: Any] {
        let sorted = backupPack.slots.sorted { $0.day < $1.day }
        return [
            "slotCount": sorted.count,
            "maxSlots": BookmarkBackupPack.maxSlots,
            "days": sorted.map(\.day)
        ]
    }

    func backupListPayload() -> [[String: Any]] {
        backupPack.slots.sorted { $0.day < $1.day }.map { slot in
            [
                "day": slot.day,
                "takenAt": slot.takenAt,
                "entries": slot.ledger.entries.count,
                "tombstones": slot.ledger.tombstones.count,
                "folders": slot.ledger.folders.count
            ]
        }
    }

    func backupNowForCLI() async -> Result<BookmarkBackupPack, Error> {
        let today = BookmarkBackupPackLogic.dayString()
        backupPack = BookmarkBackupPackLogic.upsert(
            pack: backupPack,
            day: today,
            ledger: ledger,
            takenAt: Date().timeIntervalSince1970,
            today: today
        )
        return .success(backupPack)
    }

    func restoreBackupForCLI(day: String?) async -> Result<BookmarkLedgerSnapshot, Error> {
        guard let slot = BookmarkBackupPackLogic.slot(in: backupPack, day: day) else {
            return .failure(TocodeCommandError.operationFailed("找不到备份槽：\(day ?? "最近一日")"))
        }
        var restored = slot.ledger
        restored.remoteRevision = ledger.remoteRevision
        ledger = restored
        return .success(ledger)
    }

    func foldersTreePayload() -> [[String: Any]] {
        BookmarkCLIFolderTree.build(from: ledger)
    }

    func createFolderCLI(path: BookmarkFolderPath, siblingIndex: Int?) throws -> BookmarkFolderRecord {
        if BookmarkLedgerMerge.isRootFolderPath(path) {
            throw TocodeCommandError.invalidArguments("不可对书签根执行 folder create")
        }
        let now = Date().timeIntervalSince1970
        ledger = BookmarkLedgerMerge.upsertFolderAncestors(
            path,
            siblingIndex: siblingIndex,
            updatedAt: now,
            in: ledger
        )
        guard let saved = ledger.folders.first(where: { $0.pathKey == path.sortKey }) else {
            throw TocodeCommandError.operationFailed("建夹后无法读取")
        }
        return saved
    }

    func deleteFolderCLI(path: BookmarkFolderPath, recursive: Bool) throws -> BookmarkLedgerSnapshot {
        ledger = try BookmarkLedgerMerge.deleteFolder(path, recursive: recursive, in: ledger)
        return ledger
    }

    func pruneEmptyFoldersCLI(under: BookmarkFolderPath?) throws -> [BookmarkFolderPath] {
        let result = try BookmarkLedgerMerge.pruneEmptyFolders(under: under, in: ledger)
        ledger = result.ledger
        return result.removed
    }

    func moveFolderCLI(
        path: BookmarkFolderPath,
        to: BookmarkFolderPath?,
        siblingIndex: Int?
    ) throws -> BookmarkLedgerSnapshot {
        ledger = try BookmarkLedgerMerge.moveFolder(
            from: path,
            to: to,
            siblingIndex: siblingIndex,
            in: ledger
        )
        return ledger
    }

    func applyPlanCLI(ops: [[String: Any]], dryRun: Bool) throws -> [[String: Any]] {
        // 与正式服务同语义：复用路径解析；测试侧直接调用真实合并逻辑字段。
        var results: [[String: Any]] = []
        let before = ledger
        for (i, op) in ops.enumerated() {
            let action = ((op["op"] as? String) ?? "").lowercased()
            do {
                let folder: BookmarkFolderPath?
                if let folderRaw = op["folder"] as? String {
                    switch BookmarkCLIFolder.parse(folderRaw) {
                    case .success(let path): folder = path
                    case .failure(let err): throw err
                    }
                } else {
                    folder = nil
                }
                switch action {
                case "add":
                    let url = op["url"] as? String ?? ""
                    let existedBefore: Bool = {
                        guard let canonical = BookmarkURL.canonicalize(url) else { return false }
                        return ledger.entries.contains { $0.url == canonical }
                    }()
                    if dryRun {
                        results.append([
                            "index": i,
                            "op": "add",
                            "url": url,
                            "ok": true,
                            "dryRun": true,
                            "created": !existedBefore,
                            "merged": existedBefore
                        ])
                    } else {
                        let added = try addCLI(
                            url: url,
                            title: op["title"] as? String,
                            folder: folder,
                            siblingIndex: op["index"] as? Int
                        )
                        results.append([
                            "index": i,
                            "op": "add",
                            "url": added.entry.url,
                            "ok": true,
                            "created": added.created,
                            "merged": !added.created
                        ])
                    }
                case "update":
                    let url = op["url"] as? String ?? ""
                    if dryRun {
                        results.append(["index": i, "op": "update", "url": url, "ok": true, "dryRun": true])
                    } else {
                        let entry = try updateCLI(
                            url: url,
                            title: op["title"] as? String,
                            folder: folder,
                            siblingIndex: op["index"] as? Int,
                            newURL: op["newUrl"] as? String
                        )
                        results.append(["index": i, "op": "update", "url": entry.url, "ok": true])
                    }
                case "delete":
                    let url = op["url"] as? String ?? ""
                    if dryRun {
                        results.append(["index": i, "op": "delete", "url": url, "ok": true, "dryRun": true])
                    } else {
                        try deleteCLI(url: url)
                        results.append(["index": i, "op": "delete", "url": url, "ok": true])
                    }
                default:
                    throw TocodeCommandError.invalidArguments("未知 op")
                }
            } catch {
                results.append([
                    "index": i,
                    "op": action,
                    "ok": false,
                    "error": error.localizedDescription
                ])
                break
            }
        }
        if dryRun { ledger = before }
        return results
    }
}

final class MockBookmarkKeyStore: BookmarkSyncKeyStoring {
    var value: String?
    func loadPlaintext() throws -> String? { value }
    func savePlaintext(_ secret: String) throws { value = secret }
    func deletePlaintext() throws { value = nil }
}

final class MemoryTocodeTransport: TocodeIPCTransport {
    var requests: [TocodeIPCRequest] = []
    var response: TocodeIPCResponse
    var error: TocodeIPCError?

    init(response: TocodeIPCResponse) {
        self.response = response
    }

    func send(_ request: TocodeIPCRequest) -> Result<TocodeIPCResponse, TocodeIPCError> {
        requests.append(request)
        if let error { return .failure(error) }
        return .success(response)
    }
}
