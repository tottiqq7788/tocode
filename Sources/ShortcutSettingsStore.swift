import Foundation

/// 三个快捷键开关的持久化。缺省均为关闭。
struct ShortcutSettingsStore {
    static let finderMoveKey = "tocode.finderMoveHotkeysEnabled"
    static let doubleCommandQKey = "tocode.doubleCommandQEnabled"
    static let finderCommandQKey = "tocode.finderCommandQEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var finderMoveHotkeysEnabled: Bool {
        get { defaults.bool(forKey: Self.finderMoveKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.finderMoveKey) }
    }

    var doubleCommandQEnabled: Bool {
        get { defaults.bool(forKey: Self.doubleCommandQKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.doubleCommandQKey) }
    }

    var finderCommandQEnabled: Bool {
        get { defaults.bool(forKey: Self.finderCommandQKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.finderCommandQKey) }
    }
}
