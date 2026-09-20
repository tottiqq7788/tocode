import AppKit

enum UserManual {
    struct Page: Equatable {
        let title: String
        let body: String
    }

    static let pages: [Page] = [
        Page(title: "入门", body: """
        Tocode 是菜单栏里的本机文件与系统助手，没有主窗口。

        • 左键图标：打开当前根目录的目录树。
        • 右键图标：打开功能菜单（访达、目录、codex、mac、微信、设置、退出）。

        根目录保存在本机。从未设置过时默认为「文稿」目录；路径失效时也会回到该默认位置。

        多数开关默认关闭。键盘映射、触控板和部分快捷键需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Tocode。访达相关操作可能还需要允许控制访达。
        """),
        Page(title: "目录树", body: """
        左键打开目录树后，悬停文件夹即可展开下级。未按修饰键时，点击文件或文件夹会把绝对路径以「路径」形式复制到剪贴板。

        每个文件夹菜单底部都有「新增」：可新建文件夹，或按常见格式新建空文件（txt / md / csv / json / docx / xlsx / pptx / pdf）。重名不会覆盖。

        按住 Option：进入删除模式。「新增」变成「清空」；点击条目改为删除。删除和清空都会先确认，然后移入废纸篓，可以恢复。

        按住 Command：进入访问模式。「新增」变成「访问」。点「访问」或文件夹会用访达打开该文件夹；点文件则用默认应用打开。

        同时按住 Option 和 Command 时，以删除模式为准。松开修饰键后恢复复制路径。
        """),
        Page(title: "访达与目录", body: """
        右键 → 访达
        • 访问路径：在访达中打开当前左键根目录。
        • 复制路径：复制访达当前选中的那一个文件或文件夹本身的路径。
        • 目录初始化：仅当访达恰好选中一项时出现。选中文件夹则把它设为根目录；选中文件则设为其父文件夹。
        • 显示/隐藏隐藏文件：与访达共用同一偏好。在访达里按 ⌘⇧. 后，下次打开 Tocode 菜单会跟着变。

        右键 → 目录
        • 读取剪贴板：若剪贴板是存在的文件夹路径，则设为根目录。以「」包裹的复制路径不会被当成设根。
        • 更改目录：弹出系统选择器。
        • 重置初始目录：回到默认根目录。

        右键 → codex
        • 显示当前 Codex 本地项目名称与根目录。
        • 同步项目夹（默认关）：开启后左键目录树跟随 Codex 当前项目；「读取剪贴板 / 更改目录 / 重置 / 访达目录初始化」会置灰。只读 Codex 状态，绝不写回。
        """),
        Page(title: "mac", body: """
        右键 → mac → 临时黑屏
        每个屏幕盖一层纯黑窗口，按任意键或鼠标键解除。不需要辅助功能权限，也不保存开关。

        右键 → mac → 触控板
        可为三指 / 四指 / 五指轻点各绑一个目标：映射一个快捷键，或映射一个 Tocode 功能。只有短促、几乎不移动、指数量准确的轻点才会触发。滑动和长按不会触发。

        右键 → mac → 键盘
        用「新增」添加规则：名称、源快捷键、目标（再映射一个快捷键，或映射一个功能）。命中源时吞掉原按键，只执行一次。没有规则时不安装键盘钩子。

        可映射的功能包括：向左/向右切换桌面、访问路径、复制路径、目录初始化、隐藏文件、x/v 移动、⌘Q 强关访达、读剪贴板、重置根目录、同步项目夹、微信文件位置、临时黑屏、滚轮对调、双击 ⌘Q、开机自启、退出。不能映射需要弹窗录入的项（更改目录、绑微信、密钥、触控板/键盘配置、模型切换）。

        桌面切换依赖系统「调度中心」里向左/向右移动空间的快捷键处于开启。Tocode 不会改这项系统偏好。

        右键 → mac 里还可打开双击 ⌘Q，以及对调垂直/横向滚轮（只影响物理鼠标滚轮，不影响触控板）。
        """),
        Page(title: "微信", body: """
        右键 → 微信关联 → 绑定微信：用有 iLink Bot 资格的个人微信扫码。绑定后会自动接收发给该 Bot 的新消息。

        普通消息只归档、不回复、不调用模型。归档目录是本机「文稿/wechat」，按日期写成 wechat日期.md；点「文件位置」可在访达打开。

        以英文句点开头的消息是命令，例如 .help、.status、.blackout（别名 .lshp）。命令不写入归档；结果会回复到原会话。

        不以句点开头、但整条都能拆成 {按键} 或 “文字” 的，是快捷输入。例如 {space}、{cmd+space}、“你好”、“你好”{enter}。会按段注入按键或文字，成功或失败都回复原会话，也不归档。

        终端里可以用 tocode wechat send 发文字、图片或附件到最近一条入站会话；--to 只能指定曾经来过的用户。出站内容不写入归档。
        """),
        Page(title: "命令行", body: """
        应用启动后会把 tocode 安装到 ~/.local/bin/tocode。常驻进程必须在运行，命令才会执行（help / commands 除外）。

        常用：
        tocode help
        tocode status
        tocode root get|set|choose|reset|init-from-finder
        tocode codex status|sync|model
        tocode wechat status|bind|location|send
        tocode blackout
        tocode login on|off|toggle
        tocode wheel vertical|horizontal on|off|toggle
        tocode hidden on|off|toggle
        tocode shortcut finder-move|double-cmdq|finder-cmdq on|off|toggle
        tocode quit

        开关类命令的 on / off / toggle 可以互换。每条命令都会返回结果，不会静默执行。不会执行任意 shell。
        """),
        Page(title: "设置", body: """
        右键 → 设置
        • 开机自启：随系统登录启动 Tocode。菜单显示的是系统里的真实状态。
        • 导出配置 / 导入配置：生成或读入 .tocode 文件。只含键盘映射、触控板、快捷键开关和滚轮。导入前会确认，确认后整段覆盖这些项。根目录、开机自启、同步项目夹、拓展设置、微信凭据和密钥不会进出该文件。
        • 说明书：就是本窗口。
        • 拓展设置 → AK（默认关）：勾选后才出现 codex 模型切换，以及设置里的 AK密钥。关闭只隐藏入口，不删除已保存密钥。

        访达子菜单里的 x/v 移动文件、⌘Q 强关访达，以及 mac 里的双击 ⌘Q，也都是默认关闭的开关。
        • x/v：只在访达前台把 ⌘X/⌘V 变成「剪切后粘贴即移动」，目标是访达当前窗口，不是 Tocode 根目录。
        • 双击 ⌘Q：第一次按下只提示，2 秒内再按一次才退出当前应用。
        • ⌘Q 强关访达：关闭访达窗口并隐藏访达，不退出访达进程。

        配置写在固定偏好域，重建应用不应再丢开关和映射。
        """)
    ]

    @MainActor
    static func present() {
        UserManualWindowController.present()
    }
}

@MainActor
private final class UserManualWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "说明书"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
    }

    static func present() {
        let controller = UserManualWindowController()
        guard let window = controller.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        _ = withExtendedLifetime(controller) {
            NSApp.runModal(for: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    @objc private func closeManual() {
        window?.close()
    }

    private func makeContent() -> NSView {
        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for page in UserManual.pages {
            let item = NSTabViewItem()
            item.label = page.title
            item.view = makePageView(body: page.body)
            tabView.addTabViewItem(item)
        }

        let close = NSButton(title: "关闭", target: self, action: #selector(closeManual))
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        root.autoresizingMask = [.width, .height]
        root.addSubview(tabView)
        root.addSubview(close)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            close.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        return root
    }

    private func makePageView(body: String) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 13)
        text.string = body
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text

        let box = NSView()
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)
        ])
        return box
    }
}
