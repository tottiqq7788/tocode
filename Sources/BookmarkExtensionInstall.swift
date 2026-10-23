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

    /// `open -a` 候选应用名，按优先级。
    var applicationNames: [String] {
        switch self {
        case .chrome:
            return ["Google Chrome", "Chromium"]
        case .edge:
            return ["Microsoft Edge"]
        case .firefox:
            return ["Firefox"]
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
        let source = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Extensions/bookmark-sync", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) {
            return source
        }
        return nil
    }

    /// 按浏览器分开的包外可加载副本（Firefox 与 Chromium 的 background 字段不同）。
    static func stagedExtensionDirectory(for browser: BookmarkBrowser) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(
            "com.tocode.app/Extensions/bookmark-sync-\(browser.rawValue)",
            isDirectory: true
        )
    }

    /// 把包内扩展同步到 Application Support；Firefox 改写为 `background.scripts`。
    static func prepareInstallableExtensionDirectory(for browser: BookmarkBrowser) throws -> URL {
        guard let bundled = bundledExtensionDirectory() else {
            throw BookmarkExtensionInstallError.extensionMissing
        }
        let staged = stagedExtensionDirectory(for: browser)
        let fm = FileManager.default
        try fm.createDirectory(
            at: staged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: staged.path) {
            try fm.removeItem(at: staged)
        }
        try fm.copyItem(at: bundled, to: staged)
        if browser == .firefox {
            try rewriteManifestBackgroundScripts(at: staged.appendingPathComponent("manifest.json"))
        } else {
            // 兼容早期装到 Extensions/bookmark-sync 的 Chrome/Edge：同步刷新旧路径，避免仍跑无 upsert 的旧脚本。
            let legacy = staged.deletingLastPathComponent().appendingPathComponent("bookmark-sync", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) {
                try fm.removeItem(at: legacy)
            }
            try fm.copyItem(at: staged, to: legacy)
        }
        return staged
    }

    /// 正式版 Firefox 常禁用扩展 service_worker，须用 background.scripts。
    static func rewriteManifestBackgroundScripts(at manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BookmarkExtensionInstallError.extensionMissing
        }
        root["background"] = ["scripts": ["background.js"]]
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: manifestURL, options: .atomic)
    }

    /// 在访达中选中 bookmark-sync 目录本身（便于「加载已解压」直接点选）。
    static func revealExtensionDirectoryInFinder(_ directory: URL) {
        // `open -R` 对 Application Support 路径比包内 Resources 更稳；再拉起访达以免被浏览器盖住。
        let reveal = Process()
        reveal.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reveal.arguments = ["-R", directory.path]
        reveal.standardOutput = FileHandle.nullDevice
        reveal.standardError = FileHandle.nullDevice
        try? reveal.run()
        reveal.waitUntilExit()
        if reveal.terminationStatus != 0 {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        activate.arguments = ["-a", "Finder"]
        activate.standardOutput = FileHandle.nullDevice
        activate.standardError = FileHandle.nullDevice
        try? activate.run()
        activate.waitUntilExit()
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

        let prefix = "\(browser.rawValue):"
        let connected = connectedKeys.contains { $0.hasPrefix(prefix) }

        // 已在线：只开扩展管理页，不再开访达、不弹安装说明。
        if connected {
            if !openExtensionPage(for: browser) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(browser.extensionPageURL.absoluteString, forType: .string)
                present(
                    title: "未能打开 \(browser.title)",
                    message: "扩展页地址已复制，请粘贴到地址栏：\n\(browser.extensionPageURL.absoluteString)"
                )
            }
            return
        }

        let extensionDir: URL
        do {
            extensionDir = try prepareInstallableExtensionDirectory(for: browser)
        } catch {
            present(title: "找不到扩展", message: error.localizedDescription)
            return
        }

        // 先开访达定位目录，再开扩展页；浏览器抢焦点后再把访达拉回前台。
        revealExtensionDirectoryInFinder(extensionDir)
        let opened = openExtensionPage(for: browser)
        revealExtensionDirectoryInFinder(extensionDir)

        let alert = NSAlert()
        alert.messageText = "安装 \(browser.title) 扩展"
        var detail: String
        let loadHint: String
        if browser == .firefox {
            loadHint = """
            目标页是 about:debugging（不是 about:addons）。在「此 Firefox」里点「临时载入附加组件…」，选访达中 bookmark-sync-firefox 目录下的 manifest.json。
            """
        } else {
            loadHint = """
            请开启「开发者模式」，选择「加载已解压的扩展程序」，指向访达中选中的 bookmark-sync-\(browser.rawValue) 目录。
            """
        }
        if opened {
            detail = """
            已登记 Native Messaging 主机，访达已打开扩展目录，并已用 \(browser.title) 打开扩展页。

            \(loadHint)
            """
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(browser.extensionPageURL.absoluteString, forType: .string)
            detail = """
            已登记 Native Messaging 主机，访达已打开扩展目录。未能自动打开 \(browser.title)（可能未安装）。

            扩展页地址已复制，请粘贴到地址栏打开：
            \(browser.extensionPageURL.absoluteString)

            \(loadHint)
            """
        }
        if browser == .firefox {
            detail += "\n正式版 Firefox 不会保留未签名扩展：重启后需再加载一次。未连上时不会假装已在同步。"
        }
        detail += "\n\n当前未检测到该浏览器扩展在线。"
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 用对应浏览器打开 chrome:// / edge:// / about: 扩展页。
    @discardableResult
    static func openExtensionPage(for browser: BookmarkBrowser) -> Bool {
        if browser == .firefox {
            return openFirefoxExtensionPage()
        }
        let page = browser.extensionPageURL.absoluteString
        for name in browser.applicationNames {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name, page]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    /// Firefox 不吃 `open -a … about:`（常只启动应用、不导航）；要用二进制 `-new-tab`。
    private static func openFirefoxExtensionPage() -> Bool {
        let page = BookmarkBrowser.firefox.extensionPageURL.absoluteString
        let bundleIDs = [
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly"
        ]
        for bundleID in bundleIDs {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                continue
            }
            let binary = appURL.appendingPathComponent("Contents/MacOS/firefox")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { continue }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-new-tab", page]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // 已有实例时会很快把标签交给现进程并退出；冷启动则进程常驻，不能 wait。
                return true
            } catch {
                continue
            }
        }
        // 回退：open --args（仍优于裸 about:）
        for name in BookmarkBrowser.firefox.applicationNames {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name, "--args", "-new-tab", page]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
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
