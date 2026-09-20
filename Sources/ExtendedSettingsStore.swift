import Foundation

/// 「设置 → 拓展设置」中的功能类型开关。缺省关闭。
struct ExtendedSettingsStore {
    static let akEnabledKey = "tocode.extendedSettings.akEnabled"
    static let folderTitle = "拓展设置"
    static let akTitle = "AK"
    static let akCredentialTitle = "AK密钥"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    /// AK 类型开启时才显示模型切换与 AK密钥。
    var akEnabled: Bool {
        get { defaults.bool(forKey: Self.akEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.akEnabledKey) }
    }
}
