import Foundation

/// 「同步项目夹」开关的持久化。缺省关闭。
struct CodexSyncSettingsStore {
    static let syncEnabledKey = "tocode.codexProjectSyncEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Self.syncEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.syncEnabledKey) }
    }
}
