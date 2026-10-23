import AppKit
import Foundation

enum BookmarkBrowser: String, CaseIterable {
    case chrome
    case edge
    case firefox

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        }
    }

    var extensionPageURL: URL {
        switch self {
        case .chrome:
            return URL(string: "chrome://extensions")!
        case .edge:
            return URL(string: "edge://extensions")!
        case .firefox:
            return URL(string: "about:debugging#/runtime/this-firefox")!
        }
    }

    var nativeMessagingDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .chrome:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        case .edge:
            return home.appendingPathComponent("Library/Application Support/Microsoft Edge/NativeMessagingHosts")
        case .firefox:
            return home.appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts")
        }
    }
}

enum BookmarkExtensionInstall {
    static func bundledExtensionDirectory() -> URL? {
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("Extensions/bookmark-sync", isDirectory: true),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource
        }
        // 开发态：源码旁
        let source = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Extensions/bookmark-sync", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) {
            return source
        }
        return nil
    }

    static func hostExecutableURL() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "tocode-bookmark-host") {
            return url
        }
        let beside = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tocode-bookmark-host")
        if FileManager.default.isExecutableFile(atPath: beside.path) {
            return beside
        }
        let build = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/tocode-bookmark-host")
        if FileManager.default.isExecutableFile(atPath: build.path) {
            return build
        }
        return nil
    }

    @MainActor
    static func install(browser: BookmarkBrowser, connectedKeys: [String]) {
        do {
            try registerNativeMessaging(for: browser)
        } catch {
            present(title: "登记失败", message: error.localizedDescription)
            return
        }

        guard let extensionDir = bundledExtensionDirectory() else {
            present(title: "找不到扩展", message: "应用包内没有 Extensions/bookmark-sync。请先重新构建 Tocode。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionDir])

        let alert = NSAlert()
        alert.messageText = "安装 \(browser.title) 扩展"
        var detail = """
        已登记 Native Messaging 主机，并在访达中打开了扩展目录。

        请到 \(browser.title) 打开扩展页，开启「开发者模式」，选择「加载已解压的扩展程序」，指向刚打开的 bookmark-sync 目录。
        """
        if browser == .firefox {
            detail += "\n\n正式版 Firefox 不会保留未签名扩展：重启后需再加载一次。未连上时不会假装已在同步。"
        }
        let prefix = "\(browser.rawValue):"
        let connected = connectedKeys.contains { $0.hasPrefix(prefix) }
        if !connected {
            detail += "\n\n当前未检测到该浏览器扩展在线。"
        } else {
            detail += "\n\n已检测到该浏览器扩展在线。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "打开扩展页说明")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            // chrome:// 等不能用 openURL；复制说明。
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(browser.extensionPageURL.absoluteString, forType: .string)
            let tip = NSAlert()
            tip.messageText = "已复制扩展页地址"
            tip.informativeText = "请粘贴到 \(browser.title) 地址栏打开：\n\(browser.extensionPageURL.absoluteString)"
            tip.addButton(withTitle: "好")
            tip.runModal()
        }
    }

    static func registerNativeMessaging(for browser: BookmarkBrowser) throws {
        guard let host = hostExecutableURL() else {
            throw BookmarkExtensionInstallError.hostMissing
        }
        guard let extensionDir = bundledExtensionDirectory() else {
            throw BookmarkExtensionInstallError.extensionMissing
        }
        let dir = browser.nativeMessagingDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("\(BookmarkNativeBridge.hostName).json")

        var allowedOrigins: [String] = []
        var allowedExtensions: [String] = []
        let idFile = extensionDir.appendingPathComponent("extension-id.txt")
        let extensionID = (try? String(contentsOf: idFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if browser == .firefox {
            allowedExtensions = ["bookmark-sync@tocode.app"]
        } else {
            let id = (extensionID?.isEmpty == false) ? extensionID! : "eboibkdllghagjclofflkabfhndgpnde"
            allowedOrigins = ["chrome-extension://\(id)/"]
        }

        var manifest: [String: Any] = [
            "name": BookmarkNativeBridge.hostName,
            "description": "Tocode bookmark sync native host",
            "path": host.path,
            "type": "stdio"
        ]
        if browser == .firefox {
            manifest["allowed_extensions"] = allowedExtensions
        } else {
            manifest["allowed_origins"] = allowedOrigins
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
    }

    @MainActor
    private static func present(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

enum BookmarkExtensionInstallError: Error, LocalizedError {
    case hostMissing
    case extensionMissing

    var errorDescription: String? {
        switch self {
        case .hostMissing:
            return "找不到 tocode-bookmark-host。请先重新构建 Tocode。"
        case .extensionMissing:
            return "找不到扩展目录 Extensions/bookmark-sync。"
        }
    }
}
