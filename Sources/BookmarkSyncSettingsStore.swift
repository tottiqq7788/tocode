import Foundation

struct BookmarkSyncSettingsStore {
    static let enabledKey = "tocode.bookmarkSync.remoteEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var isRemoteEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
