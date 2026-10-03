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
        at: parent.appendingPathComponent("角色1"),
        withIntermediateDirectories: true
    )
    try! FileManager.default.createDirectory(
        at: parent.appendingPathComponent("角色3"),
        withIntermediateDirectories: true
    )
    let registered = [parent.appendingPathComponent("角色2").path]
    expect(
        service.defaultWorkspacePath(registeredPaths: registered)
            == parent.appendingPathComponent("角色4").path,
        "默认角色目录编号同时避开注册表与磁盘"
    )

    let workspace = parent.appendingPathComponent("角色4")
    var role = makeTogentRole(name: "开发", workspace: workspace)
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
    let first = makeTogentRole(name: "一", workspace: firstURL)

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
        name: "归档",
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
    expect(role.name == "默认角色" && role.isActive, "默认角色命名并自动激活")
    expect(role.publishedModelID.isEmpty, "默认角色模型初始为未配置")
    expect(role.workspacePath.hasSuffix("/Documents/togent/角色1"),
           "默认角色使用最小未占用角色编号")
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
    draft.name = "主角色"
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
    draft.name = "忙碌角色"
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
