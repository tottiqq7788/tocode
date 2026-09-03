import AppKit

/// 菜单栏图标控制器：分发左右键点击事件。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let builder = MenuBuilder()
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let store = RootPathStore()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "tomaid")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showDirectoryMenu()
        case .leftMouseUp:
            handleLeftClick()
        default:
            break
        }
    }

    /// 左键：剪贴板若是真实存在的文件夹路径，设为新根文件夹。
    private func handleLeftClick() {
        guard let text = clipboard.read(), fs.isExistingDirectory(text) else { return }
        store.save(text)
    }

    /// 右键：弹出根文件夹目录树。
    private func showDirectoryMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let root = store.load(), fs.isExistingDirectory(root) {
            builder.fillRoot(menu, with: root)
        } else {
            let item = menu.addItem(withTitle: "选择根文件夹…", action: #selector(chooseRoot), keyEquivalent: "")
            item.target = self
        }

        menu.addItem(.separator())
        let change = menu.addItem(withTitle: "更改根文件夹…", action: #selector(chooseRoot), keyEquivalent: "")
        change.target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择作为根文件夹的目录"
        if panel.runModal() == .OK, let url = panel.url {
            store.save(url.path)
        }
    }
}
