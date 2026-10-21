import Foundation

/// 手机切换的当前档案。只进 com.tocode.app，不进 .tocode。
struct PhoneHermesProfileStore {
    static let key = "tocode.hermesProfile"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func saved() -> String {
        defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func resolved(among names: [String]) -> String {
        HermesProfileCatalog.accepted(saved(), among: names)
    }

    func save(_ name: String) {
        defaults.set(name, forKey: Self.key)
    }
}
