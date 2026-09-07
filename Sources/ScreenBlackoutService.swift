import AppKit

/// 全屏黑屏覆盖层的抽象边界，便于单元测试注入 mock。
@MainActor
protocol ScreenBlackoutOverlaying: AnyObject {
    var isPresented: Bool { get }
    func show()
    func dismiss()
}

/// 纯逻辑黑屏服务：负责激活与解除状态，真实覆盖窗口通过依赖注入。
@MainActor
final class ScreenBlackoutService {
    private let overlay: ScreenBlackoutOverlaying

    init(overlay: ScreenBlackoutOverlaying) {
        self.overlay = overlay
    }

    var isPresented: Bool { overlay.isPresented }

    /// 显示全屏黑屏；已经显示时是 no-op。
    func activate() {
        guard !overlay.isPresented else { return }
        overlay.show()
    }

    /// 立即关闭所有覆盖窗口。
    func dismiss() {
        overlay.dismiss()
    }
}

/// 实际的全屏黑色无边框覆盖窗口：每个显示器一个，任意按键或鼠标点击解除。
@MainActor
final class ScreenBlackoutOverlay: ScreenBlackoutOverlaying {
    private var windows: [ScreenBlackoutWindow] = []

    var isPresented: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }

        var created: [ScreenBlackoutWindow] = []
        for screen in NSScreen.screens {
            let window = ScreenBlackoutWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false

            let content = ScreenBlackoutContentView(frame: screen.frame)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor

            let label = ScreenBlackoutLabel()
            label.stringValue = "点击恢复"
            label.font = .systemFont(ofSize: 44, weight: .medium)
            label.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
            label.alignment = .center
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)

            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])

            content.onEvent = { [weak self] in
                self?.dismiss()
            }
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(content)
            created.append(window)
        }
        windows = created
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        for window in windows {
            (window.contentView as? ScreenBlackoutContentView)?.onEvent = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}

private final class ScreenBlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScreenBlackoutContentView: NSView {
    var onEvent: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onEvent?()
    }

    override func mouseDown(with event: NSEvent) {
        onEvent?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEvent?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onEvent?()
    }
}

/// 不可交互的文本标签：不拦截点击，确保点击落在覆盖层内容视图上。
private final class ScreenBlackoutLabel: NSTextField {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
