import AppKit
import Foundation

private final class MockTogentWorkspaceOpener: TogentWorkspaceOpening {
    var result = true
    private(set) var urls: [URL] = []

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return result
    }
}

func testTogentStoreAndUniqueActivation() {
    let root = makeTogentTemporaryDirectory("store")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("togent.sqlite")
    let store = TogentStore(databaseURL: database)
    let firstWorkspace = root.appendingPathComponent("role-one")
    let secondWorkspace = root.appendingPathComponent("role-two")

    let first = try! store.insertRole(
        makeTogentRole(name: "Alpha", workspace: firstWorkspace, active: false)
    )
    expect(first.isActive, "Togent 第一角色即使未勾选也自动激活")

    let second = try! store.insertRole(
        makeTogentRole(name: "Beta", workspace: secondWorkspace, active: true)
    )
    expect(second.isActive, "Togent 新勾选角色成为激活角色")
    expect(try! store.role(id: first.id)?.isActive == false, "激活新角色事务性取消旧角色")
    expect(try! store.roles().filter(\.isActive).count == 1, "Togent 注册表最多一个激活角色")

    try! store.setActiveRole(id: nil)
    expect(try! store.activeRole() == nil, "Togent 允许取消为无激活角色")

    do {
        _ = try store.insertRole(
            makeTogentRole(
                name: "alpha",
                workspace: root.appendingPathComponent("role-three")
            )
        )
        expect(false, "Togent 角色名应不区分大小写唯一")
    } catch TogentError.duplicateRoleName {
        expect(true, "Togent 角色名不区分大小写唯一")
    } catch {
        expect(false, "Togent 重复角色名返回明确错误")
    }

    let staged = try! store.stageJob(
        deduplicationKey: "recover-running",
        roleID: first.id,
        fromUserID: "wx-user",
        contextToken: "secret-context",
        messageText: "敏感任务正文",
        receivedAt: Date()
    )
    try! store.queueStagedJob(deduplicationKey: staged.deduplicationKey)
    try! store.markRunning(id: staged.id)
    try! store.recoverInterruptedJobs()
    let recovered = try! store.nextQueuedJob()
    expect(recovered?.id == staged.id && recovered?.attemptCount == 1,
           "App 重启把 running 任务恢复为原顺序 queued")
    try! store.markCompleted(id: staged.id)
    let finalized = (try! store.jobs()).first { $0.id == staged.id }!
    expect(
        finalized.state == .completed
            && finalized.fromUserID.isEmpty
            && finalized.contextToken.isEmpty
            && finalized.messageText.isEmpty,
        "任务收口后清除微信路由和 prompt 载荷"
    )

    let permissions = (try? FileManager.default.attributesOfItem(atPath: database.path)[
        .posixPermissions
    ] as? NSNumber)?.intValue
    expect(permissions == 0o600, "Togent SQLite 主文件权限为 0600")
    let sidecars = ["-wal", "-shm"].map {
        URL(fileURLWithPath: database.path + $0)
    }.filter {
        FileManager.default.fileExists(atPath: $0.path)
    }
    expect(sidecars.allSatisfy {
        ((try? FileManager.default.attributesOfItem(atPath: $0.path)[
            .posixPermissions
        ] as? NSNumber)?.intValue) == 0o600
    }, "Togent SQLite sidecar 文件权限为 0600")
}

func testTogentPersistedWorkspaceOpening() {
    let root = makeTogentTemporaryDirectory("workspace-opening")
    defer { try? FileManager.default.removeItem(at: root) }
    let persisted = root.appendingPathComponent("persisted", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: persisted,
        withIntermediateDirectories: true
    )
    let opener = MockTogentWorkspaceOpener()
    expect(
        openTogentWorkspace(at: persisted.path, opener: opener),
        "角色编辑弹窗可打开已保存工作区"
    )
    expect(opener.urls == [persisted], "工作区按钮使用持久化角色路径")
    expect(
        !openTogentWorkspace(
            at: root.appendingPathComponent("unsaved-missing").path,
            opener: opener
        ),
        "不存在的未保存表单路径不会被误打开"
    )
    expect(opener.urls == [persisted], "无效路径不会调用系统打开器")
}

