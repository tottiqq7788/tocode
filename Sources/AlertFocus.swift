import AppKit

enum AlertFocus {
    static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = firstEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }
}

extension NSAlert {
    /// 菜单栏应用里 NSAlert 的 accessory 输入框默认拿不到焦点；窗口成为 key 后再落到第一个可编辑文本框。
    @discardableResult
    func runModalFocusingFirstTextField() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        layout()
        let field = accessoryView.flatMap(AlertFocus.firstEditableTextField)
            ?? window.contentView.flatMap(AlertFocus.firstEditableTextField)
        if let field {
            window.initialFirstResponder = field
            let focusField: () -> Void = { [window] in
                _ = window.makeFirstResponder(field)
            }
            DispatchQueue.main.async { focusField() }
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                if let token = observer {
                    NotificationCenter.default.removeObserver(token)
                    observer = nil
                }
                DispatchQueue.main.async { focusField() }
            }
            let response = runModal()
            if let token = observer {
                NotificationCenter.default.removeObserver(token)
            }
            return response
        }
        return runModal()
    }
}
