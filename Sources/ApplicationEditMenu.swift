import AppKit

@objc
private protocol ApplicationEditActionRouting: AnyObject {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
    func cut(_ sender: Any?)
    func copy(_ sender: Any?)
    func paste(_ sender: Any?)
    func selectAll(_ sender: Any?)
}

@MainActor
enum ApplicationEditMenu {
    static let identifier = NSUserInterfaceItemIdentifier(
        "com.tocode.application-edit-menu"
    )

    static func install(on application: NSApplication) {
        let mainMenu = application.mainMenu ?? NSMenu()
        guard !mainMenu.items.contains(where: { $0.identifier == identifier }) else {
            return
        }
        mainMenu.addItem(makeEditMenuItem())
        application.mainMenu = mainMenu
    }

    static func makeEditMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        root.identifier = identifier
        let menu = NSMenu(title: "编辑")
        menu.autoenablesItems = true
        menu.addItem(command(
            title: "撤销",
            action: #selector(ApplicationEditActionRouting.undo(_:)),
            key: "z"
        ))
        menu.addItem(command(
            title: "重做",
            action: #selector(ApplicationEditActionRouting.redo(_:)),
            key: "Z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(command(
            title: "剪切",
            action: #selector(ApplicationEditActionRouting.cut(_:)),
            key: "x"
        ))
        menu.addItem(command(
            title: "复制",
            action: #selector(ApplicationEditActionRouting.copy(_:)),
            key: "c"
        ))
        menu.addItem(command(
            title: "粘贴",
            action: #selector(ApplicationEditActionRouting.paste(_:)),
            key: "v"
        ))
        menu.addItem(.separator())
        menu.addItem(command(
            title: "全选",
            action: #selector(ApplicationEditActionRouting.selectAll(_:)),
            key: "a"
        ))
        root.submenu = menu
        return root
    }

    private static func command(
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
