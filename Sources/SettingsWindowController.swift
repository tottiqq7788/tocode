import AppKit

struct SettingsLabeledID: Equatable {
    var id: UUID
    var title: String
    var detail: String
}

@MainActor
protocol SettingsHosting: AnyObject {
    var settingsRootPath: String { get }
    var settingsFinderFollow: Bool { get }
    var settingsTerminalFollow: Bool { get }
    var settingsCodexFollow: Bool { get }
    var settingsHermesFollow: Bool { get }
    var settingsShowHidden: Bool { get }
    var settingsFinderMove: Bool { get }
    var settingsFinderCommandQ: Bool { get }
    var settingsDoubleCommandQ: Bool { get }
    var settingsVerticalWheel: Bool { get }
    var settingsHorizontalWheel: Bool { get }
    var settingsSpaceModifier: Bool { get }
    var settingsDockRestrict: Bool { get }
    var settingsFolderIconVisible: Bool { get }
    var settingsWindowsIconVisible: Bool { get }
    var settingsFolderIconSymbol: String { get }
    var settingsWindowsIconSymbol: String { get }
    var settingsFolderLeftClick: StatusItemPrimaryClick { get }
    var settingsFolderRightClick: StatusItemPrimaryClick { get }
    var settingsWindowsLeftClick: StatusItemPrimaryClick { get }
    var settingsWindowsRightClick: StatusItemPrimaryClick { get }
    var settingsLaunchAtLogin: Bool { get }
    var settingsHermesInstalled: Bool { get }
    var settingsHermesGatewayOn: Bool { get }
    var settingsHermesGatewayDetail: String { get }
    var settingsBindingKeySet: Bool { get }
    var settingsAppAssociated: Bool { get }
    var settingsWeChatBound: Bool { get }
    var settingsModelSummary: String { get }
    var settingsModelFailed: Bool { get }
    var settingsKeyboardMappings: [SettingsLabeledID] { get }
    var settingsTrackpadRows: [(gesture: TrackpadTapGesture, detail: String)] { get }
    var settingsRemoteButtons: [SettingsLabeledID] { get }
    var settingsTimers: [SettingsLabeledID] { get }
    var settingsProviders: [SettingsLabeledID] { get }
    var settingsLocalKeys: [SettingsLabeledID] { get }
    var settingsAutomations: [SettingsLabeledID] { get }
    var settingsBookmarkBackups: [String] { get }
    var settingsBookmarkBrowsers: [(browser: BookmarkBrowser, online: Bool)] { get }

    func settingsSetFinderFollow(_ on: Bool)
    func settingsSetTerminalFollow(_ on: Bool)
    func settingsSetCodexFollow(_ on: Bool)
    func settingsSetHermesFollow(_ on: Bool)
    func settingsSetShowHidden(_ on: Bool)
    func settingsSetFinderMove(_ on: Bool)
    func settingsSetFinderCommandQ(_ on: Bool)
    func settingsSetDoubleCommandQ(_ on: Bool)
    func settingsSetVerticalWheel(_ on: Bool)
    func settingsSetHorizontalWheel(_ on: Bool)
    func settingsSetSpaceModifier(_ on: Bool)
    func settingsSetDockRestrict(_ on: Bool)
    func settingsSetFolderIconVisible(_ on: Bool)
    func settingsSetWindowsIconVisible(_ on: Bool)
    func settingsSetFolderIconSymbol(_ symbol: String)
    func settingsSetWindowsIconSymbol(_ symbol: String)
    func settingsSetFolderLeftClick(_ menu: StatusItemPrimaryClick)
    func settingsSetFolderRightClick(_ menu: StatusItemPrimaryClick)
    func settingsSetWindowsLeftClick(_ menu: StatusItemPrimaryClick)
    func settingsSetWindowsRightClick(_ menu: StatusItemPrimaryClick)
    func settingsSetLaunchAtLogin(_ on: Bool)
    func settingsSetHermesGateway(_ on: Bool)