func testTogentWorkspaceNumberingAndManagedAgents() {
    let home = makeTogentTemporaryDirectory("workspace")
    defer { try? FileManager.default.removeItem(at: home) }
    let service = TogentWorkspaceService(homeDirectory: home)
    let parent = home.appendingPathComponent("Documents/togent", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: parent.appendingPathComponent("role1"),
        withIntermediateDirectories: true
    )
    try! FileManager.default.createDirectory(
        at: parent.appendingPathComponent("role3"),
        withIntermediateDirectories: true
    )
    let registered = [parent.appendingPathComponent("role2").path]
    expect(
        service.nextDefaultRoleName(
            registeredNames: ["role2"],
            registeredPaths: registered
        ) == "role4",
        "默认英文角色名同时避开注册表与磁盘"
    )
    expect(
        service.defaultWorkspacePath(forRoleName: "Developer")
            == parent.appendingPathComponent("Developer").path,
        "默认工作区末级目录精确使用角色名称"
    )
    expect(
        service.nextCopyRoleName(
            sourceName: "Developer",
            registeredNames: ["role2"],
            registeredPaths: registered
        ) == "Developer-copy",
        "复制角色默认使用英文 source-copy 名称"
    )
    try! FileManager.default.createDirectory(
        at: parent.appendingPathComponent("Developer-copy"),
        withIntermediateDirectories: true
    )
    expect(
        service.nextCopyRoleName(
            sourceName: "Developer",
            registeredNames: ["role2"],
            registeredPaths: registered
        ) == "Developer-copy2",
        "复制角色名称冲突时递增 copy 序号"
    )
    let longSource = "A" + String(repeating: "b", count: 79)
    let longFirstCopy = String(longSource.prefix(75)) + "-copy"
    let longNextCopy = service.nextCopyRoleName(
        sourceName: longSource,
        registeredNames: [longFirstCopy],
        registeredPaths: []
    )
    expect(
        longNextCopy.count == TogentRoleName.maximumLength
            && longNextCopy.hasSuffix("-copy2")
            && TogentRoleName.isValid(longNextCopy),
        "长角色复制名保留完整 copyN 后缀并满足长度限制"
    )
    expect(
        service.nextCopyRoleName(
            sourceName: "旧角色",
            registeredNames: ["role2"],
            registeredPaths: registered
        ) == "role4",
        "旧中文源角色复制时回退到新的英文 roleN"
    )
    var pathBinding = TogentRolePathBinding(
        workspacePath: parent.appendingPathComponent("role4").path,
        automatic: true
    )
    expect(
        pathBinding.workspacePath(afterNameChange: "Designer")
            == parent.appendingPathComponent("Designer").path,
        "新增角色改名同步尚未脱离管理的默认路径"
    )
    pathBinding.detach()
    expect(
        pathBinding.workspacePath(afterNameChange: "Writer") == nil,
        "用户自定义路径后名称变化不再覆盖路径"
    )
    expect(
        TogentRolePathBinding.isManagedDefaultWorkspace(
            roleName: "Designer",
            workspacePath: parent.appendingPathComponent("Designer").path,
            homeDirectory: home
        ),
        "名称路径策略识别受管默认工作区"
    )
    expect(
        TogentPrompts.creationTabTitles == ["从零新增", "拷贝角色"],
        "新增角色弹窗提供从零与拷贝页签"
    )

    let workspace = parent.appendingPathComponent("role4")
    var role = makeTogentRole(name: "Developer", workspace: workspace)
    let receipt = try! service.provision(role: role)
    expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("project").path),
           "角色保存创建 project 文件夹")
    let archiveURL = workspace.appendingPathComponent("wechat", isDirectory: true)
    expect(FileManager.default.fileExists(atPath: archiveURL.path),
           "角色保存创建独立 wechat 归档文件夹")
    let archivePermissions = (try? FileManager.default.attributesOfItem(
        atPath: archiveURL.path
    )[.posixPermissions] as? NSNumber)?.intValue
    expect(archivePermissions == 0o700, "角色 wechat 归档目录权限为 0700")
    let agentsURL = workspace.appendingPathComponent("AGENTS.md")
    var agents = try! String(contentsOf: agentsURL, encoding: .utf8)
    expect(agents.contains(TogentWorkspaceService.managedBegin), "AGENTS 含 Tocode 托管区块")
    expect(agents.contains("微信是唯一任务入口"), "AGENTS 声明微信唯一任务入口")
    expect(agents.contains(TogentWorkspaceService.memoryHeading), "AGENTS 预留角色记忆区")
    expect(agents.contains(archiveURL.path), "AGENTS 只记录当前角色归档路径")
    expect(!agents.contains("/Documents/wechat"), "AGENTS 不再引用全局微信归档")
    expect(receipt.createdRoot, "默认工作区首次由 Tocode 创建")

    agents += "\n用户保留内容\n"
    try! agents.write(to: agentsURL, atomically: true, encoding: .utf8)
    role.prompt = "新的角色规则"
    _ = try! service.provision(role: role)
    let updated = try! String(contentsOf: agentsURL, encoding: .utf8)
    expect(updated.contains("新的角色规则"), "编辑角色更新 AGENTS 托管区块")
    expect(updated.contains("用户保留内容"), "编辑角色保留 AGENTS 非托管内容")
    expect(
        updated.components(separatedBy: TogentWorkspaceService.managedBegin).count == 2,
        "AGENTS 托管区块幂等且不重复"
    )
}

