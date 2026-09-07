import AppKit

/// 常驻进程弹出目录选择面板的边界，测试可注入 mock。
@MainActor
protocol TocodeRootChoosing: AnyObject {
    func chooseRoot() -> String?
}

@MainActor
final class PanelTocodeRootChooser: TocodeRootChoosing {
    func chooseRoot() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择作为根文件夹的目录"
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return url.path
    }
}