    func settingsChooseRoot()
    func settingsReadClipboard()
    func settingsResetRoot()
    func settingsCreateKeyboard()
    func settingsEditKeyboard(id: UUID)
    func settingsEditTrackpad(_ gesture: TrackpadTapGesture)
    func settingsCreateRemoteButton()
    func settingsEditRemoteButton(id: UUID)
    func settingsCreateTimer()
    func settingsEditTimer(id: UUID)
    func settingsOpenBookmarkLog()
    func settingsConfigureBookmarkRemote()
    func settingsBackupBookmarksNow()
    func settingsRestoreBookmark(day: String)
    func settingsInstallBookmark(_ browser: BookmarkBrowser)
    func settingsShowModelStatus()
    func settingsChangeModelPort()
    func settingsRestartModel()
    func settingsAddProvider()
    func settingsEditProvider(id: UUID)
    func settingsAddLocalKey()
    func settingsAccessLocalKey(id: UUID)
    func settingsCreateAutomation()
    func settingsEditAutomation(id: UUID)
    func settingsManageBindingKey()
    func settingsOpenRemoteAssociation()
    var settingsMenuTracking: Bool { get }
    func settingsSetMenuTracking(_ on: Bool)
    func settingsOpenDiagnostics()
    func settingsBindWeChat()
    func settingsOpenWeChatLocation()
    func settingsExport()
    func settingsImport()
    func settingsShowManual()
    func settingsQuit()
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var host: SettingsHosting?
    private let sidebar = NSTableView()
    private let tabs = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let form = SettingsFormView()
    private var page: SettingsPage = .path
    private var selectedSection: [SettingsPage: String] = [:]
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var suppressSelection = false
    private var suppressTab = false
    private var restoreScrollOrigin: NSPoint?

