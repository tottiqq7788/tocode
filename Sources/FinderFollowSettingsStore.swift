import Foundation

/// 「访达跟随」开关的持久化。缺省关闭。
struct FinderFollowSettingsStore {
    static let followEnabledKey = "tocode.finderFollowEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var followEnabled: Bool {
        get { defaults.bool(forKey: Self.followEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.followEnabledKey) }
    }
}
