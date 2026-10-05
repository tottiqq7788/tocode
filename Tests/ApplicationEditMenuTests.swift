import AppKit

private final class ApplicationEditCommandProbe: NSResponder {
    var receivedAction = ""

    @objc func undo(_ sender: Any?) { receivedAction = "undo:" }
    @objc func redo(_ sender: Any?) { receivedAction = "redo:" }
    @objc func cut(_ sender: Any?) { receivedAction = "cut:" }
    @objc func copy(_ sender: Any?) { receivedAction = "copy:" }
    @objc func paste(_ sender: Any?) { receivedAction = "paste:" }
    override func selectAll(_ sender: Any?) { receivedAction = "selectAll:" }
}

@MainActor
func testApplicationEditMenu() async {
    let application = NSApplication.shared
    let previousMenu = application.mainMenu
    let previousNextResponder = application.nextResponder
    defer {
        application.nextResponder = previousNextResponder
        application.mainMenu = previousMenu
    }

    application.mainMenu = NSMenu()
    ApplicationEditMenu.install(on: application)
    ApplicationEditMenu.install(on: application)

    let roots = application.mainMenu?.items.filter {
        $0.identifier == ApplicationEditMenu.identifier
    } ?? []
    expect(roots.count == 1, "全局编辑菜单安装幂等且不重复")
    guard let editMenu = roots.first?.submenu else {
        expect(false, "全局编辑菜单包含子菜单")
        return
    }
    expect(editMenu.autoenablesItems, "编辑命令由 AppKit 响应链自动启停")

    let expected: [(
        title: String,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    )] = [
        ("撤销", "undo:", "z", [.command], 6),
        ("重做", "redo:", "Z", [.command, .shift], 6),
        ("剪切", "cut:", "x", [.command], 7),
        ("复制", "copy:", "c", [.command], 8),
        ("粘贴", "paste:", "v", [.command], 9),
        ("全选", "selectAll:", "a", [.command], 0)
    ]

    let commands = editMenu.items.filter { !$0.isSeparatorItem }
    expect(commands.count == expected.count, "全局编辑菜单只提供六项标准文本命令")
    for command in expected {
        guard let item = commands.first(where: { $0.title == command.title }) else {
            expect(false, "全局编辑菜单包含\(command.title)")
            continue
        }
        expect(
            item.action.map(NSStringFromSelector) == command.action
                && item.keyEquivalent == command.key
                && item.keyEquivalentModifierMask == command.modifiers
                && item.target == nil,
            "\(command.title)使用标准快捷键与 nil-target 响应链"
        )
    }

    let probe = ApplicationEditCommandProbe()
    application.nextResponder = probe
    for command in expected {
        probe.receivedAction = ""
        let characters = command.modifiers.contains(.shift)
            ? command.key.uppercased()
            : command.key
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: command.modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: command.key,
            isARepeat: false,
            keyCode: command.keyCode
        )!
        expect(
            application.mainMenu?.performKeyEquivalent(with: event) == true
                && probe.receivedAction == command.action,
            "\(command.title)经真实 NSMenu key equivalent 分发到当前第一响应链"
        )
    }
}
