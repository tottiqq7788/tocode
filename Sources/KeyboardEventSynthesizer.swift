import CoreGraphics

protocol KeyboardEventSynthesizing {
    func postCommandX()
    func postCommandC()
}

/// 向系统补发带标记的 ⌘X / ⌘C，供事件钩子识别并直接放行，避免递归拦截。
struct KeyboardEventSynthesizer: KeyboardEventSynthesizing {
    static let marker = GlobalShortcutEngine.synthesizerMarker

    var tapLocation: CGEventTapLocation = .cgSessionEventTap

    func postCommandX() {
        post(keyCode: CGKeyCode(ShortcutKeyClassifier.keyX), flags: .maskCommand)
    }

    func postCommandC() {
        _ = post(keyCode: CGKeyCode(ShortcutKeyClassifier.keyC), flags: .maskCommand)
    }

    @discardableResult
    func postCommandV() -> Bool {
        post(keyCode: CGKeyCode(ShortcutKeyClassifier.keyV), flags: .maskCommand)
    }

    @discardableResult
    private func post(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        down.post(tap: tapLocation)
        up.post(tap: tapLocation)
        return true
    }
}
