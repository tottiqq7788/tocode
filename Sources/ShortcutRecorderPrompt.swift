import AppKit

enum ShortcutRecorderResult {
    case save(RecordedShortcut)
    case clear
    case cancel
}

@MainActor
enum ShortcutRecorderPrompt {
    static func prompt(
        for gesture: TrackpadTapGesture,
        existing: RecordedShortcut?
    ) -> ShortcutRecorderResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = gesture.title
        alert.informativeText = "快捷键"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除配置")

        let recorder = ShortcutRecorderView(shortcut: existing)
        alert.accessoryView = recorder
        alert.window.initialFirstResponder = recorder

        let saveButton = alert.buttons[0]
        let clearButton = alert.buttons[2]
        saveButton.isEnabled = existing != nil
        clearButton.isEnabled = existing != nil
        recorder.onChange = { shortcut in
            saveButton.isEnabled = shortcut != nil
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let shortcut = recorder.shortcut else { return .cancel }
            return .save(shortcut)
        case .alertThirdButtonReturn:
            return .clear
        default:
            return .cancel
        }
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut: RecordedShortcut? {
        didSet {
            label.stringValue = shortcut?.displayName ?? "等待输入"
            onChange?(shortcut)
        }
    }
    var onChange: ((RecordedShortcut?) -> Void)?

    private let label = NSTextField(labelWithString: "")

    init(shortcut: RecordedShortcut?) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 48))

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.stringValue = shortcut?.displayName ?? "等待输入"
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateFocusAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateFocusAppearance()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateFocusAppearance()
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, let captured = Self.capture(event) else { return }
        shortcut = captured
    }

    private func updateFocusAppearance() {
        let focused = window?.firstResponder === self
        layer?.borderColor = (
            focused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor
        ).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }

    private static func capture(_ event: NSEvent) -> RecordedShortcut? {
        let keyCode = event.keyCode
        guard let label = keyLabel(for: keyCode, fallback: event.charactersIgnoringModifiers) else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.function) { modifiers.insert(.function) }

        return RecordedShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: label
        )
    }

    private static func keyLabel(for keyCode: UInt16, fallback: String?) -> String? {
        let labels: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "回车",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "空格",
            50: "`", 51: "删除", 53: "Esc", 65: "小数点", 67: "*", 69: "+",
            71: "清除", 75: "/", 76: "回车", 78: "-", 81: "=", 82: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
            91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home",
            116: "Page Up", 117: "向前删除", 118: "F4", 119: "End", 120: "F2",
            121: "Page Down", 122: "F1", 123: "\u{2190}", 124: "\u{2192}",
            125: "\u{2193}", 126: "\u{2191}"
        ]
        if let label = labels[keyCode] {
            return label
        }
        guard let fallback, !fallback.isEmpty else { return nil }
        return fallback.uppercased()
    }
}
