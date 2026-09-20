import CoreGraphics
import Foundation

struct KeyboardShortcutMapping: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let source: RecordedShortcut
    let target: KeyboardShortcutMappingTarget
}

struct KeyboardShortcutMappingDraft: Equatable {
    var id: UUID?
    var name: String
    var source: RecordedShortcut?
    var target: KeyboardShortcutMappingTarget?

    init(
        id: UUID? = nil,
        name: String = "",
        source: RecordedShortcut? = nil,
        target: KeyboardShortcutMappingTarget? = nil
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

/// 目标可以是用户录入的组合键，也可以是内置命名功能。
enum KeyboardShortcutMappingTarget: Equatable, Hashable {
    case shortcut(RecordedShortcut)
    case action(KeyboardMappingAction)

    /// 快捷键目标，或桌面切换解析出的组合键；Tocode 动作没有组合键。
    var resolvedShortcut: RecordedShortcut? {
        switch self {
        case .shortcut(let shortcut):
            return shortcut
        case .action(let action):
            return action.synthesizedShortcut
        }
    }

    func remapStep() -> KeyboardShortcutRemapStep {
        switch self {
        case .shortcut(let shortcut):
            return .emit(shortcut)
        case .action(let action):
            if let shortcut = action.synthesizedShortcut {
                return .emit(shortcut)
            }
            return .invoke(action)
        }
    }

    var displayText: String {
        switch self {
        case .shortcut(let shortcut):
            return shortcut.displayName
        case .action(let action):
            return action.title
        }
    }
}

extension KeyboardShortcutMappingTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case shortcut
        case action
    }

    private enum Kind: String, Codable {
        case shortcut
        case action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) {
            switch kind {
            case .shortcut:
                self = .shortcut(try container.decode(RecordedShortcut.self, forKey: .shortcut))
            case .action:
                self = .action(try container.decode(KeyboardMappingAction.self, forKey: .action))
            }
            return
        }
        // 旧格式没有 kind 判别字段，整个对象就是目标组合键。
        self = .shortcut(try RecordedShortcut(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shortcut(let shortcut):
            try container.encode(Kind.shortcut, forKey: .kind)
            try container.encode(shortcut, forKey: .shortcut)
        case .action(let action):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(action, forKey: .action)
        }
    }
}

/// 内置命名功能：桌面切换走既有组合键合成；其余调用 Tocode 一次性动作或开关切换。
enum KeyboardMappingAction: String, Codable, CaseIterable, Equatable, Hashable {
    case switchDesktopLeft
    case switchDesktopRight
    case openFinderAtRoot
    case copyFinderSelectedPath
    case initRootFromFinder
    case toggleHidden
    case toggleFinderMove
    case toggleFinderCommandQ
    case readClipboardRoot
    case resetRoot
    case toggleCodexSync
    case openWeChatLocation
    case blackout
    case toggleVerticalWheel
    case toggleHorizontalWheel
    case toggleDoubleCommandQ
    case toggleLaunchAtLogin
    case quit

    var title: String {
        switch self {
        case .switchDesktopLeft:
            return "向左切换桌面"
        case .switchDesktopRight:
            return "向右切换桌面"
        case .openFinderAtRoot:
            return "访问路径"
        case .copyFinderSelectedPath:
            return "复制路径"
        case .initRootFromFinder:
            return "目录初始化"
        case .toggleHidden:
            return "显示/隐藏隐藏文件"
        case .toggleFinderMove:
            return "x/v移动文件"
        case .toggleFinderCommandQ:
            return "⌘Q强关访达"
        case .readClipboardRoot:
            return "读取剪贴板"
        case .resetRoot:
            return "重置初始目录"
        case .toggleCodexSync:
            return "同步项目夹"
        case .openWeChatLocation:
            return "文件位置"
        case .blackout:
            return "临时黑屏"
        case .toggleVerticalWheel:
            return MouseWheelReverseStore.verticalTitle
        case .toggleHorizontalWheel:
            return MouseWheelReverseStore.horizontalTitle
        case .toggleDoubleCommandQ:
            return "双击⌘Q"
        case .toggleLaunchAtLogin:
            return LaunchAtLoginService.menuTitle
        case .quit:
            return "退出"
        }
    }

    var menuSymbolName: String {
        switch self {
        case .switchDesktopLeft:
            return "arrow.left.square"
        case .switchDesktopRight:
            return "arrow.right.square"
        case .openFinderAtRoot:
            return "macwindow"
        case .copyFinderSelectedPath:
            return "doc.on.clipboard"
        case .initRootFromFinder:
            return "folder.badge.gearshape"
        case .toggleHidden:
            return "eye"
        case .toggleFinderMove:
            return "arrow.left.arrow.right"
        case .toggleFinderCommandQ:
            return "xmark.rectangle"
        case .readClipboardRoot:
            return "doc.on.clipboard"
        case .resetRoot:
            return "arrow.counterclockwise"
        case .toggleCodexSync:
            return "arrow.triangle.2.circlepath"
        case .openWeChatLocation:
            return "folder"
        case .blackout:
            return "display.trianglebadge.exclamationmark"
        case .toggleVerticalWheel:
            return "arrow.up.arrow.down"
        case .toggleHorizontalWheel:
            return "arrow.left.and.right"
        case .toggleDoubleCommandQ:
            return "q.circle"
        case .toggleLaunchAtLogin:
            return "power.circle"
        case .quit:
            return "power"
        }
    }

