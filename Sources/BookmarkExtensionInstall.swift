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
            return URL(string: "about:addons")!
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

    /// 包内 Mozilla 已签名的 Firefox 扩展（正式版重启后仍保留）。
    static let firefoxSignedExtensionID = "bookmark-sync@tocode.app"

    static func bundledFirefoxSignedXPI() -> URL? {
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("Extensions/bookmark-sync-firefox.xpi"),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource
        }
        let source = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Extensions/firefox/bookmark-sync@tocode.app.xpi")
        if FileManager.default.fileExists(atPath: source.path) {
            return source
        }
        return nil
    }

    /// 从 profiles.ini 取 Firefox 正在使用的配置目录。优先 Install 段的 Default。
    static func firefoxProfileDirectory(profilesIni: String, root: URL) -> URL? {
        var installDefault: String?
        var profileDefault: String?
        var section = ""
        var pendingPath: String?
        var pendingRelative = true
        var pendingIsDefault = false
        func commitProfile() {
            guard section == "Profile", let path = pendingPath else { return }
            let resolved = pendingRelative
                ? Self.appendRelativePath(path, to: root).path
                : path
            if pendingIsDefault || profileDefault == nil {
                profileDefault = resolved
            }
        }
        for raw in profilesIni.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if section == "Profile" {
                    commitProfile()
                }
                section = String(line.dropFirst().dropLast())
                pendingPath = nil
                pendingRelative = true
                pendingIsDefault = false
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if section.hasPrefix("Install"), key == "Default" {
                installDefault = value
            } else if section == "Profile" {
                if key == "Path" { pendingPath = value }
                if key == "IsRelative" { pendingRelative = value != "0" }
                if key == "Default", value == "1" { pendingIsDefault = true }
            }
        }
        if section == "Profile" { commitProfile() }
        if let installDefault {
            return appendRelativePath(installDefault, to: root)
        }
        if let profileDefault {
            return URL(fileURLWithPath: profileDefault)
        }
        return nil
    }

    private static func appendRelativePath(_ relative: String, to root: URL) -> URL {
        relative.split(separator: "/").reduce(root) { url, part in
            url.appendingPathComponent(String(part))
        }
    }

    /// 把包内签名 xpi 写入指定 Firefox 配置，并避免正式版把旁路扩展自动停用。
    static func installSignedFirefoxExtension(xpi: URL, profile: URL) throws {
        let fm = FileManager.default
        let extensions = profile.appendingPathComponent("extensions", isDirectory: true)
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        let destination = extensions.appendingPathComponent("\(firefoxSignedExtensionID).xpi")
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: xpi, to: destination)
        let userJS = profile.appendingPathComponent("user.js")
        let marker = "extensions.autoDisableScopes"
        let line = "user_pref(\"extensions.autoDisableScopes\", 0);\n"
        let existing = (try? String(contentsOf: userJS, encoding: .utf8)) ?? ""
        if !existing.contains(marker) {
            try (existing + line).write(to: userJS, atomically: true, encoding: .utf8)
        }
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

        if browser == .firefox {
            installBundledFirefoxExtension()
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
        let loadHint = """
        请开启「开发者模式」，选择「加载已解压的扩展程序」，指向访达中选中的 bookmark-sync-\(browser.rawValue) 目录。
        """
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
        detail += "\n\n当前未检测到该浏览器扩展在线。"
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 未在线时把包内签名 xpi 写入当前 Firefox 配置，不走临时载入。
    @MainActor
    private static func installBundledFirefoxExtension() {
        guard let xpi = bundledFirefoxSignedXPI() else {
            present(title: "找不到 Firefox 扩展", message: "应用包内没有已签名的 bookmark-sync-firefox.xpi。")
            return
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox")
        let iniURL = support.appendingPathComponent("profiles.ini")
        guard let ini = try? String(contentsOf: iniURL, encoding: .utf8),
              let profile = firefoxProfileDirectory(profilesIni: ini, root: support) else {
            present(title: "找不到 Firefox 配置", message: "没有读到 profiles.ini。请先打开一次 Firefox。")
            return
        }
        do {
            try installSignedFirefoxExtension(xpi: xpi, profile: profile)
        } catch {
            present(title: "安装 Firefox 扩展失败", message: error.localizedDescription)
            return
        }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "org.mozilla.firefox"
        }
        let restart = running
            ? "Firefox 正在运行。请完全退出后再打开，签名扩展才会加载；之后重启仍会保留。"
            : "下次打开 Firefox 即会加载签名扩展，重启后仍会保留。"
        present(
            title: "已安装 Firefox 扩展",
            message: """
            已登记 Native Messaging 主机，并把包内签名扩展写入当前配置：
            \(profile.path)

            \(restart)
            未连上前不会假装已在同步。
            """
        )
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
