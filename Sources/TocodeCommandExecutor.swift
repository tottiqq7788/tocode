import AppKit
import Foundation
import UserNotifications

/// 供命令执行器使用的窄接口，真实服务通过扩展适配，测试可注入 mock。
protocol TocodeFinderSelectionCommanding {
    func resolveInitializationDirectory() -> Result<String, FinderSelectionError>
    func resolveSelectedItemPath() -> Result<String, FinderSelectionError>
}

extension FinderSelectionService: TocodeFinderSelectionCommanding {}

protocol TocodeClipboardCommanding {
    func read() -> String?
    func copyPath(_ path: String)
}

extension ClipboardService: TocodeClipboardCommanding {}


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

@MainActor
protocol TocodeTogentCommanding: AnyObject {
    var roles: [TogentRole] { get }
    var models: [TogentModelOption] { get }
    var isBusy: Bool { get }
    var startupError: Error? { get }
    func newRoleDraft() -> TogentRoleDraft
    func roleCopyOptions() -> [TogentRoleCopyOption]
    func defaultWorkspacePath(forRoleName name: String) -> String
    func createRole(from draft: TogentRoleDraft) throws -> TogentRole
    func updateRole(id: UUID, from draft: TogentRoleDraft) throws -> TogentRole
}

/// CLI / 微信点号命令用的非密钥中转状态摘要（与 App 内 ModelRelayService 共享形状）。
struct TocodeModelRelayCLIStatus: Equatable {
    let baseURL: String
    let port: UInt16
    let runStateText: String
    let lastUsedProviderName: String?
    let callCountLast6Hours: Int
}

@MainActor
protocol TocodeModelRelayCommanding: AnyObject {
    func cliStatus() -> TocodeModelRelayCLIStatus
    func availableTogentModels() -> [TogentModelOption]
    func todayCallLogURL() throws -> URL
    func updatePort(_ value: Int) async throws
}

extension MouseWheelReverseService: TocodeWheelCommanding {}
extension GlobalShortcutService: TocodeShortcutCommanding {}
extension FinderVisibilityService: TocodeVisibilityCommanding {}
extension TogentService: TocodeTogentCommanding {}

/// 统一命令执行器：CLI 与微信命令共享，白名单枚举，不做 shell 执行。
@MainActor
final class TocodeCommandExecutor {
    private let fs: FileSystemService
    private let store: RootPathStore
    private let chooser: TocodeRootChoosing
    private let finderSelection: any TocodeFinderSelectionCommanding
    private let clipboard: any TocodeClipboardCommanding
    private let visibility: any TocodeVisibilityCommanding
    private let launchAtLogin: LaunchAtLoginControlling
    private let mouseWheel: any TocodeWheelCommanding
    private let shortcuts: any TocodeShortcutCommanding
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let finderFollow: FinderFollowSettingsStore
    private let codexModels: CodexModelSwitching
    private let codexRestarter: CodexApplicationRestarting
    private var weChat: WeChatAssociationControlling
    private var togent: (any TocodeTogentCommanding)?
    private var modelRelay: (any TocodeModelRelayCommanding)?
    private let workspaceOpener: TogentWorkspaceOpening
    private let screenBlackout: ScreenBlackoutService
    private let notify: (String, String) -> Void

    init(
        fs: FileSystemService = FileSystemService(),
        store: RootPathStore = RootPathStore(),
        chooser: TocodeRootChoosing? = nil,
        finderSelection: any TocodeFinderSelectionCommanding = FinderSelectionService(),
        clipboard: any TocodeClipboardCommanding = ClipboardService(),
        visibility: any TocodeVisibilityCommanding = FinderVisibilityService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        mouseWheel: any TocodeWheelCommanding,
        shortcuts: any TocodeShortcutCommanding,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore(),
        finderFollow: FinderFollowSettingsStore = FinderFollowSettingsStore(),
        codexModels: CodexModelSwitching,
        codexRestarter: CodexApplicationRestarting = CodexApplicationRestarter(),
        weChat: WeChatAssociationControlling,
        togent: (any TocodeTogentCommanding)? = nil,
        modelRelay: (any TocodeModelRelayCommanding)? = nil,
        workspaceOpener: TogentWorkspaceOpening = SystemTogentWorkspaceOpener(),
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
        self.clipboard = clipboard
        self.visibility = visibility
        self.launchAtLogin = launchAtLogin
        self.mouseWheel = mouseWheel
        self.shortcuts = shortcuts
        self.codex = codex
        self.codexSync = codexSync
        self.finderFollow = finderFollow
        self.codexModels = codexModels
        self.codexRestarter = codexRestarter
        self.weChat = weChat
        self.togent = togent
        self.modelRelay = modelRelay
        self.workspaceOpener = workspaceOpener
        self.screenBlackout = screenBlackout ?? ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
        self.notify = notify
    }

