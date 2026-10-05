import Foundation
import CoreGraphics
import ImageIO
import SQLite3
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
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.05,
        imageCaptionTimeout: 0.2
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
            && archiver.messages.count == 2
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
        transport.sentTexts.count == 1
    }
    weChat.stop()
    togent.stop()

    expect(completed, "两条连续普通微信消息收到一次 Agent 最终回复")
    expect(archiver.messages == [first, second], "普通微信消息按顺序先归档")
    let roleArchive = URL(fileURLWithPath: role.workspacePath, isDirectory: true)
        .appendingPathComponent("wechat", isDirectory: true)
    expect(archiver.roots == [roleArchive, roleArchive], "同一角色消息只进入自己的归档根")
    expect(archiveWasCompleteAtExecution, "合并执行发生在全部成员消息归档之后")
    expect(runtime.executions.count == 1, "静默窗口内连续消息只调用一次 Agent")
    let mergedPrompt = runtime.executions[0].1
    expect(
        mergedPrompt.contains("第一条任务")
            && mergedPrompt.contains("第二条任务")
            && mergedPrompt.range(of: "第一条任务")!.lowerBound
                < mergedPrompt.range(of: "第二条任务")!.lowerBound,
        "连续消息按接收顺序合并进入同一 Pi prompt"
    )
    expect(transport.sentTexts.map(\.text) == ["Agent 完成"],
           "合并批次只发送一次 agent settled 最终文本")
    let completedJobs = try! store.jobs()
    expect(completedJobs.allSatisfy { $0.state == .completed },
           "成功回复后持久任务全部收口 completed")
    expect(completedJobs.allSatisfy {
        $0.fromUserID.isEmpty && $0.contextToken.isEmpty && $0.messageText.isEmpty
    }, "回复结果持久化后清除已完成任务载荷")
    expect(state.state.cursor == "cursor-2", "staged 后持久化微信 cursor")

    let imageRoot = makeTogentTemporaryDirectory("wechat-image-batch")
    defer { try? FileManager.default.removeItem(at: imageRoot) }
    let imageStore = TogentStore(
        databaseURL: imageRoot.appendingPathComponent("togent.sqlite")
    )
    let imageRuntime = StubTogentRuntime()
    imageRuntime.result = .success("批次完成")
    let imageTogent = TogentService(
        store: imageStore,
        workspace: TogentWorkspaceService(homeDirectory: imageRoot),
        runtime: imageRuntime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.03,
        imageCaptionTimeout: 0.5
    )
    var imageReplies: [String] = []
    imageTogent.replyHandler = { _, _, reply in imageReplies.append(reply.text) }
    var imageRoleDraft = imageTogent.newRoleDraft()
    imageRoleDraft.name = "图片等待角色"
    imageRoleDraft.publishedModelID = "model-a"
    let imageRole = try! imageTogent.createRole(from: imageRoleDraft)

    func stage(
        _ message: WeChatMessage,
        key: String,
        waitsForText: Bool
    ) throws {
        let lease = try imageTogent.beginInbound()!
        let batchKey = WeChatDeduplication.batchKey(
            for: message,
            roleID: imageRole.id
        )
        imageTogent.beginBatchIntake(batchKey: batchKey)
        try imageTogent.stageInbound(
            message: message,
            deduplicationKey: key,
            receivedAt: Date(),
            lease: lease,
            batchKey: batchKey,
            waitsForText: waitsForText
        )
        imageTogent.endInbound(lease)
        try imageTogent.commitStagedInbound(
            deduplicationKey: key,
            deferForBatching: true
        )
    }

    let waitingImage = WeChatMessage(
        fromUserID: "image-user",
        contextToken: "image-context-1",
        messageID: "image-only-1",
        items: [WeChatItem(type: 2, imageItem: WeChatImageItem(url: "image-1"))]
    )
    let directBatchKey = WeChatDeduplication.batchKey(
        for: waitingImage,
        roleID: imageRole.id
    )
    let groupBatchKey = WeChatDeduplication.batchKey(
        for: WeChatMessage(
            fromUserID: "image-user",
            contextToken: "group-context",
            groupID: "group-a",
            messageID: "group-message",
            items: waitingImage.items
        ),
        roleID: imageRole.id
    )
    expect(
        directBatchKey != groupBatchKey
            && directBatchKey
                != WeChatDeduplication.batchKey(
                    for: waitingImage,
                    roleID: UUID()
                )
            && !directBatchKey.contains("image-user"),
        "批次键隔离会话和角色，且不持久化明文发送者"
    )
    try! stage(waitingImage, key: "image-only-1", waitsForText: true)
    try? await Task.sleep(nanoseconds: 100_000_000)
    expect(imageRuntime.executions.isEmpty, "纯图片超过普通静默窗口仍不调用 Agent")

    let secondWaitingImage = WeChatMessage(
        fromUserID: "image-user",
        contextToken: "image-context-2",
        messageID: "image-only-2",
        items: [WeChatItem(type: 2, imageItem: WeChatImageItem(url: "image-2"))]
    )
    try! stage(secondWaitingImage, key: "image-only-2", waitsForText: true)
    try? await Task.sleep(nanoseconds: 60_000_000)
    expect(imageRuntime.executions.isEmpty, "连续多张纯图片仍等待同批次后续文字")

    let otherUserText = WeChatMessage(
        fromUserID: "other-user",
        contextToken: "other-context",
        messageID: "other-text",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "另一个用户的任务")
        )]
    )
    try! stage(otherUserText, key: "other-text", waitsForText: false)
    let otherCompleted = await waitForTogentCondition {
        imageRuntime.executions.count == 1
    }
    expect(otherCompleted, "不同发送者的文字批次独立执行")
    expect(
        imageRuntime.executions[0].1.contains("另一个用户的任务")
            && !imageRuntime.executions[0].1.contains("图片消息"),
        "不同发送者不会与等待中的图片合并"
    )

    let imageCaption = WeChatMessage(
        fromUserID: "image-user",
        contextToken: "image-context-3",
        messageID: "image-caption",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "请分析刚才的图片")
        )]
    )
    try! stage(imageCaption, key: "image-caption", waitsForText: false)
    let imageCompleted = await waitForTogentCondition {
        imageRuntime.executions.count == 2
    }
    expect(imageCompleted, "图片收到同一用户后续文字后执行")
    expect(
        imageRuntime.executions[1].1
            .components(separatedBy: "（图片消息，详情见微信归档）").count == 3
            && imageRuntime.executions[1].1.contains("请分析刚才的图片"),
        "多张图片与后续文字有序合并为一次 Agent prompt"
    )

    let expiringImage = WeChatMessage(
        fromUserID: "expired-user",
        contextToken: "expired-context",
        messageID: "expired-image",
        items: [WeChatItem(type: 2, imageItem: WeChatImageItem(url: "image-expired"))]
    )
    try! stage(expiringImage, key: "expired-image", waitsForText: true)
    try? await Task.sleep(nanoseconds: 650_000_000)
    expect(imageRuntime.executions.count == 2, "纯图片等待超时不调用 Agent")
    expect(imageReplies.count == 2, "纯图片等待超时不发送微信回复")
    let imageJobs = try! imageStore.jobs()
    expect(
        imageJobs.allSatisfy {
            $0.state == .completed
                && $0.fromUserID.isEmpty
                && $0.contextToken.isEmpty
                && $0.messageText.isEmpty
        },
        "合并成员与过期图片均保留 dedupe 记录并清除敏感载荷"
    )
    imageTogent.stop()
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
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.03,
        imageCaptionTimeout: 0.15
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
    let migrationRoot = makeTogentTemporaryDirectory("batch-migration")
    defer { try? FileManager.default.removeItem(at: migrationRoot) }
    let migrationURL = migrationRoot.appendingPathComponent("togent.sqlite")
    var legacyDatabase: OpaquePointer?
    let openedLegacy = sqlite3_open(migrationURL.path, &legacyDatabase) == SQLITE_OK
    expect(openedLegacy, "可创建旧版 Togent 数据库迁移夹具")
    if let legacyDatabase {
        let legacyID = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970
        let script = """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            dedupe_key TEXT NOT NULL UNIQUE,
            role_id TEXT,
            from_user_id TEXT NOT NULL,
            context_token TEXT NOT NULL,
            message_text TEXT NOT NULL,
            received_at REAL NOT NULL,
            state TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        INSERT INTO jobs
        (id, dedupe_key, role_id, from_user_id, context_token, message_text,
         received_at, state, attempt_count, last_error, created_at, updated_at)
        VALUES
        ('\(legacyID)', 'legacy-staged', NULL, 'legacy-user', 'legacy-context',
         '旧版待恢复消息', \(timestamp), 'staged', 0, NULL, \(timestamp), \(timestamp));
        """
        expect(
            sqlite3_exec(legacyDatabase, script, nil, nil, nil) == SQLITE_OK,
            "旧版 jobs 表夹具写入成功"
        )
        sqlite3_close(legacyDatabase)
    }
    let migratedStore = TogentStore(databaseURL: migrationURL)
    let migrationPending = try? migratedStore.reconcileStagedJobs(
        committedKeys: ["legacy-staged"]
    )
    expect(
        migrationPending?.isEmpty == true
            && (try? migratedStore.nextQueuedJob())?.deduplicationKey == "legacy-staged",
        "旧数据库自动补齐批次列且旧 staged job 独立恢复"
    )

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
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.03,
        imageCaptionTimeout: 0.15
    )
    var draft = togent.newRoleDraft()
    draft.name = "恢复角色"
    draft.publishedModelID = "model-a"
    let role = try! togent.createRole(from: draft)

    _ = try! store.stageJob(
        deduplicationKey: "committed",
        roleID: role.id,
        fromUserID: "user",
        contextToken: "context-1",
        messageText: "恢复第一条",
        receivedAt: Date(),
        batchKey: "recovery-batch"
    )
    _ = try! store.stageJob(
        deduplicationKey: "committed-2",
        roleID: role.id,
        fromUserID: "user",
        contextToken: "context-2",
        messageText: "恢复第二条",
        receivedAt: Date(),
        batchKey: "recovery-batch"
    )
    _ = try! store.stageJob(
        deduplicationKey: "uncommitted",
        roleID: role.id,
        fromUserID: "user",
        contextToken: "context",
        messageText: "不要执行",
        receivedAt: Date(),
        batchKey: "recovery-batch"
    )
    _ = try! store.stageJob(
        deduplicationKey: "committed-image",
        roleID: role.id,
        fromUserID: "image-user",
        contextToken: "image-context",
        messageText: "（图片消息，详情见微信归档）",
        receivedAt: Date(),
        batchKey: "recovery-image-batch",
        waitsForText: true
    )
    var replies: [String] = []
    togent.replyHandler = { _, _, reply in replies.append(reply.text) }
    togent.recover(
        committedDeduplicationKeys: [
            "committed",
            "committed-2",
            "committed-image"
        ]
    )
    _ = await waitForTogentCondition { replies.count == 1 }
    expect(runtime.executions.count == 1, "重启把已提交的普通 staged 批次恢复为一次调用")
    expect(
        runtime.executions.first?.1.contains("恢复第一条") == true
            && runtime.executions.first?.1.contains("恢复第二条") == true
            && runtime.executions.first!.1.range(of: "恢复第一条")!.lowerBound
                < runtime.executions.first!.1.range(of: "恢复第二条")!.lowerBound,
        "恢复批次保留已提交成员及接收顺序"
    )
    expect(!(try! store.jobs()).contains { $0.deduplicationKey == "uncommitted" },
           "未提交微信状态的 staged job 在恢复时删除")
    try? await Task.sleep(nanoseconds: 250_000_000)
    expect(runtime.executions.count == 1, "重启恢复的纯图片等待超时仍不调用 Agent")
    let recoveredImage = (try! store.jobs()).first {
        $0.deduplicationKey == "committed-image"
    }
    expect(
        recoveredImage?.state == .completed
            && recoveredImage?.fromUserID.isEmpty == true
            && recoveredImage?.contextToken.isEmpty == true
            && recoveredImage?.messageText.isEmpty == true,
        "重启恢复的纯图片超时后保留去重记录并清除载荷"
    )
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
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.2,
        imageCaptionTimeout: 0.2
    )
    var failureDraft = failureService.newRoleDraft()
    failureDraft.name = "失败角色"
    failureDraft.publishedModelID = "model-a"
    let failureRole = try! failureService.createRole(from: failureDraft)
    let priorMessage = WeChatMessage(
        fromUserID: "user",
        contextToken: "prior-context",
        messageID: "prior-message",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "状态失败前的已提交消息")
        )]
    )
    let priorBatchKey = WeChatDeduplication.batchKey(
        for: priorMessage,
        roleID: failureRole.id
    )
    let priorLease = try! failureService.beginInbound()!
    failureService.beginBatchIntake(batchKey: priorBatchKey)
    try! failureService.stageInbound(
        message: priorMessage,
        deduplicationKey: "prior-message",
        receivedAt: Date(),
        lease: priorLease,
        batchKey: priorBatchKey
    )
    failureService.endInbound(priorLease)
    try! failureService.commitStagedInbound(
        deduplicationKey: "prior-message",
        deferForBatching: true
    )
    let state = MemoryWeChatStateStore(WeChatReceiveState(
        cursor: "",
        recentKeys: ["prior-message"]
    ))
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
            && failureRuntime.executions.count == 1
            && (try? failureStore.jobs())?.allSatisfy {
                $0.state == .completed
            } == true
    }
    weChat.stop()
    failureService.stop()
    expect(archiver.messages.count == 1, "微信状态失败前归档已完成")
    let stateFailurePrompts = failureRuntime.executions.map(\.1)
    let stateFailureJobs = try! failureStore.jobs()
    expect(stateFailurePrompts.count == 1, "微信状态保存失败后旧批次只执行一次")
    expect(
        stateFailurePrompts.first?.contains("状态失败前的已提交消息") == true,
        "微信状态保存失败后恢复旧批次正文"
    )
    expect(
        stateFailurePrompts.allSatisfy { !$0.contains("不应执行") },
        "微信状态保存失败的本次消息绝不污染 Agent prompt"
    )
    expect(stateFailureJobs.count == 1, "微信状态保存失败回滚本次 staged 成员")
    expect(
        stateFailureJobs.first?.deduplicationKey == "prior-message",
        "微信状态保存失败保留旧批次去重记录"
    )
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
        bootstrapDefaultRole: false,
        messageBatchDebounce: 0.2,
        imageCaptionTimeout: 0.2
    )
    var archiveDraft = archiveTogent.newRoleDraft()
    archiveDraft.name = "归档故障"
    archiveDraft.publishedModelID = "model-a"
    let archiveRole = try! archiveTogent.createRole(from: archiveDraft)
    let archivePriorMessage = WeChatMessage(
        fromUserID: "user",
        contextToken: "archive-prior-context",
        messageID: "archive-prior",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "归档失败前的已提交消息")
        )]
    )
    let archiveBatchKey = WeChatDeduplication.batchKey(
        for: archivePriorMessage,
        roleID: archiveRole.id
    )
    let archivePriorLease = try! archiveTogent.beginInbound()!
    archiveTogent.beginBatchIntake(batchKey: archiveBatchKey)
    try! archiveTogent.stageInbound(
        message: archivePriorMessage,
        deduplicationKey: "archive-prior",
        receivedAt: Date(),
        lease: archivePriorLease,
        batchKey: archiveBatchKey
    )
    archiveTogent.endInbound(archivePriorLease)
    try! archiveTogent.commitStagedInbound(
        deduplicationKey: "archive-prior",
        deferForBatching: true
    )
    let archiveTransport = MockWeChatTransport()
    archiveTransport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "must-not-advance")),
        .failure(CancellationError())
    ]
    let archiveState = MemoryWeChatStateStore(WeChatReceiveState(
        cursor: "",
        recentKeys: ["archive-prior"]
    ))
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
    _ = await waitForTogentCondition {
        archiveTransport.updateCursors.count >= 2
            && archiveRuntime.executions.count == 1
            && (try? archiveStore.jobs())?.allSatisfy {
                $0.state == .completed
            } == true
    }
    archiveWeChat.stop()
    archiveTogent.stop()
    let archiveFailurePrompts = archiveRuntime.executions.map(\.1)
    let archiveFailureJobs = try! archiveStore.jobs()
    expect(archiveFailurePrompts.count == 1, "归档失败后旧批次只执行一次")
    expect(
        archiveFailurePrompts.first?.contains("归档失败前的已提交消息") == true,
        "本次归档失败后恢复已提交旧批次正文"
    )
    expect(
        archiveFailurePrompts.allSatisfy { !$0.contains("故障任务") },
        "本次归档失败消息绝不进入 Agent prompt"
    )
    expect(archiveFailureJobs.count == 1, "归档失败不创建本次持久任务")
    expect(
        archiveFailureJobs.first?.deduplicationKey == "archive-prior",
        "归档失败不破坏旧批次去重记录"
    )
    expect(
        archiveState.state.cursor.isEmpty
            && archiveState.state.recentKeys == ["archive-prior"],
        "归档失败保留旧去重状态且不推进本次消息"
    )

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
    replyTogent.replyHandler = { _, _, _ in
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
    modelTogent.replyHandler = { _, _, reply in modelReplies.append(reply.text) }
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
    crashTogent.replyHandler = { _, _, reply in crashReplies.append(reply.text) }
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
    shutdownTogent.replyHandler = { _, _, _ in }
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
        expect(false, "假微信 + 真 Pi E2E 缺少受管 runtime")
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
    let expectedAttachmentPaths = [
        "wechat/261005/101112_123_01_image.jpg",
        "wechat/261005/101112_123_01_image_2.jpg"
    ]
    let expectedAttachmentPath = expectedAttachmentPaths[0]
    let observationLock = NSLock()
    var initialPromptUsedExactPath = false
    var initialPromptUsedBatchOrder = false
    var initialPromptCount = 0
    var sawImageURL = false
    var textModelOmittedImage = false
    var persistedImageRedactedBeforeSecondRequest = false
    func persistedSessionSnapshot() -> String {
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return ""
        }
        return enumerator.compactMap { element -> String? in
            guard let file = element as? URL,
                  file.pathExtension == "jsonl" else {
                return nil
            }
            return try? String(contentsOf: file, encoding: .utf8)
        }.joined(separator: "\n")
    }
    func observationSnapshot() -> (
        promptPathOK: Bool,
        batchOrderOK: Bool,
        initialCount: Int,
        imageForwarded: Bool,
        textOmitted: Bool,
        persistedRedactedBeforeSecondRequest: Bool
    ) {
        observationLock.lock()
        defer { observationLock.unlock() }
        return (
            initialPromptUsedExactPath,
            initialPromptUsedBatchOrder,
            initialPromptCount,
            sawImageURL,
            textModelOmittedImage,
            persistedImageRedactedBeforeSecondRequest
        )
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
            let persisted = persistedSessionSnapshot()
            persistedImageRedactedBeforeSecondRequest =
                persisted.contains("已从持久会话移除归档图片正文")
                && !persisted.contains(#""type":"image""#)
        } else if upstreamModel == "wechat-text-upstream" && containsToolResult {
            textModelOmittedImage = true
        } else if upstreamModel == "wechat-upstream-model" && !containsToolResult {
            initialPromptCount += 1
            let normalizedBody = bodyText.replacingOccurrences(of: "\\/", with: "/")
            initialPromptUsedExactPath = initialPromptUsedExactPath
                || (expectedAttachmentPaths.allSatisfy { normalizedBody.contains($0) }
                    && !bodyText.contains("data:image"))
            if let firstPath = normalizedBody.range(of: expectedAttachmentPaths[0]),
               let secondPath = normalizedBody.range(of: expectedAttachmentPaths[1]),
               let caption = normalizedBody.range(of: "请识别刚才的两张图片") {
                initialPromptUsedBatchOrder = initialPromptUsedBatchOrder
                    || (firstPath.lowerBound < secondPath.lowerBound
                        && secondPath.lowerBound < caption.lowerBound)
            }
        }
        observationLock.unlock()

        let chunks: [[String: Any]]
        if containsImage
            || (upstreamModel == "wechat-text-upstream" && containsToolResult) {
            let answer = containsImage
                ? """
                微信图片识别链路完成
                <tocode_wechat_files>
                {"files":["AGENTS.md"]}
                </tocode_wechat_files>
                """
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
        bootstrapDefaultRole: false,
        now: { Date(timeIntervalSince1970: 0) },
        messageBatchDebounce: 0.05,
        imageCaptionTimeout: 5
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
    let firstImageMessage = WeChatMessage(
        fromUserID: "wechat-e2e-user",
        contextToken: "wechat-e2e-image-context-1",
        messageID: "wechat-e2e-image-1",
        items: [WeChatItem(
            type: 2,
            imageItem: WeChatImageItem(media: imageMedia)
        )]
    )
    let secondImageMessage = WeChatMessage(
        fromUserID: "wechat-e2e-user",
        contextToken: "wechat-e2e-image-context-2",
        messageID: "wechat-e2e-image-2",
        items: [WeChatItem(
            type: 2,
            imageItem: WeChatImageItem(media: imageMedia)
        )]
    )
    let captionMessage = WeChatMessage(
        fromUserID: "wechat-e2e-user",
        contextToken: "wechat-e2e-caption-context",
        messageID: "wechat-e2e-caption",
        items: [WeChatItem(
            type: 1,
            textItem: WeChatTextItem(text: "请识别刚才的两张图片")
        )]
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
        .success(WeChatUpdates(
            messages: [firstImageMessage, secondImageMessage, captionMessage],
            cursor: "wechat-e2e-cursor"
        )),
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
    let archivedImages = expectedAttachmentPaths.map { relativePath in
        URL(
            fileURLWithPath: role.workspacePath,
            isDirectory: true
        ).appendingPathComponent(relativePath)
    }
    expect(
        archivedImages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
        "完整图片 E2E 在 Agent 执行前把两张图片分别落盘到当前角色归档"
    )
    let archiveMarkdown = try? String(
        contentsOf: URL(
            fileURLWithPath: role.workspacePath,
            isDirectory: true
        ).appendingPathComponent("wechat/261005/wechat261005.md"),
        encoding: .utf8
    )
    expect(
        archiveMarkdown?.contains("请识别刚才的两张图片") == true
            && expectedAttachmentPaths.allSatisfy {
                archiveMarkdown?.contains(URL(fileURLWithPath: $0).lastPathComponent) == true
            },
        "三条原始消息仍逐条写入真实微信归档"
    )
    expect(
        transport.sentTexts.first?.text == "微信图片识别链路完成"
            && transport.sentTexts.first?.contextToken == "wechat-e2e-caption-context",
        "真 Pi 文件控制块不外显且最终文本只回复最后会话上下文"
    )
    expect(
        transport.uploaded.first?.fileName == "AGENTS.md"
            && transport.uploaded.first?.kind == .file
            && transport.sentItems.count == 2
            && transport.sentItems[0].items.first.map {
                if case .file(name: "AGENTS.md", media: _) = $0 { return true }
                return false
            } == true
            && transport.sentItems[1].items == [.text("微信图片识别链路完成")],
        "真 Pi 最终回复经解析后先上传发送工作区文件再发送文本"
    )
    let completedJobs = (try? store.jobs()) ?? []
    expect(
        completedJobs.count == 3
            && completedJobs.allSatisfy {
                $0.state == .completed
                    && $0.fromUserID.isEmpty
                    && $0.contextToken.isEmpty
                    && $0.messageText.isEmpty
            },
        "完整 E2E 的三个独立去重成员收口并清除载荷"
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
        "真 Pi 合并任务只收到两张图片的精确相对路径，不含图片正文/base64"
    )
    expect(
        imageObservation.batchOrderOK && imageObservation.initialCount == 1,
        "连续两图加文字按接收顺序形成一个真 Pi 初始 prompt"
    )
    expect(imageObservation.imageForwarded, "真 Pi 调用 read 后 Relay 透明转发 image_url")
    expect(
        imageObservation.persistedRedactedBeforeSecondRequest,
        "第二次模型请求到达且 Agent 未收口时，真 Pi JSONL 已不含图片正文"
    )

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
    let sessionDirectory = root
        .appendingPathComponent("runtime", isDirectory: true)
        .appendingPathComponent(role.id.uuidString, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    let persistedSessions = ((try? FileManager.default.contentsOfDirectory(
        at: sessionDirectory,
        includingPropertiesForKeys: [.isRegularFileKey]
    )) ?? []).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
    expect(
        !persistedSessions.contains((imageData as Data).base64EncodedString())
            && !persistedSessions.contains(#""type":"image","data""#),
        "真 Pi 完成识图后持久会话不保留图片正文/base64"
    )
    await runtime.stopAll()
}

private struct TogentFileReplyScenarioResult {
    var state: TogentJobState?
    var uploadedNames: [String]
    var uploadedKinds: [WeChatOutboundMediaKind]
    var uploadedPayloads: [Data]
    var outboundKinds: [String]
    var visibleTexts: [String]
}

@MainActor
private func runTogentFileReplyScenario(
    _ label: String,
    reply: String,
    prepareWorkspace: (URL) -> Void,
    configureTransport: (MockWeChatTransport) -> Void = { _ in }
) async -> TogentFileReplyScenarioResult {
    let root = makeTogentTemporaryDirectory("file-reply-\(label)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let runtime = StubTogentRuntime()
    runtime.result = .success(reply)
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: {
            [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
        },
        bootstrapDefaultRole: false
    )
    var draft = togent.newRoleDraft()
    draft.name = "文件回复角色"
    draft.publishedModelID = "model-a"
    let role = try! togent.createRole(from: draft)
    let workspaceURL = URL(fileURLWithPath: role.workspacePath, isDirectory: true)
    prepareWorkspace(workspaceURL)

    let transport = MockWeChatTransport()
    configureTransport(transport)
    let association = WeChatAssociationService(
        transport: transport,
        credentialStore: MemoryWeChatCredentialStore(
            WeChatCredential(token: "bound", baseURL: WeChatILinkClient.officialBaseURL)
        ),
        stateStore: MemoryWeChatStateStore(),
        archiver: MockWeChatArchiver(),
        pageWriter: MockWeChatBindingPage(),
        opener: MockWeChatOpener(),
        notifier: MockWeChatNotifier(),
        sleeper: MockWeChatSleeper(),
        togent: togent
    )
    let lease = try! togent.beginInbound()!
    let deduplicationKey = "file-reply-\(label)"
    try! togent.stageInbound(
        message: WeChatMessage(
            fromUserID: "wechat-user",
            contextToken: "file-context",
            messageID: deduplicationKey,
            items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "把文件发给我"))]
        ),
        deduplicationKey: deduplicationKey,
        receivedAt: Date(),
        lease: lease
    )
    togent.endInbound(lease)
    try! togent.commitStagedInbound(deduplicationKey: deduplicationKey)
    _ = await waitForTogentCondition(timeout: 5) {
        guard let state = try? store.jobs().first?.state else { return false }
        return state == .completed || state == .failed
    }
    _ = association
    let state = try? store.jobs().first?.state
    let outboundKinds = transport.sentItems.flatMap(\.items).map { item in
        switch item {
        case .text: return "text"
        case .image: return "image"
        case .file: return "file"
        }
    }
    let result = TogentFileReplyScenarioResult(
        state: state,
        uploadedNames: transport.uploaded.map(\.fileName),
        uploadedKinds: transport.uploaded.map(\.kind),
        uploadedPayloads: transport.uploaded.map(\.data),
        outboundKinds: outboundKinds,
        visibleTexts: transport.sentTexts.map(\.text)
    )
    togent.stop()
    return result
}

@MainActor
func testTogentWorkspaceFileReplyAndFaults() async {
    let success = await runTogentFileReplyScenario(
        "success",
        reply: """
        文件已发送。
        <tocode_wechat_files>
        {"files":["project/report.txt","project/pixel.png"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { workspace in
            try! Data("report-body".utf8).write(
                to: workspace.appendingPathComponent("project/report.txt")
            )
            try! Data("image-body".utf8).write(
                to: workspace.appendingPathComponent("project/pixel.png")
            )
        }
    )
    expect(success.state == .completed, "工作区文件与文本全部发出后任务才标记完成")
    expect(
        success.uploadedNames == ["report.txt", "pixel.png"]
            && success.uploadedKinds == [.file, .image]
            && success.uploadedPayloads == [
                Data("report-body".utf8),
                Data("image-body".utf8)
            ],
        "Togent 按声明顺序上传文件并沿用图片类型识别"
    )
    expect(
        success.outboundKinds == ["file", "image", "text"]
            && success.visibleTexts == ["文件已发送。"]
            && success.visibleTexts.allSatisfy {
                !$0.contains("tocode_wechat_files")
            },
        "Togent 先发送全部文件再发送剥离控制块的用户可见文本"
    )

    let symlink = await runTogentFileReplyScenario(
        "symlink",
        reply: """
        <tocode_wechat_files>
        {"files":["project/link.txt"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { workspace in
            let target = workspace.appendingPathComponent("project/target.txt")
            try! Data("target".utf8).write(to: target)
            try! FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("project/link.txt"),
                withDestinationURL: target
            )
        }
    )
    expect(
        symlink.state == .failed && symlink.uploadedNames.isEmpty,
        "Togent 拒绝符号链接且文件失败不误标 completed"
    )

    let directory = await runTogentFileReplyScenario(
        "directory",
        reply: """
        <tocode_wechat_files>
        {"files":["project/folder"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { workspace in
            try! FileManager.default.createDirectory(
                at: workspace.appendingPathComponent("project/folder"),
                withIntermediateDirectories: true
            )
        }
    )
    expect(
        directory.state == .failed && directory.uploadedNames.isEmpty,
        "Togent 拒绝把目录作为微信文件发送"
    )

    let oversized = await runTogentFileReplyScenario(
        "oversized",
        reply: """
        <tocode_wechat_files>
        {"files":["project/large.bin"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { workspace in
            let url = workspace.appendingPathComponent("project/large.bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: url)
            try! handle.truncate(atOffset: UInt64(20 * 1_024 * 1_024 + 1))
            try! handle.close()
        }
    )
    expect(
        oversized.state == .failed && oversized.uploadedNames.isEmpty,
        "Togent 在上传前拒绝超过 20MB 的文件"
    )

    let escaped = await runTogentFileReplyScenario(
        "escape",
        reply: """
        <tocode_wechat_files>
        {"files":["../other-role/secret.txt"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { _ in }
    )
    expect(
        escaped.state == .failed && escaped.uploadedNames.isEmpty,
        "Togent 拒绝越出固定角色工作区的回复路径"
    )

    let uploadFailure = await runTogentFileReplyScenario(
        "upload-failure",
        reply: """
        <tocode_wechat_files>
        {"files":["project/report.txt"]}
        </tocode_wechat_files>
        """,
        prepareWorkspace: { workspace in
            try! Data("report".utf8).write(
                to: workspace.appendingPathComponent("project/report.txt")
            )
        },
        configureTransport: { $0.uploadError = TestWeChatError.forced }
    )
    expect(
        uploadFailure.state == .failed,
        "微信上传失败时 Togent durable job 保持失败语义"
    )
}
