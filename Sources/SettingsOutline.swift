import Foundation

/// 设置窗口的一级分页。二级分组在内容区顶部切换，一次只显示一组。
enum SettingsPage: Int, CaseIterable {
    case menubar
    case path
    case input
    case tools
    case model
    case connection
    case general

    var title: String {
        switch self {
        case .menubar: return "菜单栏"
        case .path: return "路径"
        case .input: return "输入"
        case .tools: return "工具"
        case .model: return "模型"
        case .connection: return "连接"
        case .general: return "通用"
        }
    }

    var symbolName: String {
        switch self {
        case .menubar: return "menubar.rectangle"
        case .path: return "folder"
        case .input: return "keyboard"
        case .tools: return "wrench.and.screwdriver"
        case .model: return "point.3.connected.trianglepath.dotted"
        case .connection: return "link"
        case .general: return "gearshape"
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .menubar:
            return [
                SettingsSection(id: "folder", title: "文件夹"),
                SettingsSection(id: "windows", title: "窗口"),
            ]
        case .path:
            return [
                SettingsSection(id: "root", title: "固定根"),
                SettingsSection(id: "follow", title: "跟随"),
                SettingsSection(id: "finder", title: "访达"),
            ]
        case .input:
            return [
                SettingsSection(id: "keyboard", title: "键盘"),
                SettingsSection(id: "trackpad", title: "触控板"),
                SettingsSection(id: "remote", title: "遥控"),
                SettingsSection(id: "remap", title: "改键"),
            ]
        case .tools:
            return [
                SettingsSection(id: "timers", title: "定时器"),
                SettingsSection(id: "bookmarks", title: "书签"),
                SettingsSection(id: "extensions", title: "扩展"),
                SettingsSection(id: "dock", title: "程序坞"),
            ]
        case .model:
            return [
                SettingsSection(id: "status", title: "状态"),
                SettingsSection(id: "providers", title: "厂家"),
                SettingsSection(id: "keys", title: "密钥"),
                SettingsSection(id: "automations", title: "自动化"),
            ]
        case .connection:
            return [
                SettingsSection(id: "app", title: "应用"),
                SettingsSection(id: "wechat", title: "微信"),
            ]
        case .general:
            return [
                SettingsSection(id: "startup", title: "启动"),
                SettingsSection(id: "config", title: "配置"),
                SettingsSection(id: "about", title: "说明"),
            ]
        }
    }
}

struct SettingsSection: Equatable {
    var id: String
    var title: String
}
