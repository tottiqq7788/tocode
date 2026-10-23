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

    func addCLI(url: String, title: String?, folder: BookmarkFolderPath?, siblingIndex: Int?) throws -> BookmarkEntry {
        guard let canonical = BookmarkURL.canonicalize(url) else {
            throw TocodeCommandError.invalidArguments("bookmark add --url")
        }
        let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : canonical
        ledger = BookmarkLedgerMerge.unionMerge(
            ledger: ledger,
            incoming: [
                BookmarkEntry(
                    url: canonical,
                    title: resolvedTitle,
                    folder: folder ?? BookmarkFolderPath(kind: .other, segments: []),
                    siblingIndex: siblingIndex ?? 0,
                    updatedAt: Date().timeIntervalSince1970
                )
            ],
            browserKey: "cli"
        )
        guard let saved = entry(url: canonical) else {
            throw TocodeCommandError.operationFailed("mock add failed")
        }
        return saved
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
