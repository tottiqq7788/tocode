import AppKit

/// 「工具 → 书签同步」子菜单构建；动作 selector 仍由 StatusItemController 承接。
enum BookmarkSyncMenuBuilder {
    @MainActor
    static func makeSubmenu(
        target: AnyObject,
        bookmarkSync: BookmarkSyncService,
        openLog: Selector,
        configureRemote: Selector,
        restoreBackup: Selector,
        backupNow: Selector,
        installExtension: Selector
    ) -> NSMenu {
        let bookmarkMenu = NSMenu()
        bookmarkMenu.autoenablesItems = false

        let syncLogItem = bookmarkMenu.addItem(
            withTitle: "同步日志",
            action: openLog,
            keyEquivalent: ""
        )
        syncLogItem.target = target
        syncLogItem.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)

        let remoteSyncItem = bookmarkMenu.addItem(
            withTitle: "远程同步",
            action: configureRemote,
            keyEquivalent: ""
        )
        remoteSyncItem.target = target
        ShortcutMenuAppearance.apply(to: remoteSyncItem, enabled: bookmarkSync.isRemoteEnabled)
        remoteSyncItem.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: nil)

        let backupItem = bookmarkMenu.addItem(withTitle: "备份", action: nil, keyEquivalent: "")
        backupItem.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        let backupMenu = NSMenu()
        backupMenu.autoenablesItems = false
        let backupList = bookmarkSync.backupListPayload()
        if backupList.isEmpty {
            let emptyItem = backupMenu.addItem(withTitle: "暂无日备", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
        } else {
            for slot in backupList.reversed() {
                let day = slot["day"] as? String ?? "?"
                let entries = slot["entries"] as? Int ?? 0
                let item = backupMenu.addItem(
                    withTitle: "还原 \(day)（\(entries) 条）",
                    action: restoreBackup,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = day
            }
        }
        backupMenu.addItem(NSMenuItem.separator())
        let backupNowItem = backupMenu.addItem(
            withTitle: "立即备份",
            action: backupNow,
            keyEquivalent: ""
        )
        backupNowItem.target = target
        backupNowItem.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        backupItem.submenu = backupMenu

        let installItem = bookmarkMenu.addItem(withTitle: "拓展安装", action: nil, keyEquivalent: "")
        installItem.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        let installMenu = NSMenu()
        installMenu.autoenablesItems = false
        for browser in BookmarkBrowser.allCases {
            let item = installMenu.addItem(
                withTitle: browser.title,
                action: installExtension,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = browser.rawValue
            let connected = bookmarkSync.connectedBrowserKeys.contains { $0.hasPrefix("\(browser.rawValue):") }
            ShortcutMenuAppearance.apply(to: item, enabled: connected)
        }
        installItem.submenu = installMenu
        return bookmarkMenu
    }
}
