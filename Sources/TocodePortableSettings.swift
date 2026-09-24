import Foundation

struct TocodePortableSettings: Codable, Equatable {
    static let formatID = "tocode.settings"
    static let currentVersion = 1
    static let folderTitle = "配置"
    static let exportTitle = "导出配置"
    static let importTitle = "导入配置"

    struct Shortcuts: Codable, Equatable {
        var finderMove: Bool
        var doubleCommandQ: Bool
        var finderCommandQ: Bool
    }

    struct MouseWheel: Codable, Equatable {
        var vertical: Bool
        var horizontal: Bool
    }

    var format: String
    var version: Int
    var keyboardMappings: [KeyboardShortcutMapping]
    var trackpad: [String: KeyboardShortcutMappingTarget]
    var shortcuts: Shortcuts
    var mouseWheel: MouseWheel
}

enum TocodePortableSettingsError: LocalizedError {
    case invalidFormat
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "不是有效的 Tocode 配置文件。"
        case .unsupportedVersion:
            return "不支持的配置文件版本。"
        }
    }
}

enum TocodePortableSettingsTransfer {
    static func make(from defaults: UserDefaults) -> TocodePortableSettings {
        let pad = TrackpadShortcutStore(defaults: defaults)
        var trackpad: [String: KeyboardShortcutMappingTarget] = [:]
        for gesture in TrackpadTapGesture.allCases {
            if let binding = pad.binding(for: gesture) {
                trackpad[String(gesture.rawValue)] = binding
            }
        }
        let shortcuts = ShortcutSettingsStore(defaults: defaults)
        let wheel = MouseWheelReverseStore(defaults: defaults)
        return TocodePortableSettings(
            format: TocodePortableSettings.formatID,
            version: TocodePortableSettings.currentVersion,
            keyboardMappings: KeyboardShortcutMappingStore(defaults: defaults).allMappings(),
            trackpad: trackpad,
            shortcuts: TocodePortableSettings.Shortcuts(
                finderMove: shortcuts.finderMoveHotkeysEnabled,
                doubleCommandQ: shortcuts.doubleCommandQEnabled,
                finderCommandQ: shortcuts.finderCommandQEnabled
            ),
            mouseWheel: TocodePortableSettings.MouseWheel(
                vertical: wheel.reverseVerticalEnabled,
                horizontal: wheel.reverseHorizontalEnabled
            )
        )
    }

    static func encode(_ settings: TocodePortableSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    static func decode(_ data: Data) throws -> TocodePortableSettings {
        let settings = try JSONDecoder().decode(TocodePortableSettings.self, from: data)
        guard settings.format == TocodePortableSettings.formatID else {
            throw TocodePortableSettingsError.invalidFormat
        }
        guard settings.version == TocodePortableSettings.currentVersion else {
            throw TocodePortableSettingsError.unsupportedVersion
        }
        return settings
    }

    static func apply(_ settings: TocodePortableSettings, to defaults: UserDefaults) {
        KeyboardShortcutMappingStore(defaults: defaults).replaceAll(settings.keyboardMappings)
        let pad = TrackpadShortcutStore(defaults: defaults)
        for gesture in TrackpadTapGesture.allCases {
            if let binding = settings.trackpad[String(gesture.rawValue)] {
                pad.setBinding(binding, for: gesture)
            } else {
                pad.removeBinding(for: gesture)
            }
        }
        let shortcuts = ShortcutSettingsStore(defaults: defaults)
        shortcuts.finderMoveHotkeysEnabled = settings.shortcuts.finderMove
        shortcuts.doubleCommandQEnabled = settings.shortcuts.doubleCommandQ
        shortcuts.finderCommandQEnabled = settings.shortcuts.finderCommandQ
        let wheel = MouseWheelReverseStore(defaults: defaults)
        wheel.reverseVerticalEnabled = settings.mouseWheel.vertical
        wheel.reverseHorizontalEnabled = settings.mouseWheel.horizontal
    }
}
