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
        // 首次展开：移除占位项，填充真实子项
        guard let idx = menu.items.firstIndex(where: { $0.title == Self.placeholderTitle }) else { return }
        menu.removeItem(at: idx)
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
        let item = NSMenuItem(title: entry.name, action: #selector(copyItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.path

        if entry.kind == .directory {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self

            // 第一项：复制此文件夹路径
            let copyItem = NSMenuItem(title: "复制路径", action: #selector(copyItem(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = entry.path
            submenu.addItem(copyItem)
            submenu.addItem(.separator())

            // 占位（惰性加载子项）
            let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)

            menuDirectoryMap[ObjectIdentifier(submenu)] = entry.path
            item.submenu = submenu
        }
        return item
    }

    @objc private func copyItem(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            clipboard.copyPath(path)
        }
    }
}
