import Foundation

/// 读写 com.apple.dock 的自动隐藏与悬停延迟。
protocol DockPreferenceStore {
    func readAutohide() -> Bool?
    func readAutohideDelay() -> Double?
    func writeAutohideDelay(_ value: Double) -> Bool
}

/// 重启 Dock，使 autohide-delay 立即生效。
protocol DockRelauncher {
    func relaunch() -> Bool
}

enum DockAutohideRestrictError: Error, Equatable {
    case autohideRequired
    case writeFailed
    case relaunchFailed
}

/// 通过拉长 Dock autohide-delay 限制悬停弹出；不改写系统 autohide 开关。
final class DockAutohideRestrictService {
    private let settings: DockAutohideRestrictStore
    private let dock: DockPreferenceStore
    private let relauncher: DockRelauncher
    private let alerts: ShortcutAlerting
    private var applied = false

    init(
        settings: DockAutohideRestrictStore = DockAutohideRestrictStore(),
        dock: DockPreferenceStore = CFPreferencesDockStore(),
        relauncher: DockRelauncher = ProcessDockRelauncher(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.settings = settings
        self.dock = dock
        self.relauncher = relauncher
        self.alerts = alerts
    }

    /// 菜单勾选态：偏好为开且本会话已成功施加（或启动后已施加）。
    var isEffective: Bool {
        settings.isEnabled && applied
    }

    func applySavedSettings() {
        guard settings.isEnabled else {
            applied = false
            return
        }
        switch applyRestriction(persistingPreference: true) {
        case .success:
            break
        case .failure:
            settings.isEnabled = false
            settings.backupDelay = nil
            applied = false
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            return disableRestriction()
        }
        switch applyRestriction(persistingPreference: true) {
        case .success:
            return true
        case .failure(.autohideRequired):
            alerts.notify(
                title: "无法限制程序坞弹出",
                body: "请先在“系统设置 → 桌面与程序坞”中开启“自动隐藏和显示程序坞”，然后再打开此开关。"
            )
            settings.isEnabled = false
            applied = false
            return false
        case .failure:
            alerts.notify(
                title: "无法限制程序坞弹出",
                body: "写入程序坞偏好或重启 Dock 失败，开关保持关闭。"
            )
            settings.isEnabled = false
            applied = false
            return false
        }
    }

    /// 退出时恢复系统 delay，保留偏好以便下次启动再施加。
    func shutdown() {
        guard settings.isEnabled else {
            applied = false
            return
        }
        _ = restoreDelayKeepingPreference()
        applied = false
    }

    private func applyRestriction(persistingPreference: Bool) -> Result<Void, DockAutohideRestrictError> {
        guard dock.readAutohide() == true else {
            return .failure(.autohideRequired)
        }
        if !settings.hasBackupDelay {
            settings.backupDelay = dock.readAutohideDelay() ?? 0
        }
        guard dock.writeAutohideDelay(DockAutohideRestrictStore.restrictedDelay) else {
            if !settings.isEnabled {
                settings.backupDelay = nil
            }
            return .failure(.writeFailed)
        }
        guard relauncher.relaunch() else {
            let backup = settings.backupDelay ?? 0
            _ = dock.writeAutohideDelay(backup)
            if !settings.isEnabled {
                settings.backupDelay = nil
            }
            return .failure(.relaunchFailed)
        }
        if persistingPreference {
            settings.isEnabled = true
        }
        applied = true
        return .success(())
    }

    private func disableRestriction() -> Bool {
        let restored = restoreDelayKeepingPreference()
        settings.isEnabled = false
        settings.backupDelay = nil
        applied = false
        if !restored {
            alerts.notify(
                title: "程序坞延迟恢复失败",
                body: "开关已关闭，但写回 autohide-delay 或重启 Dock 可能未成功。可在系统设置中检查程序坞行为。"
            )
        }
        return true
    }

    @discardableResult
    private func restoreDelayKeepingPreference() -> Bool {
        let target = settings.backupDelay ?? 0
        guard dock.writeAutohideDelay(target) else { return false }
        return relauncher.relaunch()
    }
}

struct CFPreferencesDockStore: DockPreferenceStore {
    static let appID = "com.apple.dock" as CFString
    static let autohideKey = "autohide" as CFString
    static let delayKey = "autohide-delay" as CFString

    func readAutohide() -> Bool? {
        guard let obj = CFPreferencesCopyAppValue(Self.autohideKey, Self.appID) else {
            return nil
        }
        if CFGetTypeID(obj) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((obj as! CFBoolean))
        }
        if let number = obj as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    func readAutohideDelay() -> Double? {
        guard let obj = CFPreferencesCopyAppValue(Self.delayKey, Self.appID) else {
            return nil
        }
        if let number = obj as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    func writeAutohideDelay(_ value: Double) -> Bool {
        CFPreferencesSetValue(
            Self.delayKey,
            NSNumber(value: value),
            Self.appID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesSynchronize(Self.appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

struct ProcessDockRelauncher: DockRelauncher {
    func relaunch() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // Dock 未运行时 killall 非 0，视为无需重启。
            return process.terminationStatus == 0 || process.terminationStatus == 1
        } catch {
            return false
        }
    }
}
