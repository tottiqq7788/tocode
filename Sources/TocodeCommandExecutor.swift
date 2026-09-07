import AppKit
import Foundation
import UserNotifications

/// 供命令执行器使用的窄接口，真实服务通过扩展适配，测试可注入 mock。
protocol TocodeFinderSelectionCommanding {
    func resolveInitializationDirectory() -> Result<String, FinderSelectionError>
}

extension FinderSelectionService: TocodeFinderSelectionCommanding {}


protocol TocodeWheelCommanding {
    var isVerticalEffective: Bool { get }
    var isHorizontalEffective: Bool { get }
    func setVerticalEnabled(_ enabled: Bool) -> Bool
    func setHorizontalEnabled(_ enabled: Bool) -> Bool
}

protocol TocodeShortcutCommanding {
    var isFinderMoveEffective: Bool { get }
    var isDoubleCommandQEffective: Bool { get }
    var isFinderCommandQEffective: Bool { get }
    func setFinderMoveEnabled(_ enabled: Bool) -> Bool
    func setDoubleCommandQEnabled(_ enabled: Bool) -> Bool
    func setFinderCommandQEnabled(_ enabled: Bool) -> Bool
}

protocol TocodeVisibilityCommanding {
    func currentShowAllFiles() -> Bool
    func setShowAllFiles(_ show: Bool) -> Bool
}

extension MouseWheelReverseService: TocodeWheelCommanding {}
extension GlobalShortcutService: TocodeShortcutCommanding {}
extension FinderVisibilityService: TocodeVisibilityCommanding {}

/// 统一命令执行器：CLI 与微信命令共享，白名单枚举，不做 shell 执行。
@MainActor
final class TocodeCommandExecutor {
    private let fs: FileSystemService
    private let store: RootPathStore
    private let chooser: TocodeRootChoosing
    private let finderSelection: any TocodeFinderSelectionCommanding
    private let visibility: any TocodeVisibilityCommanding
    private let launchAtLogin: LaunchAtLoginControlling
    private let mouseWheel: any TocodeWheelCommanding
    private let shortcuts: any TocodeShortcutCommanding
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let codexModels: CodexModelSwitching
    private let codexRestarter: CodexApplicationRestarting
    private var weChat: WeChatAssociationControlling
    private let screenBlackout: ScreenBlackoutService
    private let notify: (String, String) -> Void

