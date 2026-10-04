import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
func testTogentWeChatArchiveQueueReplyIntegration() async {
    let root = makeTogentTemporaryDirectory("wechat-flow")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let runtime = StubTogentRuntime()
    runtime.result = .success("Agent 完成")
    let models = [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var roleDraft = togent.newRoleDraft()
    roleDraft.name = "微信角色"
    roleDraft.publishedModelID = "model-a"
    let role = try! togent.createRole(from: roleDraft)

    let first = WeChatMessage(
        fromUserID: "user",
        contextToken: "context-1",
        messageID: "message-1",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "第一条任务"))]
    )
    let second = WeChatMessage(
        fromUserID: "user",
        contextToken: "context-2",
        messageID: "message-2",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "第二条任务"))]
    )
    let transport = MockWeChatTransport()
    transport.updates = [
        .success(WeChatUpdates(messages: [first, second], cursor: "cursor-2")),
        .failure(CancellationError())
    ]
    let archiver = MockWeChatArchiver()
    var archiveWasCompleteAtExecution = true
    runtime.onExecute = {
        archiveWasCompleteAtExecution = archiveWasCompleteAtExecution
            && !archiver.messages.isEmpty
    }
    let state = MemoryWeChatStateStore()
    let credential = WeChatCredential(
        token: "bound",
        baseURL: WeChatILinkClient.officialBaseURL
    )
    let weChat = WeChatAssociationService(
        transport: transport,
        credentialStore: MemoryWeChatCredentialStore(credential),
        stateStore: state,
        archiver: archiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: togent
    )
    weChat.startBoundListener()
    let completed = await waitForTogentCondition {
        transport.sentTexts.count == 2
    }
    weChat.stop()
    togent.stop()

    expect(completed, "两条普通微信消息都收到 Agent 最终回复")
    expect(archiver.messages == [first, second], "普通微信消息按顺序先归档")
    let roleArchive = URL(fileURLWithPath: role.workspacePath, isDirectory: true)
        .appendingPathComponent("wechat", isDirectory: true)
    expect(archiver.roots == [roleArchive, roleArchive], "同一角色消息只进入自己的归档根")
    expect(archiveWasCompleteAtExecution, "每次 Togent 执行都发生在入站归档之后")
    expect(runtime.executions.count == 2, "普通消息调用几次就执行几次且不合并")
    expect(runtime.executions[0].1.contains("第一条任务"), "第一条微信任务先进入 Pi")
    expect(runtime.executions[1].1.contains("第二条任务"), "第二条微信任务后进入 Pi")
    expect(transport.sentTexts.map(\.text) == ["Agent 完成", "Agent 完成"],
           "只发送 agent settled 后的最终文本")
    let completedJobs = try! store.jobs()
    expect(completedJobs.allSatisfy { $0.state == .completed },
           "成功回复后持久任务全部收口 completed")
    expect(completedJobs.allSatisfy {
        $0.fromUserID.isEmpty && $0.contextToken.isEmpty && $0.messageText.isEmpty
    }, "回复结果持久化后清除已完成任务载荷")
    expect(state.state.cursor == "cursor-2", "staged 后持久化微信 cursor")
}

@MainActor
func testTogentWeChatNoRoleAndDuplicateFaults() async {
    let root = makeTogentTemporaryDirectory("wechat-fault")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let runtime = StubTogentRuntime()
    let models = [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    let message = WeChatMessage(
        fromUserID: "user",
        contextToken: "context",
        messageID: "duplicate",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "普通消息"))]
    )
    let transport = MockWeChatTransport()
    transport.updates = [
        .success(WeChatUpdates(messages: [message, message], cursor: "done")),
        .failure(CancellationError())
    ]
    let archiver = MockWeChatArchiver()
    let state = MemoryWeChatStateStore()
    let weChat = WeChatAssociationService(
        transport: transport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: state,
        archiver: archiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: togent
    )
    weChat.startBoundListener()
    _ = await waitForTogentCondition { transport.sentTexts.count == 1 }
    weChat.stop()
    togent.stop()

    expect(archiver.messages.isEmpty, "无激活角色时不创建任何全局或角色归档")
    expect(runtime.executions.isEmpty, "无激活角色时不启动 Pi")
    expect(transport.sentTexts.count == 1, "重复微信消息只回复一次错误")
    expect(transport.sentTexts.first?.text.contains("尚未激活") == true,
           "无激活角色向原会话明确回复")
    expect((try! store.jobs()).isEmpty, "无激活角色时不创建 Togent job")
    expect(state.state.recentKeys.count == 1, "无激活角色仍持久去重并推进消费状态")
}

