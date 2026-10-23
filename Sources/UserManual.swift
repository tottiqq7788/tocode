import AppKit

enum UserManual {
    static let menuTitle = "说明书"

    struct Page: Equatable {
        let title: String
        let body: String
    }

    static let pages: [Page] = [
        Page(title: "入门", body: """
        Tocode 是菜单栏里的本机文件与系统助手，没有主窗口。

        • 左键图标：打开当前根目录的目录树（可悬停展开；根菜单有「历史」「配置」「终端」与「新增」）。
        • 按住 totti 再左键点图标：按桌面切换窗口。空格修饰键开启并正在按住 totti 时，左键不再打开目录树。只有一个显示器时直接列出桌面；多个显示器时先按显示器分组。普通桌面是夹，带向右箭头。点击桌面夹这一行就切到该桌面。悬停桌面夹列出其中看得到的窗口，点窗口会先进入该桌面，再把该窗口带到前台。没有切到该桌面时，不会把窗口显示到当前桌面。完全透明的窗口不列出。已撤出显示的窗口不列出。全屏空间不是夹，没有向右箭头，也不展开窗口，标题用调度中心里的应用名，点击这一行就进入该全屏空间。不改固定根。
        • 右键图标：打开功能菜单（访达、输入、工具、模型、微信、设置、退出）。

        根目录保存在本机。从未设置过时默认为当前用户的「文稿」目录；已保存路径不存在时，会把固定根改写成该文稿目录。文稿目录本身也不存在时，改写为用户主目录，不再保留失效路径。左键实际展示根默认是该固定目录；仅当前台是访达且「访达跟随」开、前台是 Codex 且「codex跟随」开、前台是 Hermes 且「hermes跟随」开，或「终端跟随」开且前台是本次运行中由「终端」打开且仍在最前的系统终端窗口时，才临时改用对应目录。

        多数开关默认关闭。键盘映射、触控板和部分快捷键需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Tocode。访达相关操作可能还需要允许控制访达。
        """),
        Page(title: "目录树", body: """
        左键图标打开目录树时，始终从当前解析根的第一层开始，不会整页跳到别处。悬停文件夹可继续展开下级。

        根菜单底部结构是：分隔线 →「历史」→「配置」→「终端」→「新增」。子文件夹菜单底部只有「新增」，没有「历史」、「配置」和「终端」。

        未按修饰键时，点击文件或文件夹会把绝对路径以「路径」形式（全角括号包裹）复制到剪贴板，菜单随后关闭。

        「历史」记住你上次点击过的文件或文件夹（普通复制、Shift 多选、删除、访问，以及新增成功都会更新；只悬停展开不会更新）。悬停「历史」会展开该条目所在目录的同级文件与文件夹，便于快速回去继续索引。还没有点击过、记忆不在当前根下、或父目录已不存在时，「历史」不可用。

        「终端」用系统「终端」新开一个窗口，工作目录就是这次左键展示的根（跟随访达或 Codex 时用那个临时目录），并记住这个窗口和当时的目录。是否用这条记录改左键目录，由「配置」里的「终端跟随」决定。开关关闭时，即使这个窗口正在最前，仍用固定根。开关打开后，只有这个窗口正在最前时，展示根才临时改用当时记住的目录；该窗口不在最前，或前台不是系统「终端」时，这次跟随不起作用。窗口里再进入其它目录，菜单仍用打开时的目录。按住 Option 或 Command 时它仍是「终端」。点击它不会写入「历史」，也不会改掉已保存的固定根。

        「配置」夹提供：
        • 复制路径：复制访达当前选中的那一个文件或文件夹本身的路径。
        • 读取剪贴板 / 更改目录 / 重置初始目录：维护固定根；跟随开关开启时也不置灰。
        • 访达跟随（默认关）：仅当前台是访达且恰好选中一项时，左键树临时跟该文件夹（文件则跟其父文件夹）；否则仍用固定根。不写回固定根偏好。
        • 终端跟随（默认关）：仅当前台是系统「终端」，且最前面的窗口是本次运行中由「终端」打开、原标签仍在、当时的目录仍存在时，左键树临时用打开时的目录。关闭时打开终端仍会记下窗口，但左键不跟随。不写回固定根偏好。
        • codex跟随（默认关）：仅当前台是 Codex 且能解析到项目根时，左键树临时跟该项目；否则仍用固定根。不写回固定根偏好。
        • hermes跟随（默认关）：仅当前台是 Hermes 桌面应用时，左键树临时跟当前打开的项目。点进某个项目（含自动发现的目录）后，按窗口上已经显示的项目名立即跟随，不等本地记录写盘；还在项目列表里时，跟当前会话所属项目的主目录，会话进入子文件夹也不改到更深层。没有这些信息时，才用该配置档案里记住的当前项目。侧边栏当前会话带关闭标记时，跟这一条会话所在的项目，不停在档案里记住的第一个项目。这条会话若只属于另一个档案，跟随那个档案，不被上一个档案的旧路由留下。点进另一个项目后，若留下的会话不在这个项目里，跟随新项目。没有旧的档案路由时，用当前打开的会话找到它所属的配置档案，再读那个档案；对不上才读默认档案。安装器在前台、没有可跟随目录时仍用固定根。不写回固定根偏好。

        按住 Shift 可连续点击多个条目：按点击顺序把多条「路径」一行一条写入剪贴板，且目录树保持打开。松开 Shift 后再普通点一次，仍只复制那一条并关闭菜单。Shift 多选只在普通复制模式下有效；按住 Option 或 Command 时仍是删除或访问。

        每个文件夹菜单底部都有「新增」：可新建文件夹，或按常见格式新建空文件（txt / md / csv / json / docx / xlsx / pptx / pdf）。重名不会覆盖。创建成功后会自动把新建项的「路径」复制到剪贴板；取消或失败则不改剪贴板。

        按住 Option：进入删除模式。「新增」变成「清空」；点击条目改为删除。删除和清空都会先确认，然后移入废纸篓，可以恢复。根菜单的「历史」、「配置」与「终端」仍在。

        按住 Command：进入访问模式。「新增」变成「访问」。点「访问」或文件夹会用访达打开该文件夹；点文件则用默认应用打开。根菜单的「历史」、「配置」与「终端」仍在。不再提供单独的「访问路径」菜单项。

        同时按住 Option 和 Command 时，以删除模式为准。松开修饰键后恢复复制路径。
        """),
        Page(title: "访达与目录", body: """
        右键 → 访达
        • 显示/隐藏隐藏文件：与访达共用同一偏好。在访达里按 ⌘⇧. 后，下次打开 Tocode 菜单会跟着变。
        • x/v移动文件、⌘Q强关访达：见「设置」页说明。

        设根与跟随改在左键 → 根目录，见「目录树」页。
        """),
        Page(title: "输入与工具", body: """
        右键 → 输入 → 触控板
        可为三指 / 四指 / 五指轻点各绑一个目标：映射一个快捷键，映射一个 Tocode 功能，或选择一个已保存的自动化。只有短促、几乎不移动、指数量准确的轻点才会触发。滑动和长按不会触发。

        右键 → 输入 → 键盘
        用「新增」添加规则：名称、源快捷键、目标（再映射一个快捷键，映射一个功能，或选择一个自动化）。命中源时吞掉原按键。映射成快捷键时，按住源键等于按住目标键；映射成功能、打开网址或自动化仍然只触发一次。没有规则时不安装键盘钩子。源快捷键可以是 totti 加另一个键。触发自动化时，会读取当前选中的文字，连同提示词调用模型，把结果写入剪贴板并粘贴回去。

        右键 → 输入 → 改键 → 空格修饰键（默认关）
        开启后，250 毫秒内单独点按空格仍输出空格；按住空格则作为内部修饰键 totti，可与其他键组成快捷键。长按不会先打出一个空格。已经按着 ⌘、⌃、⌥ 或 ⇧ 时，空格保持原样。totti 不占用 fn。键盘和触控板弹窗的按键监听都能识别 totti+键。可以把 totti+V 映射成 ⌃7，但不能把 totti 当作要发出去的目标快捷键。该开关不进入可分享配置，也不进入遥控。

        可映射的功能包括：向左/向右切换桌面、调度中心、应用程序窗口、显示桌面、Launchpad、访问路径、复制路径、访达跟随、隐藏文件、x/v 移动、⌘Q 强关访达、读剪贴板、重置根目录、codex跟随、微信文件位置、临时黑屏、取消黑屏、限制程序坞弹出、锁定屏幕、滚轮对调、双击 ⌘Q、开机自启、退出，以及「打开网址」。选中「打开网址」后在同一页填写地址；地址去掉空白后必须带协议，例如 https://、file:// 或 mailto:。触发后交给系统默认方式打开，打不开时会提示，规则仍保留。其余需要录入的项仍然不能映射（更改目录、绑微信、密钥、触控板/键盘配置、模型切换）。

        桌面切换依赖系统「调度中心」里向左/向右移动空间的快捷键处于开启；调度中心、应用程序窗口、显示桌面与 Launchpad 同样依赖系统对应快捷键。Tocode 不会改这些系统偏好。

        右键 → 输入里还可打开双击 ⌘Q，以及对调垂直/横向滚轮（只影响物理鼠标滚轮，不影响触控板）。

        右键 → 工具 → 定时器
        用「新增」添加任务：名称、时间（一次性或 cron）、事项（与键盘相同的快捷键、功能或自动化目录，含「打开网址」）。一次性用小时和分钟步进输入，默认 10 分钟；cron 填 5 段表达式，合法时显示下次执行时间。启动后菜单项打勾并显示距下次的剩余时间。一次性到点后变为未启动；cron 到点后保持勾选并排下次。「打开网址」到点后用系统默认方式打开，打不开时会提示，任务仍保留。自动化到点后同样读取当时选中的文字并粘贴结果。应用未运行时过点的一次性任务下次启动不会补执行；cron 会重算下次但仍不补跑已错过的那次。定时器不进入可分享配置，也不能映射到键盘/触控板；其中保存的网址同样不进入可分享配置。

        右键 → 工具 → 书签同步
        位于定时器下方。夹内有「远程同步」与「拓展安装」（Chrome、Edge、Firefox）。只同步书签。每个浏览器须手动加载扩展：菜单会登记本机通信主机、打开扩展目录，并提示到浏览器扩展页加载；不能静默安装。Chrome 与 Edge 加载后可保留；正式版 Firefox 未签名扩展重启后需再加载，未连上时会提示。本机各浏览器并入同一本按规范化网址去重的账本；初次与后加入按并集，不因某一边缺失而删除。加入完成后的删除会留下墓碑。「远程同步」可生成或粘贴同一把超长密钥；明文只进钥匙串，查看须 Touch ID 或设备密码。两台 Mac 输入同一密钥即绑定；中转只保存加密账本。书签账本与远程密钥不进入可分享配置、命令行或键盘映射。

        右键 → 工具 → 临时黑屏
        每个屏幕盖一层纯黑窗口，按任意键或鼠标键解除。不需要辅助功能权限，也不保存开关。

        右键 → 工具 → 限制程序坞弹出（默认关）
        勾选后，在系统已开启「自动隐藏和显示程序坞」时，鼠标悬停屏幕边缘也不会弹出程序坞；取消勾选后恢复。退出 Tocode 时会暂时恢复系统延迟，下次启动若仍勾选会再限制。该开关不进入可分享配置；可通过键盘/触控板映射翻转。
        """),
        Page(title: "模型中转", body: """
        右键顶层「模型」是本机 OpenAI-compatible 中转站，始终显示。Codex 使用的模型请用独立应用 Ancode 切换，不在本菜单内。

        服务随 Tocode 启动，只监听 127.0.0.1，默认端口 27800。菜单下为「状态」「端口」「厂家」「密钥」「自动化」。「状态」可查看当前 Base URL、按厂家下钻的调用次数折线图（近六小时/近一周/近一个月，默认最近使用的厂家），并打开当日调用明细日志文件；日志仅含元数据、次日覆盖，不含正文或密钥。「端口…」可改为 1024…65535；新端口不可用时不会偷偷换端口，并会尝试恢复原监听。

        「厂家 → 新增」创建由唯一名称、一个常见 OpenAI-compatible 预设或自定义 Base URL、一个上游 Key 组成的厂家实体。同一预设可用不同名称重复新增；选择「自定义…」时才输入地址。点击「测试连接」会用待保存 Key 请求 /models，成功取得非空模型列表后才能保存；失败不留下空厂家或钥匙串项。

        厂家名称是普通可点击项，不是文件夹。点击后直接打开与新增相同的编辑弹窗并回显信息，可保存、测试连接、刷新上游模型目录或确认删除。上游 Key 明文只进入 macOS 钥匙串且不回填；每个厂家只能有一个 Key。本地暴露的模型名直接取上游 model id，跨厂家冲突时系统自动加厂家前缀，不提供人工别名。

        「密钥 → 新增」只填唯一名称，随后自动生成随机本地访问 Key。点击已命名的密钥时，须通过本机 Touch ID 或设备密码验证后，才会把 Base URL、API Key 和当前可用模型复制到剪贴板；弹窗和通知不会展示明文。同一流程也可删除。旧版仍用查看密码加密的密钥，首次打开时需输入旧查看密码迁移一次，之后同样只走设备验证。

        「自动化 → 新增」填写唯一名称、提示词和当前可用模型。提示词在调用时作为系统提示，选中的文字作为用户输入。点击已有项可编辑或删除，删除不再次确认。键盘、触控板和定时器的目标里可以选择这些自动化。触发后读取选中文字，非流式调用所选模型，只把助手正文写入剪贴板并粘贴回当时的焦点。没有选中文字、模型不可用或正文为空时只提示，不粘贴。同一时间只执行一个。自动化的名称、提示词和模型名不进入 .tocode、遥控或命令行。指向自动化的键盘或触控板规则若被导出，只带走 ID。

        客户端可调用 GET /v1/models、POST /v1/chat/completions 和 POST /v1/responses，普通 JSON 与 SSE 都支持。请求必须用本地 Key 鉴权。模型名只路由到所属厂家及其唯一上游 Key；网络错误、401/403、429 或 5xx 会明确失败，不会切换同厂家其他 Key，流一旦开始也绝不拼接重试。每次入站 POST 记一次调用，不合并、不统计 token。

        中转配置和所有密钥都不会进入 .tocode、CLI、微信或通知，也不能当作键盘或触控板的功能项。上游 Key 在钥匙串；本地 Key 明文只在带设备验证的钥匙串里，元数据只保存鉴权摘要。调用元数据仅落在本机 Application Support 的 0600 文件。
        """),
        Page(title: "微信", body: """
        右键 → 微信 → 绑定微信：用有 iLink Bot 资格的个人微信扫码。绑定后会自动接收发给该 Bot 的新消息。

        收到的文字、图片和附件都只归档、不回复、不调用模型，也不识别命令或快捷输入。归档目录是本机「文稿/wechat」，按日期写成 wechat日期.md；点「文件位置」可在访达打开。

        终端里可以用 tocode wechat send 发文字、图片或附件到最近一条入站会话；--to 只能指定曾经来过的用户。出站内容不写入归档。
        """),
        Page(title: "命令行", body: """
        应用启动后会把 tocode 安装到 ~/.local/bin/tocode。常驻进程必须在运行，命令才会执行（help / commands 除外）。

        常用：
        tocode help
        tocode status
        tocode root get|set|choose|reset|finder-follow|clipboard|open
        tocode finder copy
        tocode codex status|sync|model
        tocode wechat status|bind|location|send
        tocode blackout
        tocode login on|off|toggle
        tocode wheel vertical|horizontal on|off|toggle
        tocode hidden on|off|toggle
        tocode shortcut finder-move|double-cmdq|finder-cmdq on|off|toggle
        tocode quit

        root clipboard：剪贴板是不带「」的现有文件夹路径时设为固定根。
        root open：在访达打开固定根（不是访达/Codex 跟随后的展示根）。
        finder copy：复制访达当前恰好选中的那一项绝对路径。

        开关类命令的 on / off / toggle 可以互换。每条命令都会返回结果，不会静默执行。不会执行任意 shell。
        """),
        Page(title: "设置", body: """
        右键 → 设置
        • 开机自启：随系统登录启动 Tocode。菜单显示的是系统里的真实状态。
        • 应用 → 绑定密钥：先设置本机绑定密钥（至少 8 个字符）。明文只进钥匙串，查看或管理时须通过 Touch ID 或设备密码。未设置时不能「绑定应用」。手机扫码后还要输入此密钥才能绑定成功；二维码本身不含密钥。更换密钥不影响已有关联。
        • 应用 → 绑定应用：生成只含中转地址和配对码的二维码，供安卓扫码绑定。须先设好绑定密钥。
        • 应用 → 网关链接（默认关）：打开后启动本机 Hermes 网关，手机才能连上 Hermes。图标打勾表示网关正在运行；转圈表示正在启动；感叹号表示连续失败后已停住。退出 Tocode 或再点一次会关掉网关，包括别处已经启动的网关。没装 Hermes 时这一项是灰的。第一次打开若缺少 API Server 配置，只补缺失项，不改已有配置。这个开关不进入 .tocode。
        • 手机上的档案和项目：在手机顶栏切换，只列出已经存在的 Hermes 档案，手机不能新建档案。切档案不重启网关，只补该档案缺失的 API Server 配置。新建项目时在手机上从这台 Mac 的主目录往下选文件夹，Mac 会再检查一遍。目录页显示当前项目的文件夹。这些选择不进入 .tocode。
        • 配置 → 导出配置 / 导入配置：生成或读入 .tocode 文件。只含键盘映射、触控板、快捷键开关和滚轮。导入前会确认，确认后整段覆盖这些项。根目录、开机自启、访达跟随、终端跟随、codex跟随、hermes跟随、空格修饰键、微信凭据、本地模型中转配置、模型自动化和所有密钥不会进出该文件。含 totti 的键盘映射仍会随键盘映射进出。指向自动化的映射只带走 ID，不带走提示词或模型名。
        • Codex 模型切换已迁至独立应用 Ancode；本应用右键不再提供模型切换入口。右键不再提供密钥入口。
        • 说明书：就是本窗口，位于设置夹最底部。

        访达子菜单里的 x/v 移动文件、⌘Q 强关访达，以及输入里的双击 ⌘Q，也都是默认关闭的开关。
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
        window.title = UserManual.menuTitle
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