func testTogentWorkspaceCanonicalIsolation() {
    let root = makeTogentTemporaryDirectory("canonical")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let firstURL = root.appendingPathComponent("first", isDirectory: true)
    try! FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
    let first = makeTogentRole(name: "One", workspace: firstURL)

    do {
        try workspace.validateIsolation(
            candidatePath: firstURL.appendingPathComponent("nested").path,
            existingRoles: [first]
        )
        expect(false, "Togent 拒绝互相嵌套的角色工作区")
    } catch TogentError.overlappingWorkspacePath {
        expect(true, "Togent 拒绝互相嵌套的角色工作区")
    } catch {
        expect(false, "Togent 嵌套工作区返回明确错误")
    }

    let symlink = root.appendingPathComponent("alias")
    try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: firstURL)
    do {
        try workspace.validateIsolation(candidatePath: symlink.path, existingRoles: [first])
        expect(false, "Togent canonical 路径拒绝 symlink 别名复用")
    } catch TogentError.duplicateWorkspacePath {
        expect(true, "Togent canonical 路径拒绝 symlink 别名复用")
    } catch {
        expect(false, "Togent symlink 冲突返回明确错误")
    }

    let archiveRole = makeTogentRole(
        name: "Archive",
        workspace: root.appendingPathComponent("archive-role")
    )
    _ = try! workspace.provision(role: archiveRole)
    let outside = root.appendingPathComponent("outside")
    try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let archive = URL(fileURLWithPath: archiveRole.workspacePath)
        .appendingPathComponent("wechat")
    try! FileManager.default.removeItem(at: archive)
    try! FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
    do {
        _ = try workspace.archiveDirectory(for: archiveRole)
        expect(false, "角色归档拒绝 symlink 越界")
    } catch TogentError.workspaceOutsideBoundary {
        expect(true, "角色归档拒绝 symlink 越界")
    } catch {
        expect(false, "角色归档 symlink 返回明确边界错误")
    }
    do {
        _ = try workspace.provision(role: archiveRole)
        expect(false, "角色工作区补齐拒绝既有 wechat symlink")
    } catch TogentError.workspaceOutsideBoundary {
        expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: archive.path
            )) != nil,
            "拒绝归档 symlink 时保留既有链接且不跟随删除目标"
        )
    } catch {
        expect(false, "工作区补齐 symlink 返回明确边界错误")
    }
}