    func attachWeChat(_ controller: WeChatAssociationControlling) {
        weChat = controller
    }

    func attachTogent(_ service: any TocodeTogentCommanding) {
        togent = service
    }

    func attachModelRelay(_ service: any TocodeModelRelayCommanding) {
        modelRelay = service
    }

    func execute(_ command: TocodeCommand) -> TocodeCommandResult {
        switch command {
        case .help:
            return .success(TocodeCommandOutput(TocodeCommandParser.helpText))
        case .status:
            return .success(TocodeCommandOutput(lines: statusLines()))
        case .root(let subcommand):
            return executeRoot(subcommand)
        case .finder(let subcommand):
            return executeFinder(subcommand)
        case .codex(let subcommand):
            return executeCodex(subcommand)
        case .wechat(.send):
            return .failure(.operationFailed("wechat send 需要通过 CLI 异步执行"))
        case .wechat(let subcommand):
            return executeWechat(subcommand)
        case .togent(let subcommand):
            return executeTogent(subcommand)
        case .model(.portSet):
            return .failure(.operationFailed("model port 设置需要通过 CLI 异步执行"))
        case .model(let subcommand):
            return executeModel(subcommand)
        case .blackout:
            let alreadyPresented = screenBlackout.isPresented
            screenBlackout.activate()
            return .success(TocodeCommandOutput(
                alreadyPresented ? "✅ 黑屏已在显示中，无需重复触发" : "✅ 已触发临时黑屏，按任意键或点击恢复"
            ))
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
            return .success(TocodeCommandOutput("✅ 已请求退出 Tocode"))
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

    func executeAsync(_ command: TocodeCommand) async -> TocodeCommandResult {
        if case .wechat(.send(let payload)) = command {
            return await weChat.sendOutbound(payload)
        }
        if case .model(.portSet(let port)) = command {
            return await executeModelPortSet(port)
        }
        return execute(command)
    }

    func executeAsync(_ body: String) async -> TocodeCommandResult {
        switch TocodeCommandParser.parse(body) {
        case .failure(let error):
            return .failure(error)
        case .success(let command):
            return await executeAsync(command)
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
        let togentLine: String
        if let startupError = togent?.startupError {
            togentLine = "Togent：不可用（\(startupError.localizedDescription)）"
        } else if let roles = togent?.roles {
            if let active = roles.first(where: \.isActive) {
                let modelText = active.publishedModelID.isEmpty ? "未配置" : active.publishedModelID
                togentLine = "Togent：\(active.name)（激活，模型 \(modelText)，共 \(roles.count) 个角色）"
            } else {
                togentLine = "Togent：无激活角色（共 \(roles.count) 个角色）"
            }
        } else {
            togentLine = "Togent：未就绪"
        }
        let relayLine: String
        if let status = modelRelay?.cliStatus() {
            let provider = status.lastUsedProviderName ?? "无"
            relayLine = "模型中转：\(status.runStateText)；\(status.baseURL)；最近厂家 \(provider)；近六小时调用 \(status.callCountLast6Hours)"
        } else {
            relayLine = "模型中转：未就绪"
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
            togentLine,
            relayLine,
            projectLine,
            "访达跟随：\(finderFollow.followEnabled ? "开" : "关")",
            "codex跟随：\(syncEnabled ? "开" : "关")",
            modelLine
        ]
    }

    // MARK: - root

    private func executeRoot(_ subcommand: TocodeRootCommand) -> TocodeCommandResult {
        switch subcommand {
        case .get:
            return .success(TocodeCommandOutput(
                "根目录：\(store.resolveRoot(isDirectory: fs.isExistingDirectory))"
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
        case .finderFollow(let toggle):
            return applyToggle(toggle, current: finderFollow.followEnabled) { target in
                finderFollow.followEnabled = target
                return .success(())
            }
        case .clipboard:
            return executeRootClipboard()
        case .open:
            return executeRootOpen()
        }
    }

    private func executeRootClipboard() -> TocodeCommandResult {
        guard let raw = clipboard.read() else {
            return .failure(.operationFailed("剪贴板为空或不是文本"))
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(.operationFailed("剪贴板为空或不是文本"))
        }
        guard !text.hasPrefix("\u{300C}") else {
            return .failure(.operationFailed("剪贴板路径带「」包裹，请粘贴纯路径"))
        }
        let standardized = (text as NSString).standardizingPath
        guard fs.isExistingDirectory(standardized) else {
            return .failure(.rootNotFound(text))
        }
        store.save(standardized)
        notify("根目录已更新", standardized)
        return .success(TocodeCommandOutput("已设置根目录：\(standardized)"))
    }

    private func executeRootOpen() -> TocodeCommandResult {
        let root = store.resolveRoot(isDirectory: fs.isExistingDirectory)
        guard fs.isExistingDirectory(root) else {
            return .failure(.rootNotFound(root))
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
        return .success(TocodeCommandOutput("已在访达打开根目录：\(root)"))
    }

    private func executeFinder(_ subcommand: TocodeFinderCommand) -> TocodeCommandResult {
        switch subcommand {
        case .copy:
            switch finderSelection.resolveSelectedItemPath() {
            case .failure(let error):
                return .failure(.finderSelectionFailed(error.commandMessage))
            case .success(let path):
                clipboard.copyPath(path)
                return .success(TocodeCommandOutput("已复制路径：\(path)"))
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
                "✅ 已切换模型 \(id)；2 秒后强制重启 Codex"
            ))
        }
    }

    // MARK: - wechat

    private func executeWechat(_ subcommand: TocodeWechatCommand) -> TocodeCommandResult {
        switch subcommand {
        case .status:
            return .success(TocodeCommandOutput(
                weChat.isBound ? "✅ 微信已绑定" : "ℹ️ 微信未绑定，可执行 .wechat bind 触发扫码"
            ))
        case .bind:
            weChat.startBinding()
            return .success(TocodeCommandOutput("已触发微信扫码绑定"))
        case .send:
            return .failure(.operationFailed("wechat send 需要通过 CLI 异步执行"))
        }
    }

    // MARK: - Togent

    private func executeTogent(_ subcommand: TocodeTogentCommand) -> TocodeCommandResult {
        guard let togent else {
            return .failure(.operationFailed("Togent 未就绪"))
        }
        if let startupError = togent.startupError {
            return .failure(.operationFailed("Togent 不可用：\(startupError.localizedDescription)"))
        }
        switch subcommand {
        case .list:
            let roles = togent.roles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if roles.isEmpty {
                return .success(TocodeCommandOutput("暂无 Togent 角色"))
            }
            let capabilityByID = Dictionary(
                uniqueKeysWithValues: togent.models.map {
                    ($0.publishedModelID, $0.capabilityTitle)
                }
            )
            let lines = roles.map { role -> String in
                let active = role.isActive ? "激活" : "未激活"
                let model = role.publishedModelID.isEmpty
                    ? "未配置"
                    : "\(role.publishedModelID)（\(capabilityByID[role.publishedModelID] ?? "已失效")）"
                return "\(role.name)\t\(active)\t\(model)\t\(role.workspacePath)"
            }
            return .success(TocodeCommandOutput(lines: lines))
        case .show(let name):
            guard let role = role(named: name, in: togent) else {
                return .failure(.operationFailed("未找到角色：\(name)"))
            }
            let capability = togent.models.first {
                $0.publishedModelID == role.publishedModelID
            }?.capabilityTitle
            let model = role.publishedModelID.isEmpty
                ? "未配置"
                : "\(role.publishedModelID)（\(capability ?? "已失效")）"
            return .success(TocodeCommandOutput(lines: [
                "名称：\(role.name)",
                "激活：\(role.isActive ? "是" : "否")",
                "工作区：\(role.workspacePath)",
                "模型：\(model)",
                "提示词：",
                role.prompt.isEmpty ? "（空）" : role.prompt
            ]))
        case .models:
            return .success(TocodeCommandOutput(lines: modelDirectoryLines(togent.models)))
        case .create(let options):
            do {
                var draft = togent.newRoleDraft()
                apply(options, to: &draft, defaultPathFromName: true, togent: togent)
                let role = try togent.createRole(from: draft)
                return .success(TocodeCommandOutput(
                    "✅ 已创建角色 \(role.name)\n工作区：\(role.workspacePath)\n模型：\(role.publishedModelID.isEmpty ? "未配置" : role.publishedModelID)\n激活：\(role.isActive ? "是" : "否")"
                ))
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        case .copy(let sourceName, let options):
            guard let sourceOption = togent.roleCopyOptions().first(where: {
                $0.sourceRoleName.caseInsensitiveCompare(sourceName) == .orderedSame
            }) else {
                return .failure(.operationFailed("未找到可复制的源角色：\(sourceName)"))
            }
            do {
                var draft = sourceOption.draft
                apply(options, to: &draft, defaultPathFromName: true, togent: togent)
                let role = try togent.createRole(from: draft)
                return .success(TocodeCommandOutput(
                    "✅ 已从 \(sourceName) 复制出角色 \(role.name)\n工作区：\(role.workspacePath)\n模型：\(role.publishedModelID.isEmpty ? "未配置" : role.publishedModelID)\n激活：否"
                ))
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        case .update(let name, let options):
            guard let existing = role(named: name, in: togent) else {
                return .failure(.operationFailed("未找到角色：\(name)"))
            }
            do {
                var draft = TogentRoleDraft(role: existing)
                apply(options, to: &draft, defaultPathFromName: false, togent: togent)
                let role = try togent.updateRole(id: existing.id, from: draft)
                return .success(TocodeCommandOutput(
                    "✅ 已更新角色 \(role.name)\n工作区：\(role.workspacePath)\n模型：\(role.publishedModelID.isEmpty ? "未配置" : role.publishedModelID)\n激活：\(role.isActive ? "是" : "否")"
                ))
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        case .open(let name):
            guard let role = role(named: name, in: togent) else {
                return .failure(.operationFailed("未找到角色：\(name)"))
            }
            guard openTogentWorkspace(at: role.workspacePath, opener: workspaceOpener) else {
                return .failure(.operationFailed("无法打开已保存的角色工作区：\(role.workspacePath)"))
            }
            return .success(TocodeCommandOutput("已打开角色工作区：\(role.workspacePath)"))
        }
    }

    private func apply(
        _ options: TocodeTogentRoleOptions,
        to draft: inout TogentRoleDraft,
        defaultPathFromName: Bool,
        togent: any TocodeTogentCommanding
    ) {
        if let name = options.name {
            draft.name = name
            if defaultPathFromName, options.workspacePath == nil {
                draft.workspacePath = togent.defaultWorkspacePath(forRoleName: name)
            }
        }
        if let path = options.workspacePath {
            draft.workspacePath = path
        }
        if let model = options.publishedModelID {
            draft.publishedModelID = model
        }
        if let active = options.isActive {
            draft.isActive = active
        }
        if let prompt = options.prompt {
            draft.prompt = prompt
        }
    }

    private func role(named name: String, in togent: any TocodeTogentCommanding) -> TogentRole? {
        togent.roles.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    // MARK: - 模型中转

    private func executeModel(_ subcommand: TocodeModelCommand) -> TocodeCommandResult {
        guard let modelRelay else {
            return .failure(.operationFailed("模型中转未就绪"))
        }
        switch subcommand {
        case .status:
            let status = modelRelay.cliStatus()
            return .success(TocodeCommandOutput(lines: [
                status.runStateText,
                "Base URL：\(status.baseURL)",
                "端口：\(status.port)",
                "最近厂家：\(status.lastUsedProviderName ?? "无")",
                "近六小时调用：\(status.callCountLast6Hours)"
            ]))
        case .portGet:
            return .success(TocodeCommandOutput("端口：\(modelRelay.cliStatus().port)"))
        case .portSet:
            return .failure(.operationFailed("model port 设置需要通过 CLI 异步执行"))
        case .models:
            return .success(TocodeCommandOutput(lines: modelDirectoryLines(
                modelRelay.availableTogentModels()
            )))
        case .log:
            do {
                let url = try modelRelay.todayCallLogURL()
                guard workspaceOpener.open(url) else {
                    return .failure(.operationFailed("无法打开今日调用日志：\(url.path)"))
                }
                return .success(TocodeCommandOutput("已打开今日调用日志：\(url.path)"))
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        }
    }

    private func executeModelPortSet(_ port: Int) async -> TocodeCommandResult {
        guard let modelRelay else {
            return .failure(.operationFailed("模型中转未就绪"))
        }
        do {
            try await modelRelay.updatePort(port)
            return .success(TocodeCommandOutput("✅ 已设置模型中转端口：\(port)"))
        } catch {
            return .failure(.operationFailed(error.localizedDescription))
        }
    }

    private func modelDirectoryLines(_ models: [TogentModelOption]) -> [String] {
        if models.isEmpty {
            return ["无健康模型"]
        }
        return models.map {
            "\($0.publishedModelID)\t\($0.providerName)\t\($0.capabilityTitle)"
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

private extension FinderSelectionError {
    var commandMessage: String {
        switch self {
        case .notExactlyOne:
            return "访达需要恰好选中一项"
        case .notPermitted:
            return "没有控制访达的权限"
        case .scriptFailed:
            return "读取访达选中项失败"
        case .invalidPath:
            return "访达选中项路径无效"
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
