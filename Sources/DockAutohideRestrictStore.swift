import Foundation

/// 「限制程序坞弹出」开关与开启前 Dock delay 备份的持久化。缺省关闭。
struct DockAutohideRestrictStore {
    static let enabledKey = "tocode.dockAutohideRestrictEnabled"
    static let backupDelayKey = "tocode.dockAutohideDelayBackup"
    static let menuTitle = "限制程序坞弹出"
    /// 开启后写入的悬停延迟（秒）；足够大即可使悬停实际上无法弹出。
    static let restrictedDelay: Double = 1000

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var hasBackupDelay: Bool {
        defaults.object(forKey: Self.backupDelayKey) != nil
    }

    var backupDelay: Double? {
        get {
            guard defaults.object(forKey: Self.backupDelayKey) != nil else { return nil }
            return defaults.double(forKey: Self.backupDelayKey)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.backupDelayKey)
            } else {
                defaults.removeObject(forKey: Self.backupDelayKey)
            }
        }
    }
}