@MainActor
func testTogentDefaultRoleModelGateAndRoleArchiveRouting() async {
    let modelGateRoot = makeTogentTemporaryDirectory("default-model-gate")
    defer { try? FileManager.default.removeItem(at: modelGateRoot) }
    let modelGateStore = TogentStore(
        databaseURL: modelGateRoot.appendingPathComponent("togent.sqlite")
    )
    let modelGateRuntime = StubTogentRuntime()
    let defaultTogent = TogentService(
        store: modelGateStore,
        workspace: TogentWorkspaceService(homeDirectory: modelGateRoot),
        runtime: modelGateRuntime,
        availableModelOptions: { [] }
    )
    let defaultRole = defaultTogent.roles.first!
    let defaultMessage = WeChatMessage(
        fromUserID: "default-user",
        contextToken: "default-context",
        messageID: "default-message",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "执行默认任务"))]
    )
    let defaultTransport = MockWeChatTransport()
    defaultTransport.updates = [
        .success(WeChatUpdates(messages: [defaultMessage], cursor: "default-cursor")),
        .failure(CancellationError())
    ]
    let defaultArchiver = MockWeChatArchiver()
    let defaultWeChat = WeChatAssociationService(
        transport: defaultTransport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: MemoryWeChatStateStore(),
        archiver: defaultArchiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: defaultTogent
    )
    defaultWeChat.startBoundListener()
    let modelGateCompleted = await waitForTogentCondition {
        defaultTransport.sentTexts.count == 1
    }
    defaultWeChat.stop()
    defaultTogent.stop()
    expect(modelGateCompleted, "默认角色未配置模型时仍消费普通消息")
    expect(defaultArchiver.roots == [
        URL(fileURLWithPath: defaultRole.workspacePath, isDirectory: true)
            .appendingPathComponent("wechat", isDirectory: true)
    ], "默认角色先归档到自身工作区")
    expect(modelGateRuntime.executions.isEmpty, "默认角色模型未配置时绝不启动 Pi")
    expect(
        defaultTransport.sentTexts.first?.text.contains("尚未配置模型") == true,
        "模型未配置使用独立于模型失效的明确文案"
    )
    expect(
        (try! modelGateStore.jobs()).first?.state == .failed,
        "模型未配置任务有界收口为 failed"
    )

    let routingRoot = makeTogentTemporaryDirectory("role-routing")
    defer { try? FileManager.default.removeItem(at: routingRoot) }
    let routingRuntime = StubTogentRuntime()
    let model = TogentModelOption(publishedModelID: "route-model", providerName: "厂家")
    let routingTogent = TogentService(
        store: TogentStore(databaseURL: routingRoot.appendingPathComponent("togent.sqlite")),
        workspace: TogentWorkspaceService(homeDirectory: routingRoot),
        runtime: routingRuntime,
        availableModelOptions: { [model] },
        bootstrapDefaultRole: false
    )
    var firstDraft = routingTogent.newRoleDraft()
    firstDraft.name = "角色A"
    firstDraft.publishedModelID = model.publishedModelID
    let firstRole = try! routingTogent.createRole(from: firstDraft)
    var secondDraft = routingTogent.newRoleDraft()
    secondDraft.name = "角色B"
    secondDraft.publishedModelID = model.publishedModelID
    let secondRole = try! routingTogent.createRole(from: secondDraft)
    let archiveTransport = MockWeChatTransport()
    archiveTransport.mediaResult = .success(Data("角色隔离附件".utf8))
    let sharedArchiver = WeChatArchiveService(
        transport: archiveTransport,
        calendarProvider: makeArchiveCalendar
    )
    let archiveCalendar = makeArchiveCalendar()
    let receivedAt = archiveCalendar.date(from: DateComponents(
        year: 2026,
        month: 9,
        day: 7,
        hour: 8,
        minute: 9,
        second: 10
    ))!
    let media = WeChatMedia(
        encryptQueryParameter: "role-archive-media",
        aesKey: Data(repeating: 1, count: 16).base64EncodedString()
    )

    let firstMessage = WeChatMessage(
        fromUserID: "route-user",
        contextToken: "route-context-a",
        messageID: "route-a",
        items: [
            WeChatItem(type: 1, textItem: WeChatTextItem(text: "A 任务")),
            WeChatItem(
                type: 4,
                fileItem: WeChatFileItem(fileName: "角色A.txt", media: media)
            )
        ]
    )
    let firstTransport = MockWeChatTransport()
    firstTransport.updates = [
        .success(WeChatUpdates(messages: [firstMessage], cursor: "route-cursor-a")),
        .failure(CancellationError())
    ]
    let firstWeChat = WeChatAssociationService(
        transport: firstTransport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: MemoryWeChatStateStore(),
        archiver: sharedArchiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        now: { receivedAt },
        togent: routingTogent
    )
    firstWeChat.startBoundListener()
    _ = await waitForTogentCondition { firstTransport.sentTexts.count == 1 }
    firstWeChat.stop()
    _ = await waitForTogentCondition { !routingTogent.isBusy }

    var activateSecond = TogentRoleDraft(role: secondRole)
    activateSecond.isActive = true
    _ = try! routingTogent.updateRole(id: secondRole.id, from: activateSecond)

    let secondMessage = WeChatMessage(
        fromUserID: "route-user",
        contextToken: "route-context-b",
        messageID: "route-b",
        items: [
            WeChatItem(type: 1, textItem: WeChatTextItem(text: "B 任务")),
            WeChatItem(
                type: 4,
                fileItem: WeChatFileItem(fileName: "角色B.txt", media: media)
            )
        ]
    )
    let secondTransport = MockWeChatTransport()
    secondTransport.updates = [
        .success(WeChatUpdates(messages: [secondMessage], cursor: "route-cursor-b")),
        .failure(CancellationError())
    ]
    let secondWeChat = WeChatAssociationService(
        transport: secondTransport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: MemoryWeChatStateStore(),
        archiver: sharedArchiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        now: { receivedAt },
        togent: routingTogent
    )
    secondWeChat.startBoundListener()
    _ = await waitForTogentCondition { secondTransport.sentTexts.count == 1 }
    secondWeChat.stop()
    _ = await waitForTogentCondition { !routingTogent.isBusy }

    let expectedRoots = [firstRole, secondRole].map {
        URL(fileURLWithPath: $0.workspacePath, isDirectory: true)
            .appendingPathComponent("wechat", isDirectory: true)
    }
    let archiveDays = expectedRoots.map {
        $0.appendingPathComponent("260907", isDirectory: true)
    }
    let archiveMarkdown = archiveDays.map {
        try? String(
            contentsOf: $0.appendingPathComponent("wechat260907.md"),
            encoding: .utf8
        )
    }
    let archiveFiles = archiveDays.map {
        (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
    }
    expect(
        archiveMarkdown[0]?.contains("A 任务") == true
            && archiveMarkdown[0]?.contains("B 任务") == false
            && archiveFiles[0].contains(where: { $0.contains("角色A.txt") })
            && !archiveFiles[0].contains(where: { $0.contains("角色B.txt") }),
        "角色 A 的日志和附件只落到角色 A 工作区"
    )
    expect(
        archiveMarkdown[1]?.contains("B 任务") == true
            && archiveMarkdown[1]?.contains("A 任务") == false
            && archiveFiles[1].contains(where: { $0.contains("角色B.txt") })
            && !archiveFiles[1].contains(where: { $0.contains("角色A.txt") }),
        "角色 B 的日志和附件只落到角色 B 工作区"
    )
    expect(archiveTransport.mediaDescriptors.count == 2, "角色 A/B 附件均通过真实归档器下载")
    expect(
        routingRuntime.executions.map { $0.0.id } == [firstRole.id, secondRole.id],
        "归档与任务执行始终使用同一个收到时角色"
    )
    let firstAttachment = archiveFiles[0].first { $0.contains("角色A.txt") }!
    let secondAttachment = archiveFiles[1].first { $0.contains("角色B.txt") }!
    expect(
        routingRuntime.executions[0].1.contains("wechat/260907/\(firstAttachment)")
            && routingRuntime.executions[1].1.contains("wechat/260907/\(secondAttachment)"),
        "每个任务只收到本次真实归档生成的精确工作区相对附件路径"
    )
    expect(
        !routingRuntime.executions[0].1.contains(secondRole.workspacePath)
            && !routingRuntime.executions[1].1.contains(firstRole.workspacePath)
            && routingRuntime.executions.allSatisfy {
                !$0.1.lowercased().contains("base64")
                    && !$0.1.contains("角色隔离附件")
            },
        "任务提示不复制附件正文/base64，也不泄露另一角色路径"
    )

    let lease = try! routingTogent.beginInbound()!
    do {
        try routingTogent.stageInbound(
            message: secondMessage,
            deduplicationKey: "malicious-receipt",
            receivedAt: receivedAt,
            lease: lease,
            archiveReceipt: WeChatArchiveReceipt(
                logRelativePath: "wechat/260907/wechat260907.md",
                attachmentRelativePaths: ["wechat/../角色A/secret.jpg"]
            )
        )
        expect(false, "Togent 不得接受调用方伪造的路径穿越收据")
    } catch TogentError.workspaceOutsideBoundary {
        expect(true, "Togent 在任务持久化前再次拒绝越界附件路径")
    } catch {
        expect(false, "越界附件路径返回明确角色边界错误")
    }
    var switchDuringArchive = TogentRoleDraft(role: firstRole)
    switchDuringArchive.isActive = true
    do {
        _ = try routingTogent.updateRole(id: firstRole.id, from: switchDuringArchive)
        expect(false, "归档租约期间不得切换角色")
    } catch TogentError.busy {
        expect(true, "归档租约期间角色边界修改返回 busy")
    } catch {
        expect(false, "归档租约期间返回明确 busy：\(error)")
    }
    routingTogent.endInbound(lease)
    routingTogent.stop()
}

