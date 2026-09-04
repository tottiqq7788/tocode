import AppKit

enum FinderDismissError: Error, Equatable {
    case notPermitted
    case scriptFailed
    case hideFailed
}

protocol FinderWindowDismissing {
    func dismissWindowsAndHide() -> Result<Void, FinderDismissError>
}

protocol FinderHiding {
    func hideFinder() -> Bool
}

/// 先关闭全部 Finder 窗口，成功后再隐藏 Finder；失败不得隐藏。
struct FinderDismissService: FinderWindowDismissing {
    let script: AppleScriptRunning
    let hider: FinderHiding

    init(
        script: AppleScriptRunning = NSAppleScriptRunner(),
        hider: FinderHiding = WorkspaceFinderHider()
    ) {
        self.script = script
        self.hider = hider
    }

    static let closeWindowsScript = """
        tell application "Finder"
            close every window
        end tell
        """

    func dismissWindowsAndHide() -> Result<Void, FinderDismissError> {
        switch script.execute(Self.closeWindowsScript) {
        case .failure(.notPermitted):
            return .failure(.notPermitted)
        case .failure:
            return .failure(.scriptFailed)
        case .success:
            break
        }
        guard hider.hideFinder() else {
            return .failure(.hideFailed)
        }
        return .success(())
    }
}

struct WorkspaceFinderHider: FinderHiding {
    func hideFinder() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.finder"
        }
        if apps.isEmpty { return true }
        return apps.allSatisfy { $0.hide() }
    }
}
