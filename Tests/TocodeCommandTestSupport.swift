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
    func startBinding() { bindCalls += 1 }
    func startBoundListener() {}
    func openArchiveLocation() { locationCalls += 1 }
    func stop() {}
}

final class MockTocodeCodexModels: CodexModelSwitching {
    var state: Result<CodexModelState, Error> = .success(
        CodexModelState(liveModelID: "v_model/gpt-5.5", providerModelID: "v_model/gpt-5.5", providerID: "anker", providerName: "Anker")
    )
    var fetchResult: Result<[CodexModelDescriptor], Error> = .success([
        CodexModelDescriptor(id: "v_model/gpt-5.5", displayName: "GPT-5.6 Sol", source: .general, compatibility: .verified)
    ])
    var switchError: Error?
    var switchedIDs: [String] = []

    func currentState() throws -> CodexModelState { try state.get() }
    func fetchModels(completion: @escaping (Result<[CodexModelDescriptor], Error>) -> Void) {
        completion(fetchResult)
    }
    func switchModel(to modelID: String) throws {
        if let switchError { throw switchError }
        switchedIDs.append(modelID)
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

    func resolveInitializationDirectory() -> Result<String, FinderSelectionError> {
        result
    }
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
