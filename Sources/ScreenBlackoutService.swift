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

/// 覆盖层要同时出现在普通桌面和其他应用的全屏空间。
/// 只设 canJoinAllSpaces 时，窗口会留在桌面空间，全屏应用挡住它，退出全屏才看得到。
enum ScreenBlackoutPresentation {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]
    static let level: NSWindow.Level = .screenSaver

    static func apply(to window: NSWindow) {
        window.collectionBehavior = collectionBehavior
        window.level = level
        window.hidesOnDeactivate = false
    }
}

/// 实际的全屏黑色无边框覆盖窗口：每个显示器一个，纯黑且不渲染任何提示文字，任意按键或鼠标点击解除。
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
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.isMovable = false
            ScreenBlackoutPresentation.apply(to: window)

            let content = ScreenBlackoutContentView(frame: screen.frame)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor

            content.onEvent = { [weak self] in
                self?.dismiss()
            }
            window.contentView = content
            window.orderFrontRegardless()
            created.append(window)
        }
        windows = created
        // 激活会把窗口重新归到本应用所在的桌面空间，需要再声明一次全屏空间并置前。
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            ScreenBlackoutPresentation.apply(to: window)
            window.orderFrontRegardless()
        }
        if let keyWindow = windows.first {
            keyWindow.makeKey()
            keyWindow.makeFirstResponder(keyWindow.contentView)
            ScreenBlackoutPresentation.apply(to: keyWindow)
            keyWindow.orderFrontRegardless()
        }
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

    // 覆盖窗口可能不是关键窗口：首次点击应立即送达 mouseDown，而不是仅用于激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