@MainActor
func testTogentTwoPhaseRecoveryAndStateFailure() async {
    let root = makeTogentTemporaryDirectory("recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let workspace = TogentWorkspaceService(homeDirectory: root)
    let runtime = StubTogentRuntime()
    let models = [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    let togent = TogentService(
        store: store,
        workspace: workspace,
        runtime: runtime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var draft = togent.newRoleDraft()
    draft.name = "恢复角色"
    draft.publishedModelID = "model-a"
    let role = try! togent.createRole(from: draft)

    _ = try! store.stageJob(
        deduplicationKey: "committed",
        roleID: role.id,
        fromUserID: "user",
        contextToken: "context",
        messageText: "恢复我",
        receivedAt: Date()
    )
    _ = try! store.stageJob(
        deduplicationKey: "uncommitted",
        roleID: role.id,
        fromUserID: "user",
        contextToken: "context",
        messageText: "不要执行",
        receivedAt: Date()
    )
    var replies: [String] = []
    togent.replyHandler = { _, text in replies.append(text) }
    togent.recover(committedDeduplicationKeys: ["committed"])
    _ = await waitForTogentCondition { replies.count == 1 }
    expect(runtime.executions.count == 1, "重启只恢复已提交微信去重状态的 staged job")
    expect(runtime.executions.first?.1.contains("恢复我") == true, "恢复任务保留原消息")
    expect(!(try! store.jobs()).contains { $0.deduplicationKey == "uncommitted" },
           "未提交微信状态的 staged job 在恢复时删除")
    togent.stop()

    let failureRoot = makeTogentTemporaryDirectory("state-failure")
    defer { try? FileManager.default.removeItem(at: failureRoot) }
    let failureStore = TogentStore(
        databaseURL: failureRoot.appendingPathComponent("togent.sqlite")
    )
    let failureRuntime = StubTogentRuntime()
    let failureService = TogentService(
        store: failureStore,
        workspace: TogentWorkspaceService(homeDirectory: failureRoot),
        runtime: failureRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var failureDraft = failureService.newRoleDraft()
    failureDraft.name = "失败角色"
    failureDraft.publishedModelID = "model-a"
    _ = try! failureService.createRole(from: failureDraft)
    let state = MemoryWeChatStateStore()
    state.saveError = TestWeChatError.forced
    let message = WeChatMessage(
        fromUserID: "user",
        contextToken: "context",
        messageID: "state-fails",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "不应执行"))]
    )
    let transport = MockWeChatTransport()
    transport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "not-saved")),
        .failure(CancellationError())
    ]
    let archiver = MockWeChatArchiver()
    let weChat = WeChatAssociationService(
        transport: transport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: state,
        archiver: archiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: failureService
    )
    weChat.startBoundListener()
    _ = await waitForTogentCondition {
        transport.updateCursors.count >= 2
    }
    weChat.stop()
    failureService.stop()
    expect(archiver.messages.count == 1, "微信状态失败前归档已完成")
    expect(failureRuntime.executions.isEmpty, "微信状态保存失败不调用 Agent")
    expect((try! failureStore.jobs()).isEmpty, "微信状态保存失败回滚 staged job")
}

