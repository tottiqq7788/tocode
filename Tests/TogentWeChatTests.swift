import Foundation

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
        availableModelOptions: { models }
    )
    var roleDraft = togent.newRoleDraft()
    roleDraft.name = "微信角色"
    roleDraft.publishedModelID = "model-a"
    _ = try! togent.createRole(from: roleDraft)

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
        availableModelOptions: { models }
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
        togent: togent
    )
    weChat.startBoundListener()
    _ = await waitForTogentCondition { transport.sentTexts.count == 1 }
    weChat.stop()
    togent.stop()

    expect(archiver.messages.count == 1, "重复微信消息只归档一次")
    expect(runtime.executions.isEmpty, "无激活角色时不启动 Pi")
    expect(transport.sentTexts.count == 1, "重复微信消息只回复一次错误")
    expect(transport.sentTexts.first?.text.contains("尚未激活") == true,
           "无激活角色向原会话明确回复")
    expect((try! store.jobs()).count == 1, "消息 dedupe key 在 Togent job 表唯一")
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
        availableModelOptions: { models }
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
        availableModelOptions: { models }
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
        availableModelOptions: { models }
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
        availableModelOptions: { models }
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
    try! replyTogent.stageInbound(
        message: message,
        deduplicationKey: "reply-fault",
        receivedAt: Date()
    )
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
        availableModelOptions: { currentModels }
    )
    var modelDraft = modelTogent.newRoleDraft()
    modelDraft.name = "模型故障"
    modelDraft.publishedModelID = "model-a"
    _ = try! modelTogent.createRole(from: modelDraft)
    var modelReplies: [String] = []
    modelTogent.replyHandler = { _, text in modelReplies.append(text) }
    try! modelTogent.stageInbound(
        message: message,
        deduplicationKey: "model-fault",
        receivedAt: Date()
    )
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
        availableModelOptions: { models }
    )
    var crashDraft = crashTogent.newRoleDraft()
    crashDraft.name = "崩溃故障"
    crashDraft.publishedModelID = "model-a"
    _ = try! crashTogent.createRole(from: crashDraft)
    var crashReplies: [String] = []
    crashTogent.replyHandler = { _, text in crashReplies.append(text) }
    try! crashTogent.stageInbound(
        message: message,
        deduplicationKey: "crash-fault",
        receivedAt: Date()
    )
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
        availableModelOptions: { models }
    )
    var shutdownDraft = shutdownTogent.newRoleDraft()
    shutdownDraft.name = "退出恢复"
    shutdownDraft.publishedModelID = "model-a"
    _ = try! shutdownTogent.createRole(from: shutdownDraft)
    shutdownTogent.replyHandler = { _, _ in }
    try! shutdownTogent.stageInbound(
        message: message,
        deduplicationKey: "shutdown-recovery",
        receivedAt: Date()
    )
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
        availableModelOptions: { models }
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
                alias: "wechat-e2e-model"
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
    ModelRelayURLProtocol.reset { _ in
        let first = """
        data: {"id":"chatcmpl-wechat-e2e","object":"chat.completion.chunk","created":1,"model":"wechat-upstream-model","choices":[{"index":0,"delta":{"role":"assistant","content":"微信真 Pi 链路完成"},"finish_reason":null}]}

        """
        let final = """
        data: {"id":"chatcmpl-wechat-e2e","object":"chat.completion.chunk","created":1,"model":"wechat-upstream-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

        data: [DONE]

        """
        return ModelRelayStubResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data((first + "\n").utf8), Data(final.utf8)]
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
        providerName: "微信 E2E 厂家"
    )
    let access = TogentRelayAccess(
        baseURL: "http://127.0.0.1:\(relayPort)/v1",
        bearerToken: relayToken,
        models: [model]
    )
    let runtime = TogentRuntimeService(
        relayAccess: { access },
        runtimeDirectory: runtimeDirectory,
        sandbox: TogentSandbox(
            applicationSupportRoot: root.appendingPathComponent("runtime", isDirectory: true),
            weChatArchiveRoot: root.appendingPathComponent("wechat", isDirectory: true)
        )
    )
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: { [model] }
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

    let message = WeChatMessage(
        fromUserID: "wechat-e2e-user",
        contextToken: "wechat-e2e-context",
        messageID: "wechat-e2e-message",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "请完成完整链路测试")
        )]
    )
    let transport = MockWeChatTransport()
    transport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "wechat-e2e-cursor")),
        .failure(CancellationError())
    ]
    let archiver = MockWeChatArchiver()
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
        togent: togent
    )
    weChat.startBoundListener()
    let completed = await waitForTogentCondition(timeout: 20) {
        transport.sentTexts.count == 1
    }
    weChat.stop()
    await togent.stopAndWait()

    expect(completed, "假 iLink 普通消息经真 Pi 与 Relay 收到最终回复")
    expect(archiver.messages == [message], "完整 E2E 在 Agent 执行前归档普通消息")
    expect(
        transport.sentTexts.first?.text == "微信真 Pi 链路完成",
        "完整 E2E 只回复真 Pi 的 agent settled 最终文本"
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
}