    init(host: SettingsHosting) {
        self.host = host
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tocode"
        window.subtitle = "设置"
        window.minSize = NSSize(width: 780, height: 480)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.toolbar = NSToolbar(identifier: "tocode.settings")
        super.init(window: window)
        window.delegate = self
        let split = makeSplit()
        split.preferredContentSize = NSSize(width: 920, height: 620)
        window.contentViewController = split
        window.setFrameAutosaveName("tocode.settings.window")
        let designed = NSRect(x: 0, y: 0, width: 920, height: 620)
        if window.frame.width < 900 || window.frame.height < 580 || window.frame.origin == .zero {
            window.setFrame(designed, display: false)
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reveal(page: SettingsPage, timerID: UUID? = nil) {
        self.page = page
        if timerID != nil {
            selectedSection[.tools] = "timers"
        }
        sidebar.reloadData()
        suppressSelection = true
        sidebar.selectRowIndexes(IndexSet(integer: page.rawValue), byExtendingSelection: false)
        suppressSelection = false
        reloadForm(resetScroll: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let timerID {
            host?.settingsEditTimer(id: timerID)
            reloadForm()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    private func makeSplit() -> NSSplitViewController {
        let sidebarController = NSViewController()
        sidebarController.view = makeSidebar()
        let contentController = NSViewController()
        contentController.view = makeContent()
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 196
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 520
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "tocode.settings.split"
        return split
    }

    private func makeSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 160
        column.width = 196
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.rowHeight = 32
        sidebar.style = .sourceList
        sidebar.selectionHighlightStyle = .regular
        sidebar.backgroundColor = .clear
        sidebar.focusRingType = .none
        sidebar.rowSizeStyle = .default
        sidebar.intercellSpacing = NSSize(width: 0, height: 0)
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.allowsEmptySelection = false
        sidebar.allowsColumnReordering = false
        sidebar.allowsColumnResizing = false
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = sidebar
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeContent() -> NSView {
        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            tabs.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPage.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = SettingsPage.allCases[row]
        let identifier = NSUserInterfaceItemIdentifier("settings.page")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? SettingsSidebarCell(identifier: identifier)
        cell.textField?.stringValue = page.title
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        cell.imageView?.image = NSImage(
            systemSymbolName: page.symbolName,
            accessibilityDescription: page.title
        )?.withSymbolConfiguration(config)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = sidebar.selectedRow
        guard SettingsPage.allCases.indices.contains(row) else { return }
        page = SettingsPage.allCases[row]
        reloadForm(resetScroll: true)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard !suppressTab else { return }
        let sections = page.sections
        let index = sender.selectedSegment
        guard sections.indices.contains(index) else { return }
        selectedSection[page] = sections[index].id
        reloadForm(resetScroll: true)
    }

    private func reloadForm(resetScroll: Bool = false) {
        actions.removeAll()
        syncTabControl()
        form.setRows(rows(for: page))
        if resetScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func syncTabControl() {
        let sections = page.sections
        suppressTab = true
        defer { suppressTab = false }
        if tabs.segmentCount != sections.count {
            tabs.segmentCount = sections.count
        }
        for (index, section) in sections.enumerated() {
            tabs.setLabel(section.title, forSegment: index)
        }
        let id = currentSectionID()
        selectedSection[page] = id
        tabs.selectedSegment = sections.firstIndex { $0.id == id } ?? 0
    }

    private func currentSectionID() -> String {
        let sections = page.sections
        if let stored = selectedSection[page], sections.contains(where: { $0.id == stored }) {
            return stored
        }
        return sections[0].id
    }

    private func rows(for page: SettingsPage) -> [NSView] {
        guard let host else { return [] }
        switch (page, currentSectionID()) {
        case (.menubar, "folder"):
            return folderIconRows(host)
        case (.menubar, "windows"):
            return windowsIconRows(host)
        case (.path, "root"):
            return pathRootRows(host)
        case (.path, "follow"):
            return pathFollowRows(host)
        case (.path, "finder"):
            return pathFinderRows(host)
        case (.input, "keyboard"):
            return keyboardRows(host)
        case (.input, "trackpad"):
            return trackpadRows(host)
        case (.input, "remote"):
            return remoteRows(host)
        case (.input, "remap"):
            return remapRows(host)
        case (.tools, "timers"):
            return timerRows(host)
        case (.tools, "bookmarks"):
            return bookmarkRows(host)
        case (.tools, "extensions"):
            return extensionRows(host)
        case (.tools, "dock"):
            return dockRows(host)
        case (.model, "status"):
            return modelStatusRows(host)
        case (.model, "providers"):
            return providerRows(host)
        case (.model, "keys"):
            return localKeyRows(host)
        case (.model, "automations"):
            return automationRows(host)
        case (.connection, "app"):
            return connectionAppRows(host)
        case (.connection, "wechat"):
            return wechatRows(host)
        case (.general, "startup"):
            return startupRows(host)
        case (.general, "config"):
            return configRows(host)
        case (.general, "about"):
            return aboutRows(host)
        default:
            return []
        }
    }

    private func folderIconRows(_ host: SettingsHosting) -> [NSView] {
        iconRows(
            visible: host.settingsFolderIconVisible,
            visibleKey: "folderIcon",
            symbol: host.settingsFolderIconSymbol,
            styles: StatusBarIconCatalog.styles(for: .folder),
            left: host.settingsFolderLeftClick,
            right: host.settingsFolderRightClick,
            setLeft: { host.settingsSetFolderLeftClick($0) },
            setRight: { host.settingsSetFolderRightClick($0) },
            apply: { host.settingsSetFolderIconSymbol($0) }
        )
    }

    private func windowsIconRows(_ host: SettingsHosting) -> [NSView] {
        iconRows(
            visible: host.settingsWindowsIconVisible,
            visibleKey: "windowsIcon",
            symbol: host.settingsWindowsIconSymbol,
            styles: StatusBarIconCatalog.styles(for: .windows),
            left: host.settingsWindowsLeftClick,
            right: host.settingsWindowsRightClick,
            setLeft: { host.settingsSetWindowsLeftClick($0) },
            setRight: { host.settingsSetWindowsRightClick($0) },
            apply: { host.settingsSetWindowsIconSymbol($0) }
        )
    }

    private func iconRows(
        visible: Bool,
        visibleKey: String,
        symbol: String,
        styles: [StatusBarIconStyle],
        left: StatusItemPrimaryClick,
        right: StatusItemPrimaryClick,
        setLeft: @escaping (StatusItemPrimaryClick) -> Void,
        setRight: @escaping (StatusItemPrimaryClick) -> Void,
        apply: @escaping (String) -> Void
    ) -> [NSView] {
        [
            toggle("在菜单栏显示", on: visible, key: visibleKey),
            menuPopupRow("左键", selected: left, apply: setLeft),
            menuPopupRow("右键", selected: right, apply: setRight),
            footnote("左键是\(left.menuTitle)，右键是\(right.menuTitle)。左右键可以选同一个菜单。"),
            footnote("两个图标都关掉时，从程序坞打开设置再打开。"),
            footnote("图标样式"),
            symbolGrid(styles: styles, selected: symbol, apply: apply),
        ]
    }

    private func menuPopupRow(
        _ title: String,
        selected: StatusItemPrimaryClick,
        apply: @escaping (StatusItemPrimaryClick) -> Void
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let popup = NSPopUpButton()
        popup.controlSize = .regular
        for menu in StatusItemPrimaryClick.assignable {
            popup.addItem(withTitle: menu.menuTitle)
            popup.lastItem?.representedObject = menu.rawValue
        }
        popup.selectItem(withTitle: selected.menuTitle)
        popup.target = self
        popup.action = #selector(runControl(_:))
        actions[ObjectIdentifier(popup)] = { [weak popup] in
            guard
                let raw = popup?.selectedItem?.representedObject as? String,
                let menu = StatusItemPrimaryClick(rawValue: raw)
            else { return }
            apply(menu)
        }
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return row
    }

    private func pathRootRows(_ host: SettingsHosting) -> [NSView] {
        [
            footnote("当前固定根"),
            pathLabel(host.settingsRootPath),
            buttonRow([
                button("更改目录") { host.settingsChooseRoot() },
                button("读取剪贴板") { host.settingsReadClipboard() },
                button("重置初始目录") { host.settingsResetRoot() },
            ]),
        ]
    }

    private func pathFollowRows(_ host: SettingsHosting) -> [NSView] {
        [
            toggle("访达跟随", on: host.settingsFinderFollow, key: "finderFollow"),
            toggle("终端跟随", on: host.settingsTerminalFollow, key: "terminalFollow"),
            toggle("codex跟随", on: host.settingsCodexFollow, key: "codexFollow"),
            toggle("hermes跟随", on: host.settingsHermesFollow, key: "hermesFollow"),
            footnote("跟随只在对应应用处于前台时临时改目录树，不写回固定根。"),
        ]
    }

    private func pathFinderRows(_ host: SettingsHosting) -> [NSView] {
        [
            toggle(
                host.settingsShowHidden ? "隐藏隐藏文件" : "显示隐藏文件",
                on: host.settingsShowHidden,
                key: "hidden"
            ),
            toggle("x/v移动文件", on: host.settingsFinderMove, key: "finderMove"),
            toggle("⌘Q强关访达", on: host.settingsFinderCommandQ, key: "finderCmdQ"),
        ]
    }

    private func keyboardRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增映射") { host.settingsCreateKeyboard() },
        ]
        if host.settingsKeyboardMappings.isEmpty {
            rows.append(footnote("还没有键盘映射。"))
        } else {
            for item in host.settingsKeyboardMappings {
                rows.append(listRow(item.title, detail: item.detail) {
                    host.settingsEditKeyboard(id: item.id)
                })
            }
        }
        return rows
    }

    private func trackpadRows(_ host: SettingsHosting) -> [NSView] {
        host.settingsTrackpadRows.map { row in
            listRow(row.gesture.title, detail: row.detail.isEmpty ? "未设置" : row.detail) {
                host.settingsEditTrackpad(row.gesture)
            }
        }
    }

    private func remoteRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增按钮") { host.settingsCreateRemoteButton() },
        ]
        if host.settingsRemoteButtons.isEmpty {
            rows.append(footnote("还没有遥控按钮。手机映射页只会列出这里保存的按钮。"))
        } else {
            for item in host.settingsRemoteButtons {
                rows.append(listRow(item.title, detail: item.detail) {
                    host.settingsEditRemoteButton(id: item.id)
                })
            }
        }
        return rows
    }

    private func remapRows(_ host: SettingsHosting) -> [NSView] {
        [
            toggle("空格修饰键", on: host.settingsSpaceModifier, key: "space"),
            footnote("开启后按住空格成为 totti，只用于快捷键。不再用来切换菜单栏图标。"),
            toggle("对调垂直滚轮", on: host.settingsVerticalWheel, key: "wheelV"),
            toggle("对调横向滚轮", on: host.settingsHorizontalWheel, key: "wheelH"),
            toggle("双击⌘Q", on: host.settingsDoubleCommandQ, key: "doubleQ"),
        ]
    }

    private func timerRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增定时器") { host.settingsCreateTimer() },
        ]
        if host.settingsTimers.isEmpty {
            rows.append(footnote("还没有定时器。"))
        } else {
            for item in host.settingsTimers {
                rows.append(listRow(item.title, detail: item.detail) {
                    host.settingsEditTimer(id: item.id)
                })
            }
        }
        return rows
    }

