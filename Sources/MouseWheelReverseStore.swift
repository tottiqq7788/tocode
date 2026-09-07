import Foundation

/// 两个滚轮对调开关的持久化。缺省均为关闭。
struct MouseWheelReverseStore {
    static let verticalKey = "tocode.reverseMouseWheelVerticalEnabled"
    static let horizontalKey = "tocode.reverseMouseWheelHorizontalEnabled"
    static let verticalTitle = "对调垂直滚轮"
    static let horizontalTitle = "对调横向滚轮"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var reverseVerticalEnabled: Bool {
        get { defaults.bool(forKey: Self.verticalKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.verticalKey) }
    }

    var reverseHorizontalEnabled: Bool {
        get { defaults.bool(forKey: Self.horizontalKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.horizontalKey) }
    }
}
