import Foundation

struct BookmarkSyncSettingsStore {
    static let enabledKey = "tocode.bookmarkSync.remoteEnabled"
    static let lastBackupDayKey = "tocode.bookmarkSync.lastBackupDay"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var isRemoteEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var lastBackupDay: String? {
        get { defaults.string(forKey: Self.lastBackupDayKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastBackupDayKey)
            } else {
                defaults.removeObject(forKey: Self.lastBackupDayKey)
            }
        }
    }
}