@MainActor
func testTogentRoleNamingAndCopyIsolation() async {
    let root = makeTogentTemporaryDirectory("role-copy")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let model = TogentModelOption(publishedModelID: "healthy", providerName: "Provider")
    let alternateModel = TogentModelOption(
        publishedModelID: "alternate",
        providerName: "Alternate"
    )
    let service = TogentService(
        store: store,
        workspace: workspace,
        runtime: StubTogentRuntime(),
        availableModelOptions: { [model, alternateModel] },
        bootstrapDefaultRole: false
    )

    expect(
        ["Alpha", "qa-agent", "Role_2", "z9"].allSatisfy(TogentRoleName.isValid),
        "角色名接受英文字母开头及后续字母数字连字符下划线"
    )
    expect(
        [
            "",
            "9role",
            "-role",
            "_role",
            "角色",
            "two words",
            "a/b",
            "A.B",
            "🙂",
            String(repeating: "a", count: 81)
        ]
            .allSatisfy { !TogentRoleName.isValid($0) },
        "角色名拒绝空值、非字母开头、中文、空格、点、路径字符、emoji 与超长值"
    )
    let initial = service.newRoleDraft()
    expect(
        initial.name == "role1"
            && initial.workspacePath.hasSuffix("/Documents/togent/role1"),
        "从零新增预填最小未占用英文 roleN 及同名默认路径"
    )

    var invalid = initial
    invalid.name = "中文角色"
    do {
        _ = try service.createRole(from: invalid)
        expect(false, "服务边界拒绝非英文角色名")
    } catch TogentError.invalidRoleName {
        expect(true, "非英文角色名返回明确错误")
    } catch {
        expect(false, "非英文角色名错误类型正确")
    }

    var sourceDraft = initial
    sourceDraft.name = "Developer"
    sourceDraft.workspacePath = workspace.defaultWorkspacePath(forRoleName: sourceDraft.name)
    sourceDraft.prompt = "Source prompt"
    sourceDraft.publishedModelID = model.publishedModelID
    sourceDraft.isActive = true
    let source = try! service.createRole(from: sourceDraft)
    let sourceRoot = URL(fileURLWithPath: source.workspacePath)
    let sourceProject = sourceRoot.appendingPathComponent("project/source-only.txt")
    try! Data("source".utf8).write(to: sourceProject)
    try! Data("source-wechat".utf8).write(
        to: sourceRoot.appendingPathComponent("wechat/source-history.md")
    )
    let sourceAgents = sourceRoot.appendingPathComponent("AGENTS.md")
    var sourceAgentsText = try! String(contentsOf: sourceAgents, encoding: .utf8)
    sourceAgentsText += "\nsource-private-memory\n"
    try! sourceAgentsText.write(to: sourceAgents, atomically: true, encoding: .utf8)
    let sourceSession = root
        .appendingPathComponent("runtime/\(source.id.uuidString)/sessions", isDirectory: true)
        .appendingPathComponent("source.jsonl")
    try! FileManager.default.createDirectory(
        at: sourceSession.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try! Data("source-session".utf8).write(to: sourceSession)
    let sourceJob = try! store.stageJob(
        deduplicationKey: "source-job",
        roleID: source.id,
        fromUserID: "source-user",
        contextToken: "source-context",
        messageText: "source-message",
        receivedAt: Date()
    )
    try! store.markCompleted(id: sourceJob.id)

    var duplicate = service.newRoleDraft()
    duplicate.name = "developer"
    duplicate.workspacePath = workspace.defaultWorkspacePath(forRoleName: "developer-other")
    duplicate.publishedModelID = model.publishedModelID
    do {
        _ = try service.createRole(from: duplicate)
        expect(false, "角色名大小写不敏感唯一")
    } catch TogentError.duplicateRoleName {
        expect(true, "角色名大小写不敏感唯一")
    } catch {
        expect(false, "大小写重复名称返回明确错误")
    }

    var writerDraft = service.newRoleDraft()
    writerDraft.name = "Writer"
    writerDraft.workspacePath = workspace.defaultWorkspacePath(forRoleName: writerDraft.name)
    writerDraft.prompt = "Writer prompt"
    writerDraft.publishedModelID = alternateModel.publishedModelID
    writerDraft.isActive = false
    let writer = try! service.createRole(from: writerDraft)

    let options = service.roleCopyOptions()
    expect(options.count == 2,
           "复制页签按现有角色提供来源")
    let sourceOption = options.first(where: { $0.sourceRoleID == source.id })!
    let writerOption = options.first(where: { $0.sourceRoleID == writer.id })!
    expect(
        writerOption.draft.prompt == writer.prompt
            && writerOption.draft.publishedModelID == writer.publishedModelID,
        "切换复制源可回显对应提示词与模型选择"
    )
    let popup = NSPopUpButton(
        frame: NSRect(x: 0, y: 0, width: 300, height: 28),
        pullsDown: false
    )
    for option in options {
        popup.addItem(withTitle: option.sourceRoleName)
    }
    let fields = TogentRoleFormFields(
        draft: sourceOption.draft,
        models: [model, alternateModel],
        automaticPath: true
    )
    let sourceController = TogentRoleCopySourceController(
        popup: popup,
        options: options,
        fields: fields
    )
    popup.selectItem(at: options.firstIndex(of: writerOption)!)
    sourceController.sourceChanged(popup)
    expect(
        fields.draft == writerOption.draft,
        "复制页签切换源角色后完整回显该源的复制草稿"
    )

    let copiedDraft = sourceOption.draft
    expect(
        copiedDraft.name == "Developer-copy"
            && copiedDraft.workspacePath.hasSuffix(
                "/Documents/togent/Developer-copy"
            )
            && copiedDraft.prompt == source.prompt
            && copiedDraft.publishedModelID == source.publishedModelID
            && !copiedDraft.isActive,
        "复制模板只继承提示词和模型并生成新名称、新路径、非激活状态"
    )

    let copied = try! service.createRole(from: copiedDraft)
    let copiedRoot = URL(fileURLWithPath: copied.workspacePath)
    expect(
        copied.id != source.id
            && copied.createdAt != source.createdAt
            && !copied.isActive
            && service.roles.first(where: { $0.id == source.id })?.isActive == true,
        "复制保存生成新身份且不改变源角色激活状态"
    )
    expect(
        FileManager.default.fileExists(
            atPath: copiedRoot.appendingPathComponent("AGENTS.md").path
        )
            && FileManager.default.fileExists(
                atPath: copiedRoot.appendingPathComponent("project").path
            )
            && FileManager.default.fileExists(
                atPath: copiedRoot.appendingPathComponent("wechat").path
            )
            && !FileManager.default.fileExists(
                atPath: copiedRoot.appendingPathComponent("project/source-only.txt").path
            )
            && !FileManager.default.fileExists(
                atPath: copiedRoot.appendingPathComponent("wechat/source-history.md").path
            ),
        "复制角色只初始化独立工作区三件套且不复制源 project 或微信归档"
    )
    let copiedAgents = try! String(
        contentsOf: copiedRoot.appendingPathComponent("AGENTS.md"),
        encoding: .utf8
    )
    expect(
        !copiedAgents.contains("source-private-memory")
            && !FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent(
                        "runtime/\(copied.id.uuidString)/sessions/source.jsonl"
                    )
                    .path
            )
            && (try! store.jobs()).contains(where: { $0.roleID == source.id })
            && !(try! store.jobs()).contains(where: { $0.roleID == copied.id }),
        "复制角色不复制 AGENTS 记忆、session、任务或去重状态"
    )
    service.stop()
}

