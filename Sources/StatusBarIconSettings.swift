import Foundation

/// 菜单栏两个图标的显隐和符号。缺省都显示。不进入可分享配置。
struct StatusBarIconStyle: Equatable {
    var symbol: String
    var title: String
}

enum StatusBarIconSlot: String {
    case folder
    case windows

    var visibleKey: String { "tocode.statusIcon.\(rawValue).visible" }
    var symbolKey: String { "tocode.statusIcon.\(rawValue).symbol" }

    var defaultSymbol: String {
        switch self {
        case .folder: return "folder"
        case .windows: return "macwindow"
        }
    }
}

enum StatusBarIconCatalog {
    static let folder: [StatusBarIconStyle] = [
        .init(symbol: "folder", title: "文件夹"),
        .init(symbol: "folder.fill", title: "实心文件夹"),
        .init(symbol: "folder.badge.plus", title: "加号文件夹"),
        .init(symbol: "tray.full.fill", title: "收件箱"),
        .init(symbol: "archivebox.fill", title: "归档箱"),
        .init(symbol: "books.vertical.fill", title: "书架"),
        .init(symbol: "bookmark.fill", title: "书签"),
        .init(symbol: "list.bullet.rectangle.portrait", title: "清单"),
        .init(symbol: "square.stack.3d.up.fill", title: "层叠"),
        .init(symbol: "externaldrive.fill", title: "磁盘"),
        .init(symbol: "shippingbox.fill", title: "包裹"),
        .init(symbol: "doc.on.doc.fill", title: "文档"),
    ]

    static let windows: [StatusBarIconStyle] = [
        .init(symbol: "macwindow", title: "窗口"),
        .init(symbol: "macwindow.on.rectangle", title: "叠放窗口"),
        .init(symbol: "macwindow.badge.plus", title: "新窗口"),
        .init(symbol: "rectangle.split.2x1", title: "左右分栏"),
        .init(symbol: "rectangle.on.rectangle", title: "层叠"),
        .init(symbol: "square.grid.2x2", title: "四格"),
        .init(symbol: "rectangle.3.group", title: "一组窗口"),
        .init(symbol: "display", title: "显示器"),
        .init(symbol: "desktopcomputer", title: "台式机"),
        .init(symbol: "laptopcomputer", title: "笔记本"),
        .init(symbol: "menubar.rectangle", title: "菜单栏"),
        .init(symbol: "uiwindow.split.2x1", title: "分屏"),
    ]

    static func styles(for slot: StatusBarIconSlot) -> [StatusBarIconStyle] {
        switch slot {
        case .folder: return folder
        case .windows: return windows
        }
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
}