@MainActor
func testTogentArchiveReplyModelAndCrashFaults() async {
    let models = [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    let message = WeChatMessage(
        fromUserID: "user",
        contextToken: "context",
        messageID: "fault-message",
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "故障任务"))]
    )

    let archiveRoot = makeTogentTemporaryDirectory("archive-fault")
    defer { try? FileManager.default.removeItem(at: archiveRoot) }
    let archiveStore = TogentStore(databaseURL: archiveRoot.appendingPathComponent("togent.sqlite"))
    let archiveRuntime = StubTogentRuntime()
    let archiveTogent = TogentService(
        store: archiveStore,
        workspace: TogentWorkspaceService(homeDirectory: archiveRoot),
        runtime: archiveRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var archiveDraft = archiveTogent.newRoleDraft()
    archiveDraft.name = "归档故障"
    archiveDraft.publishedModelID = "model-a"
    _ = try! archiveTogent.createRole(from: archiveDraft)
    let archiveTransport = MockWeChatTransport()
    archiveTransport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "must-not-advance")),
        .failure(CancellationError())
    ]
    let archiveState = MemoryWeChatStateStore()
    let failingArchiver = MockWeChatArchiver()
    failingArchiver.error = WeChatArchiveError.appendLog
    let archiveWeChat = WeChatAssociationService(
        transport: archiveTransport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: archiveState,
        archiver: failingArchiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: archiveTogent
    )
    archiveWeChat.startBoundListener()
    _ = await waitForTogentCondition { archiveTransport.updateCursors.count >= 2 }
    archiveWeChat.stop()
    archiveTogent.stop()
    expect(archiveRuntime.executions.isEmpty, "归档失败绝不调用 Agent")
    expect((try! archiveStore.jobs()).isEmpty, "归档失败不创建持久任务")
    expect(archiveState.state.recentKeys.isEmpty, "归档失败不推进微信去重状态")

    let replyRoot = makeTogentTemporaryDirectory("reply-fault")
    defer { try? FileManager.default.removeItem(at: replyRoot) }
    let replyStore = TogentStore(databaseURL: replyRoot.appendingPathComponent("togent.sqlite"))
    let replyRuntime = StubTogentRuntime()
    let replyTogent = TogentService(
        store: replyStore,
        workspace: TogentWorkspaceService(homeDirectory: replyRoot),
        runtime: replyRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var replyDraft = replyTogent.newRoleDraft()
    replyDraft.name = "回复故障"
    replyDraft.publishedModelID = "model-a"
    _ = try! replyTogent.createRole(from: replyDraft)
    var replyAttempts = 0
    replyTogent.replyHandler = { _, _ in
        replyAttempts += 1
        throw TestWeChatError.forced
    }
    let replyLease = try! replyTogent.beginInbound()!
    try! replyTogent.stageInbound(
        message: message,
        deduplicationKey: "reply-fault",
        receivedAt: Date(),
        lease: replyLease
    )
    replyTogent.endInbound(replyLease)
    try! replyTogent.commitStagedInbound(deduplicationKey: "reply-fault")
    let replyFailed = await waitForTogentCondition {
        (try? replyStore.jobs())?.first?.state == .failed
    }
    replyTogent.stop()
    let replyJob = (try! replyStore.jobs()).first!
    expect(replyFailed, "微信最终回复失败会收口任务")
    expect(replyRuntime.executions.count == 1, "回复失败不重复执行 Agent")
    expect(replyAttempts == 2, "最终回复失败后仅再尝试一次明确错误回复")
    expect(replyJob.messageText.isEmpty && replyJob.contextToken.isEmpty,
           "回复失败收口后清除任务载荷")

    let modelRoot = makeTogentTemporaryDirectory("model-fault")
    defer { try? FileManager.default.removeItem(at: modelRoot) }
    let modelStore = TogentStore(databaseURL: modelRoot.appendingPathComponent("togent.sqlite"))
    let modelRuntime = StubTogentRuntime()
    var currentModels = models
    let modelTogent = TogentService(
        store: modelStore,
        workspace: TogentWorkspaceService(homeDirectory: modelRoot),
        runtime: modelRuntime,
        availableModelOptions: { currentModels },
        bootstrapDefaultRole: false
    )
    var modelDraft = modelTogent.newRoleDraft()
    modelDraft.name = "模型故障"
    modelDraft.publishedModelID = "model-a"
    _ = try! modelTogent.createRole(from: modelDraft)
    var modelReplies: [String] = []
    modelTogent.replyHandler = { _, text in modelReplies.append(text) }
    let modelLease = try! modelTogent.beginInbound()!
    try! modelTogent.stageInbound(
        message: message,
        deduplicationKey: "model-fault",
        receivedAt: Date(),
        lease: modelLease
    )
    modelTogent.endInbound(modelLease)
    currentModels = []
    try! modelTogent.commitStagedInbound(deduplicationKey: "model-fault")
    let modelFailed = await waitForTogentCondition {
        (try? modelStore.jobs())?.first?.state == .failed
    }
    modelTogent.stop()
    expect(modelFailed, "已排队角色模型消失会收口失败")
    expect(modelRuntime.executions.isEmpty, "模型消失不启动 Pi")
    expect(modelReplies.first?.contains("模型当前不可用") == true,
           "模型消失向原微信会话明确回复")

    let crashRoot = makeTogentTemporaryDirectory("crash-fault")
    defer { try? FileManager.default.removeItem(at: crashRoot) }
    let crashStore = TogentStore(databaseURL: crashRoot.appendingPathComponent("togent.sqlite"))
    let crashRuntime = StubTogentRuntime()
    crashRuntime.result = .failure(TogentError.runtimeExited("forced crash"))
    let crashTogent = TogentService(
        store: crashStore,
        workspace: TogentWorkspaceService(homeDirectory: crashRoot),
        runtime: crashRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var crashDraft = crashTogent.newRoleDraft()
    crashDraft.name = "崩溃故障"
    crashDraft.publishedModelID = "model-a"
    _ = try! crashTogent.createRole(from: crashDraft)
    var crashReplies: [String] = []
    crashTogent.replyHandler = { _, text in crashReplies.append(text) }
    let crashLease = try! crashTogent.beginInbound()!
    try! crashTogent.stageInbound(
        message: message,
        deduplicationKey: "crash-fault",
        receivedAt: Date(),
        lease: crashLease
    )
    crashTogent.endInbound(crashLease)
    try! crashTogent.commitStagedInbound(deduplicationKey: "crash-fault")
    let crashFailed = await waitForTogentCondition {
        (try? crashStore.jobs())?.first?.state == .failed
    }
    crashTogent.stop()
    expect(crashFailed, "Pi 崩溃会收口任务")
    expect(crashRuntime.executions.count == 1, "Pi 崩溃不无限重试当前微信任务")
    expect(crashReplies.count == 1 && crashReplies[0].contains("forced crash"),
           "Pi 崩溃向原微信会话发送有界错误")

    let shutdownRoot = makeTogentTemporaryDirectory("shutdown-recovery")
    defer { try? FileManager.default.removeItem(at: shutdownRoot) }
    let shutdownStore = TogentStore(
        databaseURL: shutdownRoot.appendingPathComponent("togent.sqlite")
    )
    let shutdownRuntime = StubTogentRuntime()
    shutdownRuntime.delayNanoseconds = 5_000_000_000
    let shutdownTogent = TogentService(
        store: shutdownStore,
        workspace: TogentWorkspaceService(homeDirectory: shutdownRoot),
        runtime: shutdownRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var shutdownDraft = shutdownTogent.newRoleDraft()
    shutdownDraft.name = "退出恢复"
    shutdownDraft.publishedModelID = "model-a"
    _ = try! shutdownTogent.createRole(from: shutdownDraft)
    shutdownTogent.replyHandler = { _, _ in }
    let shutdownLease = try! shutdownTogent.beginInbound()!
    try! shutdownTogent.stageInbound(
        message: message,
        deduplicationKey: "shutdown-recovery",
        receivedAt: Date(),
        lease: shutdownLease
    )
    shutdownTogent.endInbound(shutdownLease)
    try! shutdownTogent.commitStagedInbound(deduplicationKey: "shutdown-recovery")
    let becameRunning = await waitForTogentCondition {
        (try? shutdownStore.jobs())?.first?.state == .running
    }
    await shutdownTogent.stopAndWait()
    expect(becameRunning, "退出恢复测试先进入 running")
    expect((try! shutdownStore.jobs()).first?.state == .running,
           "受管退出保留中断任务供下次恢复")
    let recoveredTogent = TogentService(
        store: shutdownStore,
        workspace: TogentWorkspaceService(homeDirectory: shutdownRoot),
        runtime: StubTogentRuntime(),
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    expect((try! shutdownStore.jobs()).first?.state == .queued,
           "下次启动把退出中断任务恢复为 queued")
    recoveredTogent.stop()
}

@MainActor
func testTogentWeChatRealPiEndToEnd() async {
    let runtimeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/togent-runtime", isDirectory: true)
    guard FileManager.default.isExecutableFile(
        atPath: runtimeDirectory.appendingPathComponent("pi").path
    ) else {
        print("SKIP: 假微信 + 真 Pi E2E（先运行 scripts/build_togent_runtime.sh）")
        return
    }

    let root = makeTogentTemporaryDirectory("wechat-real-pi")
    defer { try? FileManager.default.removeItem(at: root) }
    let upstreamKey = ModelRelayUpstreamKeyReference(name: "wechat-e2e-upstream")
    let provider = ModelRelayProvider(
        name: "微信 E2E 厂家",
        baseURL: "https://wechat-e2e.example/v1",
        keys: [upstreamKey],
        models: [
            ModelRelayModelRoute(
                upstreamModelID: "wechat-upstream-model",
                alias: "wechat-e2e-model",
                capability: ModelRelayModelCapability(
                    imageInput: .multimodal,
                    evidence: .imageProbe,
                    checkedAt: Date(),
                    probeVersion: ModelRelayModelCapability.currentProbeVersion
                )
            ),
            ModelRelayModelRoute(
                upstreamModelID: "wechat-text-upstream",
                alias: "wechat-text-model",
                capability: .unknown
            )
        ]
    )
    let relayToken = "tg_wechat_e2e_only"
    let router = ModelRelayRouter(
        configuration: ModelRelayConfiguration(providers: [provider]),
        keyStore: MemoryModelRelayKeyStore([upstreamKey.id: "upstream-secret"]),
        vault: ModelRelayLocalKeyVault(iterations: 1),
        internalCredentialDigest: ModelRelayLocalKeyVault.digest(relayToken)
    )
    let expectedAttachmentPath = "wechat/261005/101112_123_01_image.jpg"
    let observationLock = NSLock()
    var initialPromptUsedExactPath = false
    var sawImageURL = false
    var textModelOmittedImage = false
    func observationSnapshot() -> (promptPathOK: Bool, imageForwarded: Bool, textOmitted: Bool) {
        observationLock.lock()
        defer { observationLock.unlock() }
        return (initialPromptUsedExactPath, sawImageURL, textModelOmittedImage)
    }
    ModelRelayURLProtocol.reset { request in
        let bodyData = modelRelayURLRequestBody(request)
        let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
        let body = try! JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let upstreamModel = body["model"] as? String
        let containsImage = bodyText.contains(#""image_url""#)
            && bodyText.contains("data:image")
        let containsToolResult = bodyText.contains(#""role":"tool""#)
        observationLock.lock()
        if containsImage {
            sawImageURL = true
        } else if upstreamModel == "wechat-text-upstream" && containsToolResult {
            textModelOmittedImage = true
        } else if !(upstreamModel == "wechat-upstream-model" && containsToolResult) {
            initialPromptUsedExactPath = initialPromptUsedExactPath
                || (bodyText
                    .replacingOccurrences(of: "\\/", with: "/")
                    .contains(expectedAttachmentPath)
                    && !bodyText.contains("data:image"))
        }
        observationLock.unlock()

        let chunks: [[String: Any]]
        if containsImage
            || (upstreamModel == "wechat-text-upstream" && containsToolResult) {
            let answer = containsImage
                ? "微信图片识别链路完成"
                : "纯文本模型安全降级完成"
            chunks = [
                [
                    "id": "chatcmpl-wechat-image-final",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "wechat-upstream-model",
                    "choices": [[
                        "index": 0,
                        "delta": [
                            "role": "assistant",
                            "content": answer
                        ],
                        "finish_reason": NSNull()
                    ]]
                ],
                [
                    "id": "chatcmpl-wechat-image-final",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "wechat-upstream-model",
                    "choices": [[
                        "index": 0,
                        "delta": [:],
                        "finish_reason": "stop"
                    ]]
                ]
            ]
        } else {
            chunks = [
                [
                    "id": "chatcmpl-wechat-image-read",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "wechat-upstream-model",
                    "choices": [[
                        "index": 0,
                        "delta": [
                            "role": "assistant",
                            "tool_calls": [[
                                "index": 0,
                                "id": "call_read_wechat_image",
                                "type": "function",
                                "function": [
                                    "name": "read",
                                    "arguments": #"{"path":"\#(expectedAttachmentPath)"}"#
                                ]
                            ]]
                        ],
                        "finish_reason": NSNull()
                    ]]
                ],
                [
                    "id": "chatcmpl-wechat-image-read",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "wechat-upstream-model",
                    "choices": [[
                        "index": 0,
                        "delta": [:],
                        "finish_reason": "tool_calls"
                    ]]
                ]
            ]
        }
        let payload = chunks.map {
            "data: " + String(
                data: try! JSONSerialization.data(withJSONObject: $0),
                encoding: .utf8
            )! + "\n\n"
        }.joined() + "data: [DONE]\n\n"
        return ModelRelayStubResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data(payload.utf8)]
        )
    }
    let relayServer = ModelRelayHTTPServer(
        router: router,
        upstream: ModelRelayUpstreamClient(
            sessionConfiguration: modelRelayTestSessionConfiguration()
        )
    )
    let relayPort: UInt16
    do {
        relayPort = try await startModelRelayTestServerOnAvailablePort(relayServer)
    } catch {
        expect(false, "假微信 + 真 Pi E2E 应能启动受控 Relay：\(error)")
        return
    }
    defer { relayServer.stop() }

    let model = TogentModelOption(
        publishedModelID: "wechat-e2e-model",
        providerName: "微信 E2E 厂家",
        imageInput: .multimodal
    )
    let textModel = TogentModelOption(
        publishedModelID: "wechat-text-model",
        providerName: "微信 E2E 厂家",
        imageInput: .unknown
    )
    let access = TogentRelayAccess(
        baseURL: "http://127.0.0.1:\(relayPort)/v1",
        bearerToken: relayToken,
        models: [model, textModel]
    )
    let runtime = TogentRuntimeService(
        relayAccess: { access },
        runtimeDirectory: runtimeDirectory,
        sandbox: TogentSandbox(
            applicationSupportRoot: root.appendingPathComponent("runtime", isDirectory: true)
        )
    )
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: { [model] },
        bootstrapDefaultRole: false
    )
    var roleDraft = togent.newRoleDraft()
    roleDraft.name = "微信真 Pi 角色"
    roleDraft.prompt = "只完成当前微信测试任务。"
    roleDraft.publishedModelID = model.publishedModelID
    let role: TogentRole
    do {
        role = try togent.createRole(from: roleDraft)
    } catch {
        expect(false, "假微信 + 真 Pi E2E 应能创建角色：\(error)")
        return
    }
    expect(
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: role.workspacePath)
                .appendingPathComponent("AGENTS.md")
                .path
        ),
        "完整 E2E 创建默认角色 AGENTS.md"
    )
    expect(
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: role.workspacePath)
                .appendingPathComponent("project", isDirectory: true)
                .path
        ),
        "完整 E2E 创建默认角色 project 目录"
    )

    let archiveCalendar = makeArchiveCalendar()
    let receivedAt = archiveCalendar.date(from: DateComponents(
        year: 2026,
        month: 10,
        day: 5,
        hour: 10,
        minute: 11,
        second: 12,
        nanosecond: 123_000_000
    ))!
    let imageMedia = WeChatMedia(
        encryptQueryParameter: "wechat-e2e-image",
        aesKey: Data(repeating: 1, count: 16).base64EncodedString()
    )
    let message = WeChatMessage(
        fromUserID: "wechat-e2e-user",
        contextToken: "wechat-e2e-context",
        messageID: "wechat-e2e-message",
        items: [
            WeChatItem(
                type: 1,
                textItem: WeChatTextItem(text: "请识别这张图片")
            ),
            WeChatItem(
                type: 2,
                imageItem: WeChatImageItem(media: imageMedia)
            )
        ]
    )
    let transport = MockWeChatTransport()
    let imageData = NSMutableData()
    let imageContext = CGContext(
        data: nil,
        width: 64,
        height: 64,
        bitsPerComponent: 8,
        bytesPerRow: 64 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    imageContext.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
    imageContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    imageContext.setFillColor(CGColor(gray: 1, alpha: 1))
    imageContext.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
    let imageDestination = CGImageDestinationCreateWithData(
        imageData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(
        imageDestination,
        imageContext.makeImage()!,
        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    )
    expect(CGImageDestinationFinalize(imageDestination), "图片 E2E 生成有效 JPEG")
    transport.mediaResult = .success(imageData as Data)
    transport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "wechat-e2e-cursor")),
        .failure(CancellationError())
    ]
    let archiver = WeChatArchiveService(
        transport: transport,
        calendarProvider: makeArchiveCalendar
    )
    let weChat = WeChatAssociationService(
        transport: transport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: MemoryWeChatStateStore(),
        archiver: archiver,
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        now: { receivedAt },
        togent: togent
    )
    weChat.startBoundListener()
    let completed = await waitForTogentCondition(timeout: 20) {
        transport.sentTexts.count == 1
    }
    weChat.stop()
    await togent.stopAndWait()

    expect(completed, "假 iLink 图片经真实归档、真 Pi 与 Relay 收到最终回复")
    let archivedImage = URL(
        fileURLWithPath: role.workspacePath,
        isDirectory: true
    ).appendingPathComponent(expectedAttachmentPath)
    expect(
        FileManager.default.fileExists(atPath: archivedImage.path),
        "完整图片 E2E 在 Agent 执行前真实落盘到当前角色归档"
    )
    expect(
        transport.sentTexts.first?.text == "微信图片识别链路完成",
        "完整图片 E2E 只回复真 Pi 的 agent settled 最终文本"
    )
    expect(
        (try? store.jobs().first?.state) == .completed,
        "完整 E2E 持久任务收口 completed"
    )
    let rewrittenModel = ModelRelayURLProtocol.requests.contains { request in
        guard let body = try? JSONSerialization.jsonObject(
            with: modelRelayURLRequestBody(request)
        ) as? [String: Any] else {
            return false
        }
        return body["model"] as? String == "wechat-upstream-model"
    }
    expect(rewrittenModel, "完整 E2E 的真 Pi 请求经 Relay 改写上游模型")
    let imageObservation = observationSnapshot()
    expect(
        imageObservation.promptPathOK,
        "真 Pi 初始任务只收到精确相对附件路径，不含图片正文/base64"
    )
    expect(imageObservation.imageForwarded, "真 Pi 调用 read 后 Relay 透明转发 image_url")

    let textRole = TogentRole(
        id: role.id,
        name: role.name,
        workspacePath: role.workspacePath,
        prompt: role.prompt,
        publishedModelID: textModel.publishedModelID,
        isActive: true,
        createdAt: role.createdAt,
        updatedAt: Date()
    )
    do {
        let answer = try await runtime.execute(
            role: textRole,
            prompt: "请调用 read 工具读取 \(expectedAttachmentPath)，然后回复结果。"
        )
        expect(answer.contains("纯文本模型安全降级完成"), "能力未知模型仍可按纯文本执行任务")
    } catch {
        expect(false, "能力未知模型安全降级 E2E 不应失败：\(error)")
    }
    expect(
        observationSnapshot().textOmitted,
        "能力未知模型读取图片时不会向上游发送 image_url"
    )
    await runtime.stopAll()
}