@MainActor
func testTogentDefaultRoleBootstrap() async {
    let root = makeTogentTemporaryDirectory("default-role")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let runtime = StubTogentRuntime()
    var relayFingerprintRead = false
    let service = TogentService(
        store: store,
        workspace: workspace,
        runtime: runtime,
        availableModelOptions: { [] },
        relayFingerprint: {
            relayFingerprintRead = true
            return ""
        }
    )
    expect(
        !relayFingerprintRead,
        "默认角色启动不读取可能阻塞的 Relay 钥匙串"
    )
    let roles = service.roles
    expect(roles.count == 1, "空角色库首启只创建一个默认角色")
    let role = roles[0]
    expect(
        role.name == TogentService.defaultRoleName && role.isActive,
        "默认角色命名为 default 并自动激活"
    )
    expect(
        role.prompt == TogentService.defaultRolePrompt
            && !role.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "default 写入非空内置角色提示词"
    )
    expect(
        ["虚构 AI 角色", "20 岁", "中国女大学生", "简体中文", "完成用户任务"]
            .allSatisfy(role.prompt.contains),
        "default 提示词冻结虚构成年女大学生身份与任务优先语义"
    )
    expect(
        TogentRoleDraft(role: role).prompt == TogentService.defaultRolePrompt,
        "角色编辑弹窗的数据源回显 default 内置提示词"
    )
    expect(role.publishedModelID.isEmpty, "默认角色模型初始为未配置")
    expect(role.workspacePath.hasSuffix("/Documents/togent/default"),
           "default 角色工作区末级目录使用角色名称")
    expect(FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: role.workspacePath)
            .appendingPathComponent("project")
            .path
    ), "默认角色自动创建 project")
    expect(FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: role.workspacePath)
            .appendingPathComponent("wechat")
            .path
    ), "默认角色自动创建私有 wechat")
    let agents = try! String(
        contentsOf: URL(fileURLWithPath: role.workspacePath)
            .appendingPathComponent("AGENTS.md"),
        encoding: .utf8
    )
    expect(
        agents.contains(TogentService.defaultRolePrompt),
        "default 内置提示词同步写入 AGENTS 托管区块"
    )

    var edit = TogentRoleDraft(role: role)
    edit.prompt = "无模型时仍可维护默认角色"
    do {
        _ = try service.updateRole(id: role.id, from: edit)
        expect(true, "未配置模型的默认角色可保存其他字段")
    } catch {
        expect(false, "未配置模型默认角色保存失败：\(error)")
    }

    let restarted = TogentService(
        store: store,
        workspace: workspace,
        runtime: StubTogentRuntime(),
        availableModelOptions: { [] }
    )
    expect(restarted.roles.count == 1, "重复启动不会重复创建默认角色")
    expect(
        restarted.roles.first?.prompt == edit.prompt,
        "重复启动保留用户编辑后的 default 提示词"
    )
    service.stop()
    restarted.stop()

    let failureHome = makeTogentTemporaryDirectory("default-role-failure")
    defer { try? FileManager.default.removeItem(at: failureHome) }
    _ = FileManager.default.createFile(
        atPath: failureHome.appendingPathComponent("Documents").path,
        contents: Data()
    )
    let failureStore = TogentStore(
        databaseURL: failureHome.appendingPathComponent("state/togent.sqlite")
    )
    let failed = TogentService(
        store: failureStore,
        workspace: TogentWorkspaceService(homeDirectory: failureHome),
        runtime: StubTogentRuntime(),
        availableModelOptions: { [] }
    )
    expect(failed.startupError != nil, "默认角色工作区初始化失败会明确阻断启动")
    expect(failed.roles.isEmpty, "默认角色工作区失败不留下半成品 registry")
    failed.stop()

    let existingHome = makeTogentTemporaryDirectory("existing-role")
    defer { try? FileManager.default.removeItem(at: existingHome) }
    let existingStore = TogentStore(
        databaseURL: existingHome.appendingPathComponent("state/togent.sqlite")
    )
    var existingRole = makeTogentRole(
        name: "已有角色",
        workspace: existingHome.appendingPathComponent("workspace"),
        active: true
    )
    existingRole.prompt = "用户自定义提示词"
    _ = try! existingStore.insertRole(existingRole)
    let existingService = TogentService(
        store: existingStore,
        workspace: TogentWorkspaceService(homeDirectory: existingHome),
        runtime: StubTogentRuntime(),
        availableModelOptions: { [] }
    )
    let preservedRoles = existingService.roles
    expect(
        preservedRoles.count == 1
            && preservedRoles[0].id == existingRole.id
            && preservedRoles[0].name == existingRole.name
            && preservedRoles[0].workspacePath == existingRole.workspacePath
            && preservedRoles[0].prompt == existingRole.prompt
            && preservedRoles[0].publishedModelID == existingRole.publishedModelID
            && preservedRoles[0].isActive == existingRole.isActive,
        "已有角色库不新增 default 且不覆盖用户名称或提示词"
    )
    existingService.stop()
}

