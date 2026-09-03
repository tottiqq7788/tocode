import AppKit

/// 目录树菜单构建器：把目录内容渲染为 NSMenu 树，子文件夹惰性递归展开。
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private var menuDirectoryMap: [ObjectIdentifier: String] = [:]

    private static let placeholderTitle = "\u{2026}"

    /// 立即填充根菜单（根目录内容在弹出前就绪）。
    func fillRoot(_ menu: NSMenu, with directory: String) {
        fill(menu, with: directory)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        // 仅在仍是占位状态时填充（首次展开）
        guard menu.items.count == 1, menu.items[0].title == Self.placeholderTitle else { return }
        menu.removeAllItems()
        fill(menu, with: dir)
    }

    private func fill(_ menu: NSMenu, with dir: String) {
        let entries = fs.entries(in: dir)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries {
            menu.addItem(makeItem(for: entry))
        }
    }

    private func makeItem(for entry: FileSystemService.Entry) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = self
        item.action = #selector(itemClicked(_:))
        item.representedObject = entry.path

        let isFolder = entry.kind == .directory
        let view = MenuItemView(name: entry.name, isFolder: isFolder, onClick: { [weak self] in
            self?.copyPath(entry.path)
        })
        item.view = view

        if isFolder {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self
            let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            menuDirectoryMap[ObjectIdentifier(submenu)] = entry.path
            item.submenu = submenu
        }
        return item
    }

    @objc private func itemClicked(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            copyPath(path)
        }
    }

    private func copyPath(_ path: String) {
        clipboard.copy(path)
    }
}
