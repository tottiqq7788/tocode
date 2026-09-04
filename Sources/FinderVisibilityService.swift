import Foundation
import AppKit

/// Finder 隐藏文件显示状态的读写边界。
protocol FinderVisibilityStore {
    func readShowAllFiles() -> Bool?
    func writeShowAllFiles(_ value: Bool) -> Bool
}

/// 重启 Finder，使 AppleShowAllFiles 立即生效。
protocol FinderRelauncher {
    func relaunch() -> Bool
}

/// 以 com.apple.finder / AppleShowAllFiles 为唯一权威，读写失败时回滚。
struct FinderVisibilityService {
    let store: FinderVisibilityStore
    let relauncher: FinderRelauncher

    init(
        store: FinderVisibilityStore = CFPreferencesFinderVisibilityStore(),
        relauncher: FinderRelauncher = WorkspaceFinderRelauncher()
    ) {
        self.store = store
        self.relauncher = relauncher
    }

    /// 缺失键视为隐藏（与 Finder 默认一致）。
    func currentShowAllFiles() -> Bool {
        store.readShowAllFiles() ?? false
    }

    /// 写入新状态并重启 Finder。任一步失败则恢复旧值并返回 false。
    @discardableResult
    func setShowAllFiles(_ show: Bool) -> Bool {
        let previous = currentShowAllFiles()
        guard store.writeShowAllFiles(show) else { return false }
        guard relauncher.relaunch() else {
            _ = store.writeShowAllFiles(previous)
            return false
        }
        return true
    }
}

struct CFPreferencesFinderVisibilityStore: FinderVisibilityStore {
    static let appID = "com.apple.finder" as CFString
    static let key = "AppleShowAllFiles" as CFString

    func readShowAllFiles() -> Bool? {
        guard let obj = CFPreferencesCopyAppValue(Self.key, Self.appID) else {
            return nil
        }
        if CFGetTypeID(obj) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((obj as! CFBoolean))
        }
        if let number = obj as? NSNumber {
            return number.boolValue
        }
        if let text = obj as? String {
            switch text.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func writeShowAllFiles(_ value: Bool) -> Bool {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetValue(
            Self.key,
            cfValue,
            Self.appID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesSynchronize(Self.appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

struct WorkspaceFinderRelauncher: FinderRelauncher {
    func relaunch() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.finder"
        }
        if apps.isEmpty { return true }
        return apps.allSatisfy { $0.terminate() }
    }
}
