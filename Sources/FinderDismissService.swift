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

/// 先关闭全部 Finder 窗口，成功后再隐藏 Finder。
/// 隐藏为尽力而为：关窗成功是主结果，隐藏请求已向全部运行中的 Finder 提交即视为成功。
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
            // hide() 请求提交失败或找不到 Finder 时兜底上报（防御性分支）。
            return .failure(.hideFailed)
        }
        return .success(())
    }
}

struct WorkspaceFinderHider: FinderHiding {
    /// Finder 隐藏：尽力而为。
    ///
    /// 若未运行 Finder 则无需隐藏，视为成功；否则向每个 Finder 进程发出 hide()
    /// 请求并立即返回成功。注意：close every window 收尾期间系统会返回 false，
    /// 但 Finder 仍会随后隐藏成功（真机探针：hide() 返回 false、数百 ms 后
    /// isHidden == true），因此 hide() 的瞬时返回值不作为失败判据。
    func hideFinder() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.finder"
        }
        guard !apps.isEmpty else { return true }
        for app in apps {
            _ = app.hide()
        }
        return true
    }
}
