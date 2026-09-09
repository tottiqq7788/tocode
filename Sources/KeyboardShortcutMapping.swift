import CoreGraphics
import Foundation

struct KeyboardShortcutMapping: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let source: RecordedShortcut
    let target: RecordedShortcut
}

struct KeyboardShortcutMappingDraft: Equatable {
    var id: UUID?
    var name: String
    var source: RecordedShortcut?
    var target: RecordedShortcut?

    init(
        id: UUID? = nil,
        name: String = "",
        source: RecordedShortcut? = nil,
        target: RecordedShortcut? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.target = target
    }

    init(mapping: KeyboardShortcutMapping) {
        id = mapping.id
        name = mapping.name
        source = mapping.source
        target = mapping.target
    }
}

enum KeyboardShortcutMappingValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case missingSource
    case missingTarget
    case duplicateName
    case duplicateSource
    case mappingNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入名称。"
        case .missingSource:
            return "请录入源快捷键。"
        case .missingTarget:
            return "请录入目标快捷键。"
        case .duplicateName:
            return "该名称已存在，请使用其他名称。"
        case .duplicateSource:
            return "该源快捷键已被其他规则使用。"
        case .mappingNotFound:
            return "该规则已不存在，请重新打开键盘菜单。"
        }
    }
}

struct KeyboardShortcutSignature: Hashable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    init(_ shortcut: RecordedShortcut) {
        keyCode = shortcut.keyCode
        modifiers = shortcut.modifiers
    }
}

struct KeyboardShortcutMappingStore {
    static let defaultsKey = "tocode.keyboardShortcutMappings"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allMappings() -> [KeyboardShortcutMapping] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([KeyboardShortcutMapping].self, from: data)) ?? []
    }

    func save(
        _ draft: KeyboardShortcutMappingDraft
    ) -> Result<KeyboardShortcutMapping, KeyboardShortcutMappingValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard let source = draft.source else { return .failure(.missingSource) }
        guard let target = draft.target else { return .failure(.missingTarget) }

        var mappings = allMappings()
        let otherMappings = mappings.filter { $0.id != draft.id }
        if otherMappings.contains(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .failure(.duplicateName)
        }

        let sourceSignature = KeyboardShortcutSignature(source)
        if otherMappings.contains(where: {
            KeyboardShortcutSignature($0.source) == sourceSignature
        }) {
            return .failure(.duplicateSource)
        }

        let mapping: KeyboardShortcutMapping
        if let id = draft.id {
            guard let index = mappings.firstIndex(where: { $0.id == id }) else {
                return .failure(.mappingNotFound)
            }
            mapping = KeyboardShortcutMapping(
                id: id,
                name: name,
                source: source,
                target: target
            )
            mappings[index] = mapping
        } else {
            mapping = KeyboardShortcutMapping(
                id: UUID(),
                name: name,
                source: source,
                target: target
            )
            mappings.append(mapping)
        }

        persist(mappings)
        return .success(mapping)
    }

    func delete(id: UUID) {
        var mappings = allMappings()
        mappings.removeAll { $0.id == id }
        persist(mappings)
    }

    private func persist(_ mappings: [KeyboardShortcutMapping]) {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct KeyboardShortcutEventSnapshot: Equatable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
    let isKeyDown: Bool
    let isAutoRepeat: Bool
    let isSynthesized: Bool

    static func capture(type: CGEventType, event: CGEvent) -> KeyboardShortcutEventSnapshot? {
        guard type == .keyDown || type == .keyUp else { return nil }
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard rawKeyCode >= 0, rawKeyCode <= Int64(UInt16.max) else { return nil }

        var modifiers: ShortcutModifiers = []
        let flags = event.flags
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }

        return KeyboardShortcutEventSnapshot(
            keyCode: UInt16(rawKeyCode),
            modifiers: modifiers,
            isKeyDown: type == .keyDown,
            isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isSynthesized: event.getIntegerValueField(.eventSourceUserData)
                == GlobalShortcutEngine.synthesizerMarker
        )
    }
}

enum KeyboardShortcutRemapStep: Equatable {
    case pass
    case suppress
    case emit(RecordedShortcut)
}

struct KeyboardShortcutRemapEngine {
    private var mappingsBySource: [KeyboardShortcutSignature: KeyboardShortcutMapping] = [:]
    private var activeSourceKeyCodes: Set<UInt16> = []

    init(mappings: [KeyboardShortcutMapping] = []) {
        replaceMappings(mappings)
    }

    mutating func replaceMappings(_ mappings: [KeyboardShortcutMapping]) {
        mappingsBySource = Dictionary(
            mappings.map { (KeyboardShortcutSignature($0.source), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func claims(_ event: KeyboardShortcutEventSnapshot) -> Bool {
        if event.isSynthesized {
            return false
        }
        if activeSourceKeyCodes.contains(event.keyCode) {
            return true
        }
        guard event.isKeyDown else {
            return false
        }
        return mappingsBySource[
            KeyboardShortcutSignature(
                RecordedShortcut(
                    keyCode: event.keyCode,
                    modifiers: event.modifiers,
                    keyLabel: ""
                )
            )
        ] != nil
    }

    mutating func process(_ event: KeyboardShortcutEventSnapshot) -> KeyboardShortcutRemapStep {
        if event.isSynthesized {
            return .pass
        }

        if !event.isKeyDown {
            if activeSourceKeyCodes.remove(event.keyCode) != nil {
                return .suppress
            }
            return .pass
        }

        if activeSourceKeyCodes.contains(event.keyCode) {
            return .suppress
        }

        let signature = KeyboardShortcutSignature(
            RecordedShortcut(
                keyCode: event.keyCode,
                modifiers: event.modifiers,
                keyLabel: ""
            )
        )
        guard let mapping = mappingsBySource[signature] else {
            return .pass
        }
        guard !event.isAutoRepeat else {
            return .suppress
        }

        activeSourceKeyCodes.insert(event.keyCode)
        return .emit(mapping.target)
    }
}
