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
        legacy: UserDefaults? = UserDefaults(suiteName: legacySuiteName),
        processDefaults: UserDefaults? = nil
    ) {
        if canonical.bool(forKey: migratedKey) { return }
        overlayKnownKeys(from: legacy, onto: canonical)
        // Bundle ID 仍是 com.tocode.mac。suiteName 同名读不到 UserDefaults.standard 里的现用值。
        let extra = processDefaults
            ?? (Bundle.main.bundleIdentifier == legacySuiteName ? UserDefaults.standard : nil)
        if let extra, extra !== legacy {
            overlayKnownKeys(from: extra, onto: canonical)
        }
        canonical.set(true, forKey: migratedKey)
    }

    private static func overlayKnownKeys(from source: UserDefaults?, onto canonical: UserDefaults) {
        guard let source else { return }
        for key in knownKeys {
            if let value = source.object(forKey: key) {
                canonical.set(value, forKey: key)
            }
        }
    }
}