    init(
        fs: FileSystemService = FileSystemService(),
        store: RootPathStore = RootPathStore(),
        chooser: TocodeRootChoosing? = nil,
        finderSelection: any TocodeFinderSelectionCommanding = FinderSelectionService(),
        visibility: any TocodeVisibilityCommanding = FinderVisibilityService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        mouseWheel: any TocodeWheelCommanding,
        shortcuts: any TocodeShortcutCommanding,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore(),
        codexModels: CodexModelSwitching,
        codexRestarter: CodexApplicationRestarting = CodexApplicationRestarter(),
        weChat: WeChatAssociationControlling,
        screenBlackout: ScreenBlackoutService? = nil,
        notify: @escaping (String, String) -> Void = { title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "tocode.command.\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
            ) { _ in }
        }
    ) {
        self.fs = fs
        self.store = store
        self.chooser = chooser ?? PanelTocodeRootChooser()
        self.finderSelection = finderSelection
        self.visibility = visibility
        self.launchAtLogin = launchAtLogin
        self.mouseWheel = mouseWheel
        self.shortcuts = shortcuts
        self.codex = codex
        self.codexSync = codexSync
        self.codexModels = codexModels
        self.codexRestarter = codexRestarter
        self.weChat = weChat
        self.screenBlackout = screenBlackout ?? ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
        self.notify = notify
    }

    func attachWeChat(_ controller: WeChatAssociationControlling) {
        weChat = controller
    }

    func execute(_ command: TocodeCommand) -> TocodeCommandResult {
        switch command {
        case .help:
            return .success(TocodeCommandOutput(TocodeCommandParser.helpText))
        case .status:
            return .success(TocodeCommandOutput(lines: statusLines()))
        case .root(let subcommand):
            return executeRoot(subcommand)
        case .codex(let subcommand):
            return executeCodex(subcommand)
        case .wechat(let subcommand):
            return executeWechat(subcommand)
        case .blackout:
            screenBlackout.activate()
            return .success(TocodeCommandOutput("已触发临时黑屏"))
        case .login(let toggle):
            return applyToggle(toggle, current: launchAtLogin.isEnabled) { [launchAtLogin] target in
                launchAtLogin.setEnabled(target).mapError(TocodeCommandError.launchError)
            }
        case .wheel(let axis, let toggle):
            switch axis {
            case .vertical:
                return applyToggle(toggle, current: mouseWheel.isVerticalEffective) { target in
                    mouseWheel.setVerticalEnabled(target)
                        ? .success(())
                        : .failure(TocodeCommandError.operationFailed("无法对调垂直滚轮（可能需要辅助功能权限）"))
                }
            case .horizontal:
                return applyToggle(toggle, current: mouseWheel.isHorizontalEffective) { target in
                    mouseWheel.setHorizontalEnabled(target)
                        ? .success(())
                        : .failure(TocodeCommandError.operationFailed("无法对调横向滚轮（可能需要辅助功能权限）"))
                }
            }
        case .hidden(let toggle):
            return applyToggle(toggle, current: visibility.currentShowAllFiles()) { target in
                visibility.setShowAllFiles(target)
                    ? .success(())
                    : .failure(TocodeCommandError.operationFailed("无法切换隐藏文件显示"))
            }
        case .shortcut(let kind, let toggle):
            return executeShortcut(kind, toggle: toggle)
        case .quit:
            notify("Tocode 即将退出", "收到 quit 命令")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return .success(TocodeCommandOutput("已请求退出 Tocode"))
        }
    }

    func execute(_ body: String) -> TocodeCommandResult {
        switch TocodeCommandParser.parse(body) {
        case .failure(let error):
            return .failure(error)
        case .success(let command):
            return execute(command)
        }
    }

    // MARK: - 状态汇总

    private func statusLines() -> [String] {
        let root = store.resolveRoot(isDirectory: fs.isExistingDirectory)
        let syncEnabled = codexSync.syncEnabled
        var projectLine = "Codex 项目：未检测到"
        if let project = codex.resolveProject() {
            projectLine = "Codex 项目：\(project.name)（\(project.rootPath)）"
        }
        let modelLine: String
        if let state = try? codexModels.currentState() {
            modelLine = "Codex 模型：\(CodexModelCatalog.displayName(for: state.liveModelID))\(state.isConsistent ? "" : "（配置不一致）")"
        } else {
            modelLine = "Codex 模型：不可用"
        }
        return [
            "根目录：\(root)",
            "开机自启：\(launchAtLogin.isEnabled ? "开" : "关")",
            "对调垂直滚轮：\(mouseWheel.isVerticalEffective ? "开" : "关")",
            "对调横向滚轮：\(mouseWheel.isHorizontalEffective ? "开" : "关")",
            "显示隐藏文件：\(visibility.currentShowAllFiles() ? "开" : "关")",
            "x/v 移动文件：\(shortcuts.isFinderMoveEffective ? "开" : "关")",
            "双击 ⌘Q：\(shortcuts.isDoubleCommandQEffective ? "开" : "关")",
            "⌘Q 强关访达：\(shortcuts.isFinderCommandQEffective ? "开" : "关")",
            "微信绑定：\(weChat.isBound ? "已绑定" : "未绑定")",
            projectLine,
            "同步项目夹：\(syncEnabled ? "开" : "关")",
            modelLine
        ]
    }

    // MARK: - root

    private func executeRoot(_ subcommand: TocodeRootCommand) -> TocodeCommandResult {
        switch subcommand {
        case .get:
            return .success(TocodeCommandOutput(
                store.resolveRoot(isDirectory: fs.isExistingDirectory)
            ))
        case .set(let path):
            let standardized = (path as NSString).standardizingPath
            guard fs.isExistingDirectory(standardized) else {
                return .failure(.rootNotFound(path))
            }
            store.save(standardized)
            notify("根目录已更新", standardized)
            return .success(TocodeCommandOutput("已设置根目录：\(standardized)"))
        case .choose:
            guard let path = chooser.chooseRoot() else {
                return .failure(.rootSelectionCancelled)
            }
            store.save(path)
            notify("根目录已更新", path)
            return .success(TocodeCommandOutput("已设置根目录：\(path)"))
        case .reset:
            store.reset()
            notify("根目录已更新", RootPathStore.defaultRoot)
            return .success(TocodeCommandOutput("已重置根目录：\(RootPathStore.defaultRoot)"))
        case .initFromFinder:
            switch finderSelection.resolveInitializationDirectory() {
            case .success(let path):
                store.save(path)
                notify("根目录已更新", path)
                return .success(TocodeCommandOutput("已设置根目录：\(path)"))
            case .failure(let error):
                return .failure(.finderSelectionFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - codex

    private func executeCodex(_ subcommand: TocodeCodexCommand) -> TocodeCommandResult {
        switch subcommand {
        case .status:
            if let project = codex.resolveProject() {
                return .success(TocodeCommandOutput(lines: [
                    "Codex 项目：\(project.name)",
                    "根目录：\(project.rootPath)"
                ]))
            }
            return .failure(.codexUnavailable("未检测到 Codex 本地项目"))
        case .sync(let toggle):
            return applyToggle(toggle, current: codexSync.syncEnabled) { target in
                codexSync.syncEnabled = target
                return .success(())
            }
        case .model:
            do {
                let state = try codexModels.currentState()
                return .success(TocodeCommandOutput(lines: [
                    "模型：\(CodexModelCatalog.displayName(for: state.liveModelID))",
                    "ID：\(state.liveModelID)",
                    "一致性：\(state.isConsistent ? "一致" : "不一致")"
                ]))
            } catch {
                return .failure(.codexUnavailable(error.localizedDescription))
            }
        case .modelList:
            let semaphore = DispatchSemaphore(value: 0)
            var modelsResult: Result<[CodexModelDescriptor], Error>?
            codexModels.fetchModels { result in
                modelsResult = result
                semaphore.signal()
            }
            let waited = semaphore.wait(timeout: .now() + 20)
            guard waited == .success, let modelsResult else {
                return .failure(.codexUnavailable("模型目录请求超时"))
            }
            switch modelsResult {
            case .failure(let error):
                return .failure(.codexUnavailable(error.localizedDescription))
            case .success(let models):
                let lines = models.map { "\($0.id)\t\($0.displayName)" }
                return .success(TocodeCommandOutput(lines: lines.isEmpty ? ["无可用模型"] : lines))
            }
        case .modelSet(let id):
            do {
                try codexModels.switchModel(to: id)
            } catch {
                return .failure(.codexModelSwitchFailed(error.localizedDescription))
            }
            notify(
                "Codex 模型已切换",
                "\(CodexModelCatalog.displayName(for: id))；2 秒后将强制重启 Codex。"
            )
            codexRestarter.forceRestart(after: 2) { _ in }
            return .success(TocodeCommandOutput(
                "已切换模型 \(id)；2 秒后强制重启 Codex"
            ))
        }
    }

    // MARK: - wechat

    private func executeWechat(_ subcommand: TocodeWechatCommand) -> TocodeCommandResult {
        switch subcommand {
        case .status:
            return .success(TocodeCommandOutput(weChat.isBound ? "微信已绑定" : "微信未绑定"))
        case .bind:
            weChat.startBinding()
            return .success(TocodeCommandOutput("已触发微信扫码绑定"))
        case .location:
            weChat.openArchiveLocation()
            return .success(TocodeCommandOutput("已在访达打开微信归档目录"))
        }
    }

    // MARK: - 快捷键

    private func executeShortcut(
        _ kind: TocodeShortcutKind,
        toggle: TocodeToggle
    ) -> TocodeCommandResult {
        let current: Bool
        let apply: (Bool) -> Result<Void, TocodeCommandError>
        switch kind {
        case .finderMove:
            current = shortcuts.isFinderMoveEffective
            apply = { [shortcuts] target in
                shortcuts.setFinderMoveEnabled(target)
                    ? .success(())
                    : .failure(TocodeCommandError.operationFailed("无法切换 x/v 移动文件（可能需要辅助功能权限）"))
            }
        case .doubleCmdQ:
            current = shortcuts.isDoubleCommandQEffective
            apply = { [shortcuts] target in
                shortcuts.setDoubleCommandQEnabled(target)
                    ? .success(())
                    : .failure(TocodeCommandError.operationFailed("无法切换双击 ⌘Q（可能需要辅助功能权限）"))
            }
        case .finderCmdQ:
            current = shortcuts.isFinderCommandQEffective
            apply = { [shortcuts] target in
                shortcuts.setFinderCommandQEnabled(target)
                    ? .success(())
                    : .failure(TocodeCommandError.operationFailed("无法切换 ⌘Q 强关访达（可能需要辅助功能权限）"))
            }
        }
        return applyToggle(toggle, current: current, apply: apply)
    }

    private func applyToggle(
        _ toggle: TocodeToggle,
        current: Bool,
        apply: (Bool) -> Result<Void, TocodeCommandError>
    ) -> TocodeCommandResult {
        let target: Bool
        switch toggle {
        case .on:
            target = true
        case .off:
            target = false
        case .toggle:
            target = !current
        }
        switch apply(target) {
        case .success:
            let state = target ? "开" : "关"
            return .success(TocodeCommandOutput("已切换为 \(state)"))
        case .failure(let error):
            return .failure(error)
        }
    }
}

private extension TocodeCommandError {
    static func launchError(_ error: LaunchAtLoginError) -> TocodeCommandError {
        switch error {
        case .needsApproval:
            return .operationFailed("开机自启需要系统批准，请在“系统设置 → 通用 → 登录项与扩展”中允许 Tocode")
        case .registerFailed:
            return .operationFailed("登记开机自启失败")
        case .unregisterFailed:
            return .operationFailed("撤销开机自启失败，请在系统设置中手动关闭")
        }
    }
}