    private func bookmarkRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            footnote("文件夹图标的右键只打开书签。同步和密钥在这里，浏览器扩展在「扩展」。"),
            buttonRow([
                button("同步日志") { host.settingsOpenBookmarkLog() },
                button("远程同步") { host.settingsConfigureBookmarkRemote() },
                button("立即备份") { host.settingsBackupBookmarksNow() },
            ]),
        ]
        if host.settingsBookmarkBackups.isEmpty {
            rows.append(footnote("还没有可还原的备份。"))
        } else {
            for day in host.settingsBookmarkBackups {
                rows.append(listRow(day, detail: "整本覆盖正式账本", actionTitle: "还原") {
                    host.settingsRestoreBookmark(day: day)
                })
            }
        }
        return rows
    }

    private func extensionRows(_ host: SettingsHosting) -> [NSView] {
        host.settingsBookmarkBrowsers.map { browser in
            let detail = browser.online ? "已在线" : "未在线"
            return listRow(browser.browser.title, detail: detail, actionTitle: "安装") {
                host.settingsInstallBookmark(browser.browser)
            }
        }
    }

    private func dockRows(_ host: SettingsHosting) -> [NSView] {
        [
            toggle("限制程序坞弹出", on: host.settingsDockRestrict, key: "dock"),
            footnote("只在系统已开启「自动隐藏和显示程序坞」时生效。"),
        ]
    }

    private func modelStatusRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            footnote(host.settingsModelSummary),
            buttonRow([
                button("状态") { host.settingsShowModelStatus() },
                button("端口…") { host.settingsChangeModelPort() },
            ]),
        ]
        if host.settingsModelFailed {
            rows.append(button("重新启动") { host.settingsRestartModel() })
        }
        return rows
    }

    private func providerRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增厂家") { host.settingsAddProvider() },
        ]
        if host.settingsProviders.isEmpty {
            rows.append(footnote("还没有厂家。"))
        } else {
            for item in host.settingsProviders {
                rows.append(listRow(item.title, detail: item.detail) {
                    host.settingsEditProvider(id: item.id)
                })
            }
        }
        return rows
    }

    private func localKeyRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增密钥") { host.settingsAddLocalKey() },
        ]
        if host.settingsLocalKeys.isEmpty {
            rows.append(footnote("还没有本地访问密钥。"))
        } else {
            for item in host.settingsLocalKeys {
                rows.append(listRow(item.title, detail: "查看或删除") {
                    host.settingsAccessLocalKey(id: item.id)
                })
            }
        }
        return rows
    }

    private func automationRows(_ host: SettingsHosting) -> [NSView] {
        var rows: [NSView] = [
            button("新增自动化") { host.settingsCreateAutomation() },
        ]
        if host.settingsAutomations.isEmpty {
            rows.append(footnote("还没有自动化。键盘、触控板和定时器仍可在编辑时选择已有项。"))
        } else {
            for item in host.settingsAutomations {
                rows.append(listRow(item.title, detail: item.detail) {
                    host.settingsEditAutomation(id: item.id)
                })
            }
        }
        return rows
    }

    private func connectionAppRows(_ host: SettingsHosting) -> [NSView] {
        [
            button(host.settingsBindingKeySet ? "管理绑定密钥" : "设置绑定密钥") {
                host.settingsManageBindingKey()
            },
            button(host.settingsAppAssociated ? "绑定应用（已关联）" : "绑定应用") {
                host.settingsOpenRemoteAssociation()
            },
            toggle(
                "网关链接",
                on: host.settingsHermesGatewayOn,
                key: "gateway",
                enabled: host.settingsHermesInstalled
            ),
            footnote(host.settingsHermesGatewayDetail),
            toggle("记录菜单跟踪", on: host.settingsMenuTracking, key: "menuTracking"),
            footnote("默认关闭。打开后只记录菜单展开和关闭的时机，不记录名称、网址或路径。"),
            button("打开诊断日志") { host.settingsOpenDiagnostics() },
        ]
    }

    private func wechatRows(_ host: SettingsHosting) -> [NSView] {
        [
            button(host.settingsWeChatBound ? "重新绑定微信" : "绑定微信") {
                host.settingsBindWeChat()
            },
            button("打开文件位置") { host.settingsOpenWeChatLocation() },
            footnote("一次性动作菜单也可以直接打开归档目录，默认是窗口图标右键。"),
        ]
    }

    private func startupRows(_ host: SettingsHosting) -> [NSView] {
        [
            toggle("开机自启", on: host.settingsLaunchAtLogin, key: "login"),
            footnote("显示的是系统登录项里的实际状态。"),
        ]
    }

    private func configRows(_ host: SettingsHosting) -> [NSView] {
        [
            buttonRow([
                button("导出配置") { host.settingsExport() },
                button("导入配置") { host.settingsImport() },
            ]),
            footnote("只含键盘映射、触控板、快捷键开关和滚轮。导入前会确认。"),
        ]
    }

    private func aboutRows(_ host: SettingsHosting) -> [NSView] {
        [
            button("说明书") { host.settingsShowManual() },
            quitButton(host),
        ]
    }

    private func symbolGrid(
        styles: [StatusBarIconStyle],
        selected: String,
        apply: @escaping (String) -> Void
    ) -> NSView {
        let columns = 6
        let cell = NSSize(width: 44, height: 36)
        let gap: CGFloat = 8
        let available = styles.filter {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) != nil
        }
        let rowCount = max(1, Int(ceil(Double(available.count) / Double(columns))))
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let height = CGFloat(rowCount) * cell.height + CGFloat(rowCount - 1) * gap
        wrap.heightAnchor.constraint(equalToConstant: height).isActive = true
        for (index, style) in available.enumerated() {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.title)
            button.imagePosition = .imageOnly
            button.bezelStyle = .regularSquare
            button.isBordered = style.symbol == selected
            button.contentTintColor = style.symbol == selected ? .controlAccentColor : .labelColor
            button.toolTip = style.title
            button.translatesAutoresizingMaskIntoConstraints = false
            let column = index % columns
            let row = index / columns
            wrap.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: CGFloat(column) * (cell.width + gap)),
                button.topAnchor.constraint(equalTo: wrap.topAnchor, constant: CGFloat(row) * (cell.height + gap)),
                button.widthAnchor.constraint(equalToConstant: cell.width),
                button.heightAnchor.constraint(equalToConstant: cell.height),
            ])
            let symbol = style.symbol
            actions[ObjectIdentifier(button)] = { apply(symbol) }
            button.target = self
            button.action = #selector(runControl(_:))
        }
        return wrap
    }

    private func footnote(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 520
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func pathLabel(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 560
        return label
    }

    private func toggle(_ title: String, on: Bool, key: String, enabled: Bool = true) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = enabled ? .labelColor : .disabledControlTextColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(runControl(_:))
        actions[ObjectIdentifier(toggle)] = { [weak self] in
            self?.applySwitch(key: key, on: toggle.state == .on)
        }
        let row = NSStackView(views: [label, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return row
    }

    private func button(_ title: String, work: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(runControl(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        actions[ObjectIdentifier(button)] = work
        return button
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func listRow(
        _ title: String,
        detail: String,
        actionTitle: String = "编辑",
        work: @escaping () -> Void
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let edit = button(actionTitle, work: work)
        edit.controlSize = .regular
        let row = NSStackView(views: [text, edit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        return row
    }

    private func quitButton(_ host: SettingsHosting) -> NSView {
        let button = self.button("退出 Tocode") { host.settingsQuit() }
        button.hasDestructiveAction = true
        button.bezelStyle = .rounded
        return padded(button, top: 18)
    }

    private func padded(_ view: NSView, top: CGFloat) -> NSView {
        let wrap = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    @objc private func runControl(_ sender: NSControl) {
        let work = actions[ObjectIdentifier(sender)]
        if sender is NSSwitch || sender is NSPopUpButton {
            restoreScrollOrigin = scroll.contentView.bounds.origin
        }
        work?()
        reloadForm()
        if let origin = restoreScrollOrigin {
            form.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            restoreScrollOrigin = nil
        }
    }

    private func applySwitch(key: String, on: Bool) {
        guard let host else { return }
        switch key {
        case "folderIcon": host.settingsSetFolderIconVisible(on)
        case "windowsIcon": host.settingsSetWindowsIconVisible(on)
        case "finderFollow": host.settingsSetFinderFollow(on)
        case "terminalFollow": host.settingsSetTerminalFollow(on)
        case "codexFollow": host.settingsSetCodexFollow(on)
        case "hermesFollow": host.settingsSetHermesFollow(on)
        case "hidden": host.settingsSetShowHidden(on)
        case "finderMove": host.settingsSetFinderMove(on)
        case "finderCmdQ": host.settingsSetFinderCommandQ(on)
        case "doubleQ": host.settingsSetDoubleCommandQ(on)
        case "space": host.settingsSetSpaceModifier(on)
        case "wheelV": host.settingsSetVerticalWheel(on)
        case "wheelH": host.settingsSetHorizontalWheel(on)
        case "dock": host.settingsSetDockRestrict(on)
        case "login": host.settingsSetLaunchAtLogin(on)
        case "gateway": host.settingsSetHermesGateway(on)
        case "menuTracking": host.settingsSetMenuTracking(on)
        default: break
        }
    }
}

private final class SettingsSidebarCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        text.isEditable = false
        text.isSelectable = false
        text.refusesFirstResponder = true
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(text)
        imageView = image
        textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let table = enclosingScrollView?.documentView as? NSTableView else { return }
        let row = table.row(for: self)
        guard row >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

private final class SettingsFormView: NSView {
    private let stack = NSStackView()
    private var layingOut = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRows(_ rows: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        needsLayout = true
    }

    override func layout() {
        guard !layingOut else {
            super.layout()
            return
        }
        layingOut = true
        defer { layingOut = false }
        let width = max(enclosingScrollView?.contentView.bounds.width ?? bounds.width, 1)
        if abs(bounds.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: max(bounds.height, 1)))
        }
        stack.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize.height + 48
        let visible = enclosingScrollView?.contentView.bounds.height ?? fitted
        let height = max(fitted, visible)
        if abs(bounds.height - height) > 0.5 || abs(bounds.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
        super.layout()
    }
}
