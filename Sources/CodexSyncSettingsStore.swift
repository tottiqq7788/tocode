import Foundation

/// 「codex跟随」开关的持久化（原「同步项目夹」键名保留）。缺省关闭。
struct CodexSyncSettingsStore {
    static let syncEnabledKey = "tocode.codexProjectSyncEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Self.syncEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.syncEnabledKey) }
    }
}