    var group: KeyboardMappingActionGroup {
        switch self {
        case .switchDesktopLeft, .switchDesktopRight:
            return .system
        case .openFinderAtRoot, .copyFinderSelectedPath, .initRootFromFinder,
            .toggleHidden, .toggleFinderMove, .toggleFinderCommandQ:
            return .finder
        case .readClipboardRoot, .resetRoot:
            return .directory
        case .toggleCodexSync:
            return .codex
        case .openWeChatLocation:
            return .wechat
        case .blackout, .toggleVerticalWheel, .toggleHorizontalWheel, .toggleDoubleCommandQ:
            return .mac
        case .toggleLaunchAtLogin:
            return .settings
        case .quit:
            return .application
        }
    }

    /// 系统「调度中心 → 向左/向右移动一个空间」的默认触发键。
    /// 物理方向键始终带 SecondaryFn；只设 Control 时系统不会把它当成空间切换热键。
    var synthesizedShortcut: RecordedShortcut? {
        switch self {
        case .switchDesktopLeft:
            return RecordedShortcut(keyCode: 123, modifiers: [.control, .function], keyLabel: "\u{2190}")
        case .switchDesktopRight:
            return RecordedShortcut(keyCode: 124, modifiers: [.control, .function], keyLabel: "\u{2192}")
        default:
            return nil
        }
    }

    var shortcut: RecordedShortcut {
        synthesizedShortcut ?? RecordedShortcut(keyCode: 0, modifiers: [], keyLabel: "")
    }

    var command: TocodeCommand? {
        switch self {
        case .initRootFromFinder:
            return .root(.initFromFinder)
        case .toggleHidden:
            return .hidden(.toggle)
        case .toggleFinderMove:
            return .shortcut(.finderMove, .toggle)
        case .toggleFinderCommandQ:
            return .shortcut(.finderCmdQ, .toggle)
        case .resetRoot:
            return .root(.reset)
        case .toggleCodexSync:
            return .codex(.sync(.toggle))
        case .openWeChatLocation:
            return .wechat(.location)
        case .blackout:
            return .blackout
        case .toggleVerticalWheel:
            return .wheel(.vertical, .toggle)
        case .toggleHorizontalWheel:
            return .wheel(.horizontal, .toggle)
        case .toggleDoubleCommandQ:
            return .shortcut(.doubleCmdQ, .toggle)
        case .toggleLaunchAtLogin:
            return .login(.toggle)
        case .quit:
            return .quit
        case .switchDesktopLeft, .switchDesktopRight, .openFinderAtRoot,
            .copyFinderSelectedPath, .readClipboardRoot:
            return nil
        }
    }

    var mutatesManualRoot: Bool {
        switch self {
        case .readClipboardRoot, .resetRoot, .initRootFromFinder:
            return true
        default:
            return false
        }
    }

    var notifiesToggleResult: Bool {
        switch self {
        case .toggleHidden, .toggleFinderMove, .toggleFinderCommandQ, .toggleCodexSync,
            .toggleVerticalWheel, .toggleHorizontalWheel, .toggleDoubleCommandQ,
            .toggleLaunchAtLogin:
            return true
        default:
            return false
        }
    }
}

enum KeyboardMappingActionGroup: String, CaseIterable, Equatable {
    case system
    case finder
    case directory
    case codex
    case wechat
    case mac
    case settings
    case application

    var title: String {
        switch self {
        case .system:
            return "系统"
        case .finder:
            return "访达"
        case .directory:
            return "目录"
        case .codex:
            return "codex"
        case .wechat:
            return "微信关联"
        case .mac:
            return "mac"
        case .settings:
            return "设置"
        case .application:
            return "应用"
        }
    }

    var actions: [KeyboardMappingAction] {
        KeyboardMappingAction.allCases.filter { $0.group == self }
    }
}

enum KeyboardShortcutMappingValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case missingSource
    case missingTarget
    case duplicateName
    case duplicateSource
    case mappingNotFound
    case sourceConflictsWithAction

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
        case .sourceConflictsWithAction:
            return "源快捷键与所选功能自身的触发键相同，映射后不会有任何效果，请换一个源快捷键。"
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

    init(defaults: UserDefaults = TocodePreferences.shared) {
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

        // 只拒绝「源 == 所选桌面功能自身的触发键」；Tocode 动作没有自身触发键。
        if case .action(let action) = target,
            let actionShortcut = action.synthesizedShortcut,
            KeyboardShortcutSignature(actionShortcut) == sourceSignature
        {
            return .failure(.sourceConflictsWithAction)
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

    func replaceAll(_ mappings: [KeyboardShortcutMapping]) {
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
    case invoke(KeyboardMappingAction)
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
        return mapping.target.remapStep()
    }
}
