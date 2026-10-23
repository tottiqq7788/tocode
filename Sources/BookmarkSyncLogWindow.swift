import AppKit
import Foundation

@MainActor
enum BookmarkSyncLogWindow {
    private static var controller: BookmarkSyncLogWindowController?

    static func present(log: BookmarkSyncActivityLog) {
        if let existing = controller, let window = existing.window, window.isVisible {
            existing.attach(log: log)
            existing.reload()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let created = BookmarkSyncLogWindowController(log: log) {
            controller = nil
        }
        controller = created
        guard let window = created.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class BookmarkSyncLogWindowController: NSWindowController, NSWindowDelegate {
    private var log: BookmarkSyncActivityLog
    private var textView: NSTextView!
    private var previousOnChange: (() -> Void)?
    private let onClose: () -> Void
    private var renderedCache = ""

    init(log: BookmarkSyncActivityLog, onClose: @escaping () -> Void) {
        self.log = log
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "书签同步日志"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 280)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        hookLog()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(log: BookmarkSyncActivityLog) {
        guard log !== self.log else { return }
        unhookLog()
        self.log = log
        hookLog()
    }

    func reload() {
        guard let textView else { return }
        let text = log.renderedText()
        guard text != renderedCache else { return }

        let wasAtBottom = isScrolledToBottom()
        let selected = textView.selectedRange()
        let oldLength = (textView.string as NSString).length
        textView.string = text
        renderedCache = text

        // 实时刷新时尽量保住用户正在拖选的范围，避免「选中即被冲掉、无法复制」。
        let newLength = (text as NSString).length
        if selected.length > 0, selected.location + selected.length <= oldLength {
            let capped = NSRange(
                location: min(selected.location, newLength),
                length: min(selected.length, max(0, newLength - min(selected.location, newLength)))
            )
            if capped.length > 0 {
                textView.setSelectedRange(capped)
            }
        }
        if wasAtBottom, selected.length == 0 {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        unhookLog()
        onClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(textView)
    }

    @objc private func clearLog() {
        log.clear()
        log.append("日志已清空。")
    }

    @objc private func copyAll() {
        let text = log.renderedText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    private func hookLog() {
        previousOnChange = log.onChange
        log.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }

    private func unhookLog() {
        log.onChange = previousOnChange
        previousOnChange = nil
    }

    private func isScrolledToBottom() -> Bool {
        guard let scroll = textView?.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        let doc = scroll.documentView?.bounds ?? .zero
        return visible.maxY >= doc.maxY - 40
    }

    private func makeContent() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.autohidesScrollers = true

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.usesFindBar = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.documentView = text
        self.textView = text

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copy.translatesAutoresizingMaskIntoConstraints = false
        let clear = NSButton(title: "清空", target: self, action: #selector(clearLog))
        clear.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        root.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        root.addSubview(copy)
        root.addSubview(clear)
        root.addSubview(close)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            copy.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            copy.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            copy.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            clear.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            clear.leadingAnchor.constraint(equalTo: copy.trailingAnchor, constant: 8),
            close.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        return root
    }
}
