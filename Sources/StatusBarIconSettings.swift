import Foundation

/// 菜单栏两个图标的显隐、符号和左右键。缺省都显示。不进入可分享配置。
struct StatusBarIconStyle: Equatable {
    var symbol: String
    var title: String
}

enum StatusBarIconSlot: String {
    case folder
    case windows

    var visibleKey: String { "tocode.statusIcon.\(rawValue).visible" }
    var symbolKey: String { "tocode.statusIcon.\(rawValue).symbol" }
    var leftClickKey: String { "tocode.statusIcon.\(rawValue).left" }
    var rightClickKey: String { "tocode.statusIcon.\(rawValue).right" }

    var defaultSymbol: String {
        switch self {
        case .folder: return "folder"
        case .windows: return "macwindow"
        }
    }

    var itemSlot: StatusItemSlot {
        switch self {
        case .folder: return .folder
        case .windows: return .windows
        }
    }
}

enum StatusBarIconCatalog {
    static let all: [StatusBarIconStyle] = [
        .init(symbol: "folder", title: "文件夹"),
        .init(symbol: "folder.fill", title: "实心文件夹"),
        .init(symbol: "folder.badge.plus", title: "加号文件夹"),
        .init(symbol: "tray.full.fill", title: "收件箱"),
        .init(symbol: "archivebox.fill", title: "归档箱"),
        .init(symbol: "books.vertical.fill", title: "书架"),
        .init(symbol: "bookmark.fill", title: "书签"),
        .init(symbol: "list.bullet.rectangle.portrait", title: "清单"),
        .init(symbol: "square.stack.3d.up.fill", title: "层叠方块"),
        .init(symbol: "externaldrive.fill", title: "磁盘"),
        .init(symbol: "shippingbox.fill", title: "包裹"),
        .init(symbol: "doc.on.doc.fill", title: "文档"),
        .init(symbol: "macwindow", title: "窗口"),
        .init(symbol: "macwindow.on.rectangle", title: "叠放窗口"),
        .init(symbol: "macwindow.badge.plus", title: "新窗口"),
        .init(symbol: "rectangle.split.2x1", title: "左右分栏"),
        .init(symbol: "rectangle.on.rectangle", title: "层叠窗口"),
        .init(symbol: "square.grid.2x2", title: "四格"),
        .init(symbol: "rectangle.3.group", title: "一组窗口"),
        .init(symbol: "display", title: "显示器"),
        .init(symbol: "desktopcomputer", title: "台式机"),
        .init(symbol: "laptopcomputer", title: "笔记本"),
        .init(symbol: "menubar.rectangle", title: "菜单栏"),
        .init(symbol: "uiwindow.split.2x1", title: "分屏"),
        .init(symbol: "star.fill", title: "星形"),
        .init(symbol: "moon.fill", title: "月亮"),
        .init(symbol: "bolt.fill", title: "闪电"),
        .init(symbol: "house.fill", title: "房子"),
        .init(symbol: "terminal.fill", title: "终端"),
        .init(symbol: "globe", title: "地球"),
        .init(symbol: "key.fill", title: "钥匙"),
        .init(symbol: "bell.fill", title: "铃铛"),
        .init(symbol: "flag.fill", title: "旗帜"),
        .init(symbol: "pin.fill", title: "图钉"),
        .init(symbol: "heart.fill", title: "心形"),
        .init(symbol: "sun.max.fill", title: "太阳"),
        .init(symbol: "cloud.fill", title: "云"),
        .init(symbol: "leaf.fill", title: "叶子"),
        .init(symbol: "paperplane.fill", title: "纸飞机"),
        .init(symbol: "tag.fill", title: "标签"),
        .init(symbol: "clock.fill", title: "时钟"),
        .init(symbol: "hammer.fill", title: "锤子"),
        .init(symbol: "lock.fill", title: "锁"),
        .init(symbol: "number", title: "数字"),
    ]

    static func styles(for slot: StatusBarIconSlot) -> [StatusBarIconStyle] {
        _ = slot
        return all
    }

    static func contains(_ symbol: String, slot: StatusBarIconSlot) -> Bool {
        styles(for: slot).contains { $0.symbol == symbol }
    }
}

struct StatusBarIconSettingsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func isVisible(_ slot: StatusBarIconSlot) -> Bool {
        guard defaults.object(forKey: slot.visibleKey) != nil else { return true }
        return defaults.bool(forKey: slot.visibleKey)
    }

    func setVisible(_ on: Bool, slot: StatusBarIconSlot) {
        defaults.set(on, forKey: slot.visibleKey)
    }

    func symbol(for slot: StatusBarIconSlot) -> String {
        let stored = defaults.string(forKey: slot.symbolKey) ?? slot.defaultSymbol
        return StatusBarIconCatalog.contains(stored, slot: slot) ? stored : slot.defaultSymbol
    }

    func setSymbol(_ symbol: String, slot: StatusBarIconSlot) {
        guard StatusBarIconCatalog.contains(symbol, slot: slot) else { return }
        defaults.set(symbol, forKey: slot.symbolKey)
    }

    func menu(for slot: StatusBarIconSlot, isRightClick: Bool) -> StatusItemPrimaryClick {
        let key = isRightClick ? slot.rightClickKey : slot.leftClickKey
        if let raw = defaults.string(forKey: key), let menu = StatusItemPrimaryClick(rawValue: raw) {
            return menu
        }
        return StatusItemPrimaryClick.resolve(slot: slot.itemSlot, isRightClick: isRightClick)
    }

    func setMenu(_ menu: StatusItemPrimaryClick, slot: StatusBarIconSlot, isRightClick: Bool) {
        let key = isRightClick ? slot.rightClickKey : slot.leftClickKey
        defaults.set(menu.rawValue, forKey: key)
    }
}
