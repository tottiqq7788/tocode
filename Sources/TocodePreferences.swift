import Foundation

enum TocodePreferences {
    static let suiteName = "com.tocode.app"
    static let legacySuiteName = "com.tocode.mac"
    static let migratedKey = "tocode.settings.canonicalDomainApplied"

    static var shared: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    static var knownKeys: [String] {
        [RootPathStore.key]
            + [
                ShortcutSettingsStore.finderMoveKey,
                ShortcutSettingsStore.doubleCommandQKey,
                ShortcutSettingsStore.finderCommandQKey,
                KeyboardShortcutMappingStore.defaultsKey,
                MouseWheelReverseStore.verticalKey,
                MouseWheelReverseStore.horizontalKey,
                ExtendedSettingsStore.akEnabledKey,
                CodexSyncSettingsStore.syncEnabledKey
            ]
            + TrackpadTapGesture.allCases.map(TrackpadShortcutStore.defaultsKey(for:))
    }

    static func migrateIfNeeded(
        canonical: UserDefaults = shared,
        legacy: UserDefaults? = UserDefaults(suiteName: legacySuiteName)
    ) {
        if canonical.bool(forKey: migratedKey) { return }
        if let legacy {
            for key in knownKeys {
                if let value = legacy.object(forKey: key) {
                    canonical.set(value, forKey: key)
                }
            }
        }
        canonical.set(true, forKey: migratedKey)
    }
}