@MainActor
func testTogentRoleServiceModelGate() async {
    let root = makeTogentTemporaryDirectory("role-service")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let runtime = StubTogentRuntime()
    var options = [TogentModelOption(publishedModelID: "healthy", providerName: "厂家")]
    let service = TogentService(
        store: store,
        workspace: workspace,
        runtime: runtime,
        availableModelOptions: { options },
        bootstrapDefaultRole: false
    )
    var draft = service.newRoleDraft()
    draft.name = "MainRole"
    draft.publishedModelID = "healthy"
    let role = try! service.createRole(from: draft)
    expect(role.isActive, "Togent 服务创建首角色后激活")
    expect(role.workspacePath == (try! workspace.canonicalPath(draft.workspacePath)),
           "Togent 持久化 canonical 工作区路径")

    options = []
    var edit = TogentRoleDraft(role: role)
    edit.prompt = "只改提示词"
    do {
        _ = try service.updateRole(id: role.id, from: edit)
        expect(false, "模型失效时角色保存不得继续")
    } catch TogentError.modelUnavailable {
        expect(true, "模型失效时角色保存明确失败")
    } catch {
        expect(false, "模型失效返回明确错误")
    }
}

@MainActor
func testTogentBusyRoleAndRelayBoundary() async {
    let root = makeTogentTemporaryDirectory("role-boundary")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let runtime = StubTogentRuntime()
    let options = [TogentModelOption(publishedModelID: "healthy", providerName: "厂家")]
    var relayFingerprint = "http://127.0.0.1:28080/v1\nhealthy"
    let service = TogentService(
        store: store,
        workspace: workspace,
        runtime: runtime,
        availableModelOptions: { options },
        relayFingerprint: { relayFingerprint },
        bootstrapDefaultRole: false
    )
    var draft = service.newRoleDraft()
    draft.name = "BusyRole"
    draft.publishedModelID = "healthy"
    let role = try! service.createRole(from: draft)
    _ = try! store.stageJob(
        deduplicationKey: "busy-job",
        roleID: role.id,
        fromUserID: "wx-user",
        contextToken: "ctx",
        messageText: "待处理",
        receivedAt: Date()
    )
    try! store.queueStagedJob(deduplicationKey: "busy-job")
    expect(service.isBusy, "排队任务使 Togent 进入忙碌状态")

    var promptOnly = TogentRoleDraft(role: role)
    promptOnly.prompt = "忙碌时仍允许修订提示词"
    do {
        _ = try service.updateRole(id: role.id, from: promptOnly)
        expect(true, "忙碌时允许仅修改角色提示词")
    } catch {
        expect(false, "仅修改提示词不应改变运行边界：\(error)")
    }

    var deactivate = promptOnly
    deactivate.isActive = false
    do {
        _ = try service.updateRole(id: role.id, from: deactivate)
        expect(false, "队列非空时不得切换激活角色")
    } catch TogentError.busy {
        expect(true, "队列非空时切换角色返回 busy")
    } catch {
        expect(false, "忙碌切换角色应返回明确错误")
    }

    service.relayDidChange()
    try? await Task.sleep(nanoseconds: 50_000_000)
    expect(runtime.stopAllCount == 0, "相同 Relay 指纹不重启 Pi")
    relayFingerprint = "http://127.0.0.1:29090/v1\nhealthy"
    service.relayDidChange()
    let stoppedForPort = await waitForTogentCondition {
        runtime.stopAllCount == 1
    }
    expect(stoppedForPort, "Relay 端口变化停止现有 Pi")
    relayFingerprint = "http://127.0.0.1:29090/v1"
    service.relayDidChange()
    let stoppedForModel = await waitForTogentCondition {
        runtime.stopAllCount == 2
    }
    expect(stoppedForModel, "健康模型消失停止现有 Pi")
}
