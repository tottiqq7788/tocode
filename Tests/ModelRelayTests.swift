import Foundation
import AppKit
import Security

@MainActor
func testModelRelayPromptFormLayout() {
    let presets = ModelRelayPrompts.providerPresets
    expect(
        presets.map(\.baseURL) == [
            "https://api.openai.com/v1",
            "https://api.deepseek.com/v1",
            "https://api.moonshot.cn/v1",
            "https://api.siliconflow.cn/v1",
            "https://open.bigmodel.cn/api/paas/v4",
            "https://generativelanguage.googleapis.com/v1beta/openai",
            "https://api.x.ai/v1",
            "https://api.groq.com/openai/v1",
            "https://openrouter.ai/api/v1",
            "https://api.mistral.ai/v1"
        ],
        "模型厂商预设映射到固定官方 Base URL"
    )
    expect(Set(presets.map(\.title)).count == presets.count, "模型厂商预设名称唯一")
    expect(Set(presets.map(\.baseURL)).count == presets.count, "模型厂商预设 URL 唯一")
    expect(
        presets.allSatisfy {
            (try? ModelRelayValidation.normalizedBaseURL($0.baseURL)) == $0.baseURL
        },
        "模型厂商预设均为已规范化的安全 URL"
    )
    expect(
        ModelRelayPrompts.initialProviderDraft(existing: ModelRelayProvider(
            name: "预设",
            baseURL: presets[1].baseURL
        )).presetIndex == 1,
        "编辑厂家时识别既有预设"
    )
    let legacyURL = "http://127.0.0.1:11434/v1"
    let legacyDraft = ModelRelayPrompts.initialProviderDraft(existing: ModelRelayProvider(
        name: "旧自定义",
        baseURL: legacyURL
    ))
    expect(
        legacyDraft.presetIndex == nil
            && legacyDraft.customBaseURL == legacyURL,
        "旧自定义厂家编辑时保留原地址"
    )
    var newDraft = ModelRelayPrompts.initialProviderDraft()
    newDraft.name = "DeepSeek A"
    newDraft.presetIndex = 1
    newDraft.secret = "candidate-secret"
    expect(!newDraft.canSave(using: nil), "新增厂家测试前不可保存")
    let passedTest = ModelRelayProviderConnectionTest(
        providerID: nil,
        baseURL: presets[1].baseURL,
        secret: "candidate-secret",
        replacesKey: true,
        modelIDs: ["deepseek-model"]
    )
    expect(newDraft.canSave(using: passedTest), "当前地址和 Key 测试成功后可保存")
    newDraft.secret = "changed-secret"
    expect(!newDraft.canSave(using: passedTest), "Key 改动立即使连接测试失效")
    newDraft.secret = "candidate-secret"
    newDraft.presetIndex = nil
    newDraft.customBaseURL = "https://custom.example/v1"
    expect(!newDraft.canSave(using: passedTest), "地址改动立即使连接测试失效")

    let name = NSTextField()
    let provider = NSPopUpButton()
    provider.addItems(withTitles: presets.map(\.title))
    let accessory = ModelRelayPrompts.formAccessory(controls: [
        ("厂商", provider),
        ("名称", name)
    ])
    accessory.layoutSubtreeIfNeeded()

    expect(accessory.frame.width >= 400, "模型弹窗表单保留可输入宽度")
    expect(accessory.frame.height >= 60, "模型弹窗表单保留两行输入高度")
    expect(provider.frame.width >= 300 && provider.frame.height >= 20, "模型弹窗厂商下拉框未被压缩")
    expect(name.frame.width >= 300 && name.frame.height >= 20, "模型弹窗名称框未被压缩")
    expect(name.isEditable && name.isEnabled, "模型弹窗输入框可编辑")
    expect(AlertFocus.firstEditableTextField(in: accessory) === name, "模型弹窗默认聚焦名称输入框")

    let save = ModelRelayPrompts.formActionButton("保存")
    let test = ModelRelayPrompts.formActionButton("测试连接")
    let cancel = ModelRelayPrompts.formActionButton("取消")
    let buttons = ModelRelayPrompts.formButtonRow([save, test, cancel])
    buttons.layoutSubtreeIfNeeded()
    expect(
        (buttons as? NSStackView)?.orientation == .horizontal,
        "厂家弹窗动作按钮横向排列"
    )
    expect(buttons.frame.height <= 36, "厂家弹窗动作按钮保持单行高度")
    expect(save.frame.width >= 72 && test.frame.width >= 72 && cancel.frame.width >= 72, "厂家弹窗按钮保留可点宽度")

    let entity = ModelRelayProvider(name: "厂家 A", baseURL: presets[0].baseURL)
    let entityItem = ModelRelayPrompts.providerMenuItem(
        entity,
        busy: false,
        target: nil,
        action: NSSelectorFromString("manageProvider:")
    )
    expect(entityItem.action != nil && entityItem.submenu == nil, "厂家是普通可点击项，直接进入编辑弹窗")
    expect(entityItem.representedObject as? String == entity.id.uuidString, "厂家菜单项绑定实体 ID")
    let busyItem = ModelRelayPrompts.providerMenuItem(
        entity,
        busy: true,
        target: nil,
        action: NSSelectorFromString("manageProvider:")
    )
    expect(!busyItem.isEnabled, "厂家测试或刷新期间菜单项禁用")

    let local = try! ModelRelayLocalKeyVault(iterations: 1)
        .create(name: "本地客户端", viewingPassword: "password-123")
    let localItem = ModelRelayPrompts.localKeyMenuItem(
        local.record,
        target: nil,
        action: NSSelectorFromString("accessLocalKey:")
    )
    expect(localItem.action != nil && localItem.submenu == nil, "本地 Key 命名项仍是原点击操作")
    expect(localItem.representedObject as? String == local.record.id.uuidString, "本地 Key 菜单项绑定原记录")
}

func testModelRelayValidationConfigAndVault() {
    expect(
        (try? ModelRelayValidation.normalizedBaseURL("https://example.com")) == "https://example.com/v1",
        "模型中转远程 Base URL 默认补 /v1"
    )
    expect(
        (try? ModelRelayValidation.normalizedBaseURL("http://127.0.0.1:3000/")) == "http://127.0.0.1:3000/v1",
        "模型中转允许 loopback HTTP"
    )
    do {
        _ = try ModelRelayValidation.normalizedBaseURL("http://example.com/v1")
        expect(false, "模型中转拒绝远程 HTTP")
    } catch {
        expect(error as? ModelRelayError == .insecureRemoteBaseURL, "远程 HTTP 返回安全校验错误")
    }

    let fm = FileManager.default
    let home = fm.temporaryDirectory
        .appendingPathComponent("tocode-relay-config-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let store = FileModelRelayConfigStore(home: home.path)
    let provider = ModelRelayProvider(
        name: "测试厂商",
        baseURL: "https://example.com/v1",
        models: [ModelRelayModelRoute(upstreamModelID: "model-a", alias: "alias-a")]
    )
    let configuration = ModelRelayConfiguration(port: 28_000, providers: [provider])
    try! store.save(configuration)
    expect((try? store.load()) == configuration, "模型中转配置可完整往返")
    let mode = (try? fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?
        .intValue
    expect(mode == 0o600, "模型中转配置权限为 0600")
    try! fm.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: store.fileURL.path
    )
    try! store.save(configuration)
    let replacedMode = (try? fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?
        .intValue
    expect(replacedMode == 0o600, "覆盖保存先准备 0600 临时文件再原子替换")
    try! Data(
        #"{"version":1,"port":27800,"providers":[],"localKeys":[]}"#.utf8
    ).write(to: store.fileURL)
    expect(
        (try? store.load().pendingUpstreamKeyDeletions) == [],
        "旧配置缺少清理日志字段时向后兼容为空"
    )
    try! Data("{broken".utf8).write(to: store.fileURL)
    do {
        _ = try store.load()
        expect(false, "损坏的模型中转配置不得静默覆盖")
    } catch {
        expect(error as? ModelRelayError == .configurationCorrupt, "损坏配置返回 configurationCorrupt")
    }

    let vault = ModelRelayLocalKeyVault(iterations: 1)
    let created = try! vault.create(name: "本地客户端", viewingPassword: "password-123")
    expect(created.secret.hasPrefix("tc_"), "本地 Key 使用 tc_ 前缀")
    expect(created.secret.count >= 45, "本地 Key 包含 32 字节随机量")
    expect(
        (try? vault.reveal(created.record, viewingPassword: "password-123")) == created.secret,
        "正确查看密码可解密本地 Key"
    )
    do {
        _ = try vault.reveal(created.record, viewingPassword: "wrong-password")
        expect(false, "错误查看密码不可解密")
    } catch {
        expect(error as? ModelRelayError == .wrongViewingPassword, "错误查看密码返回明确错误")
    }
    expect(vault.authenticates(created.secret, records: [created.record]), "本地 Key 摘要鉴权成功")
    expect(!vault.authenticates("tc_invalid", records: [created.record]), "错误本地 Key 鉴权失败")
}

func testModelRelayHTTPParser() {
    let body = Data("{\"model\":\"demo\"}".utf8)
    var request = Data(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8
    )
    request.append(body)
    expect(try! ModelRelayHTTPParser.parse(request.prefix(request.count - 2)) == nil, "Content-Length 分帧不完整时继续等待")
    let parsed = try! ModelRelayHTTPParser.parse(request)
    expect(parsed?.request.body == body, "Content-Length 请求正文解析正确")
    expect(parsed?.request.target == "/v1/chat/completions", "HTTP 请求路径解析正确")

    let chunked = Data(
        "POST /v1/responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8
    )
    let chunkedParsed = try! ModelRelayHTTPParser.parse(chunked)
    expect(String(data: chunkedParsed!.request.body, encoding: .utf8) == "hello world", "chunked 入站正文解析正确")

    let malformed = Data("GET /v1/models HTTP/1.1\r\nBadHeader\r\n\r\n".utf8)
    do {
        _ = try ModelRelayHTTPParser.parse(malformed)
        expect(false, "畸形请求头应拒绝")
    } catch {
        expect(error as? ModelRelayHTTPParseError == .malformedRequest, "畸形请求头返回 malformedRequest")
    }
    let oversized = Data(repeating: 65, count: ModelRelayHTTPParser.maximumHeaderBytes + 1)
    do {
        _ = try ModelRelayHTTPParser.parse(oversized)
        expect(false, "超限请求头应拒绝")
    } catch {
        expect(error as? ModelRelayHTTPParseError == .headersTooLarge, "请求头执行 64 KiB 限制")
    }
    let overflowingChunk = Data(
        "POST /v1/responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n".utf8
    )
    do {
        _ = try ModelRelayHTTPParser.parse(overflowingChunk)
        expect(false, "超大 chunk 声明应拒绝且不得整数溢出")
    } catch {
        expect(error as? ModelRelayHTTPParseError == .bodyTooLarge, "chunk 大小执行 64 MiB 限制")
    }
}

func testModelRelayRouterAndControlPlane() {
    let vault = ModelRelayLocalKeyVault(iterations: 1)
    let local = try! vault.create(name: "client", viewingPassword: "password-123")
    let firstKey = ModelRelayUpstreamKeyReference(name: "first")
    let provider = ModelRelayProvider(
        name: "provider",
        baseURL: "https://example.com/v1",
        keys: [firstKey],
        models: [ModelRelayModelRoute(upstreamModelID: "upstream-a", alias: "local-a")]
    )
    let configuration = ModelRelayConfiguration(
        providers: [provider],
        localKeys: [local.record]
    )
    let keyStore = MemoryModelRelayKeyStore([firstKey.id: "upstream-key-1"])
    let clock = MutableModelRelayClock()
    let router = ModelRelayRouter(
        configuration: configuration,
        keyStore: keyStore,
        vault: vault,
        now: { clock.now }
    )
    expect(router.authenticate(local.secret), "路由器接受正确本地 Key")
    expect(!router.authenticate("wrong"), "路由器拒绝错误本地 Key")
    let first = try! router.resolve(alias: "local-a")
    let second = try! router.resolve(alias: "local-a")
    expect(first.candidates.map(\.keyID) == [firstKey.id], "厂家只解析唯一上游 Key")
    expect(second.candidates.map(\.keyID) == [firstKey.id], "重复请求不做 Key 轮询")

    router.recordFailure(keyID: firstKey.id, statusCode: 401)
    do {
        _ = try router.resolve(alias: "local-a")
        expect(false, "401 后唯一 Key 保持不可用直至手动重置")
    } catch {
        expect(error as? ModelRelayError == .noHealthyUpstream, "唯一 Key 鉴权失败后明确失败")
    }
    router.resetHealth(keyIDs: [firstKey.id])
    expect(try! router.resolve(alias: "local-a").candidates.first?.keyID == firstKey.id, "手动刷新重置 401 健康状态")

    router.recordFailure(keyID: firstKey.id, statusCode: 429)
    do {
        _ = try router.resolve(alias: "local-a")
        expect(false, "429 后唯一 Key 在冷却期内不可用")
    } catch {
        expect(error as? ModelRelayError == .noHealthyUpstream, "429 冷却期明确失败")
    }
    clock.now = clock.now.addingTimeInterval(61)
    expect(
        try! router.resolve(alias: "local-a").candidates.first?.keyID == firstKey.id,
        "429 Key 冷却后自动恢复"
    )

    let deniedRouter = ModelRelayRouter(
        configuration: configuration,
        keyStore: DeniedModelRelayKeyStore(),
        vault: vault
    )
    expect(deniedRouter.availableAliases().isEmpty, "Keychain 拒绝时不公布可用模型")
    do {
        _ = try deniedRouter.resolve(alias: "local-a")
        expect(false, "Keychain 拒绝时不得回退明文或继续路由")
    } catch {
        if let relayError = error as? ModelRelayError,
           case .keychain = relayError {
            expect(true, "Keychain 拒绝时路由失败关闭")
        } else {
            expect(false, "Keychain 拒绝应返回钥匙串错误")
        }
    }

    let missingReference = ModelRelayUpstreamKeyReference(name: "temporarily-missing")
    let missingConfiguration = ModelRelayConfiguration(providers: [
        ModelRelayProvider(
            name: "missing-provider",
            baseURL: "https://missing.example/v1",
            keys: [missingReference],
            models: [ModelRelayModelRoute(upstreamModelID: "missing-upstream", alias: "missing-local")]
        )
    ])
    let missingStore = MemoryModelRelayKeyStore()
    let missingClock = MutableModelRelayClock()
    let missingRouter = ModelRelayRouter(
        configuration: missingConfiguration,
        keyStore: missingStore,
        vault: vault,
        now: { missingClock.now }
    )
    do {
        _ = try missingRouter.resolve(alias: "missing-local")
        expect(false, "Keychain 条目缺失时不得路由")
    } catch {
        expect(error as? ModelRelayError == .noHealthyUpstream, "Keychain 条目缺失时失败关闭")
    }
    try! missingStore.save("restored-secret", id: missingReference.id)
    missingClock.now = missingClock.now.addingTimeInterval(31)
    expect(
        try! missingRouter.resolve(alias: "missing-local").candidates.first?.keyID == missingReference.id,
        "Keychain 条目恢复后可在有限冷却结束时重新路由"
    )

    let initial = ModelRelayConfiguration(providers: [
        ModelRelayProvider(
            name: "one",
            baseURL: "https://one.example/v1",
            models: [
                ModelRelayModelRoute(upstreamModelID: "a", alias: "custom-a"),
                ModelRelayModelRoute(upstreamModelID: "b", alias: "custom-b")
            ]
        ),
        ModelRelayProvider(
            name: "two",
            baseURL: "https://two.example/v1",
            models: [
                ModelRelayModelRoute(upstreamModelID: "a", alias: "still-custom")
            ]
        )
    ])
    let service = ModelRelayService(
        configStore: MemoryModelRelayConfigStore(initial),
        upstreamKeyStore: MemoryModelRelayKeyStore(),
        localKeyVault: vault,
        upstreamClient: ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    )
    expect(
        service.snapshot().providers.flatMap(\.models).map(\.alias).sorted() == ["a", "b", "two/a"],
        "启动时剥离人工别名，冲突上游 id 自动加厂家前缀"
    )
    _ = try! service.createLocalKey(name: "client-a", password: "password-123")
    do {
        _ = try service.createLocalKey(name: "CLIENT-A", password: "password-456")
        expect(false, "本地 Key 名称应保持唯一")
    } catch {
        expect(error as? ModelRelayError == .duplicateKeyName, "重复本地 Key 名返回明确错误")
    }
}

func testModelRelayValidatedKeyControlPlane() async {
    func testConnection(
        _ service: ModelRelayService,
        providerID: UUID? = nil,
        baseURL: String,
        secret: String?
    ) async -> Result<ModelRelayProviderConnectionTest, Error> {
        await withCheckedContinuation { continuation in
            service.testProviderConnection(
                providerID: providerID,
                baseURL: baseURL,
                candidateSecret: secret
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    let firstKey = ModelRelayUpstreamKeyReference(name: "默认")
    let firstProvider = ModelRelayProvider(
        name: "first",
        baseURL: "https://first.example/v1",
        keys: [firstKey],
        models: [ModelRelayModelRoute(upstreamModelID: "shared", alias: "shared")]
    )
    let configStore = MemoryModelRelayConfigStore(ModelRelayConfiguration(providers: [firstProvider]))
    let keyStore = MemoryModelRelayKeyStore([firstKey.id: "first-secret"])
    let client = ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    let service = ModelRelayService(
        configStore: configStore,
        upstreamKeyStore: keyStore,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    configStore.saveObserver = { candidate in
        let storedIDs = Set(keyStore.snapshot.keys)
        expect(
            candidate.providers.flatMap(\.keys).allSatisfy { storedIDs.contains($0.id) },
            "每次配置提交时所有可路由 Key 引用均已有对应 Keychain 项"
        )
    }
    ModelRelayURLProtocol.reset { request in
        expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-secret",
            "新增厂家保存前使用待保存 Key 测试目录"
        )
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"shared\"}]}".utf8)]
        )
    }
    expect(service.snapshot().providers.count == 1 && keyStore.snapshot.count == 1, "测试前不写配置或钥匙串")
    let tested = await testConnection(
        service,
        baseURL: "https://second.example/v1",
        secret: "valid-secret"
    )
    guard case .success(let connection) = tested else {
        expect(false, "有效厂家连接应测试成功")
        return
    }
    expect(service.snapshot().providers.count == 1 && keyStore.snapshot.count == 1, "测试成功仍不提前持久化")
    let secondProvider: ModelRelayProvider
    do {
        secondProvider = try service.createProvider(name: "second", using: connection)
        expect(secondProvider.keys.count == 1, "厂家实体只保存一个上游 Key")
        expect(secondProvider.models.first?.alias == "second/shared", "冲突模型自动使用 厂家/model-id")
        expect(
            secondProvider.upstreamKey.flatMap { try? keyStore.load(id: $0.id) } == "valid-secret",
            "保存后 secret 只进入 Keychain 抽象"
        )
    } catch {
        expect(false, "测试成功的厂家应原子保存：\(error)")
        return
    }

    do {
        _ = try service.createProvider(name: "SECOND", using: connection)
        expect(false, "厂家名称应忽略大小写保持唯一")
    } catch {
        expect(error as? ModelRelayError == .duplicateProviderName, "重复厂家名返回明确错误")
    }
    expect(service.snapshot().providers.count == 2, "重复名称失败不留下空厂家")
    expect(keyStore.snapshot.count == 2, "重复名称失败回滚临时 Keychain 项")

    do {
        let duplicatePreset = try service.createProvider(name: "second-b", using: connection)
        expect(duplicatePreset.baseURL == secondProvider.baseURL, "同一厂商预设可用不同名称重复创建")
        expect(duplicatePreset.keys.count == 1, "重复预设仍保持一厂家一 Key")
    } catch {
        expect(false, "同一预设不同名称应允许保存：\(error)")
    }

    let extraKeyResult: Result<ModelRelayUpstreamKeyReference, Error> = await withCheckedContinuation { continuation in
        service.addUpstreamKey(
            providerID: secondProvider.id,
            name: "extra",
            secret: "extra-secret"
        ) {
            continuation.resume(returning: $0)
        }
    }
    if case .failure(let error) = extraKeyResult {
        expect(error as? ModelRelayError == .providerAlreadyHasKey, "已配置厂家拒绝第二个 Key")
    } else {
        expect(false, "厂家不得新增第二个 Key")
    }

    let originalReference = secondProvider.upstreamKey!
    var currentReference = originalReference
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(status: 401, chunks: [Data("{\"error\":\"unauthorized\"}".utf8)])
    }
    let rejectedReplacement = await testConnection(
        service,
        providerID: secondProvider.id,
        baseURL: secondProvider.baseURL,
        secret: "invalid-secret"
    )
    if case .success = rejectedReplacement {
        expect(false, "连接失败的替换 Key 不得产生测试凭证")
    } else {
        expect(true, "连接失败的替换 Key 被拒绝")
    }
    expect((try? keyStore.load(id: originalReference.id)) == "valid-secret", "测试失败保留原上游 Key")

    ModelRelayURLProtocol.reset { request in
        expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-secret",
            "编辑厂家测试使用候选新 Key"
        )
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"replacement-model\"}]}".utf8)]
        )
    }
    let replacementTest = await testConnection(
        service,
        providerID: secondProvider.id,
        baseURL: "https://custom.example/v1",
        secret: "replacement-secret"
    )
    if case .success(let replacement) = replacementTest {
        do {
            try service.updateProvider(id: secondProvider.id, name: "second-custom", using: replacement)
            let updated = service.snapshot().providers.first { $0.id == secondProvider.id }
            expect(updated?.baseURL == "https://custom.example/v1", "测试后的自定义地址可保存")
            expect(updated?.keys.count == 1, "替换后仍只有一个上游 Key")
            expect(updated?.models.first?.upstreamModelID == "replacement-model", "保存测试得到的模型快照")
            if let updatedReference = updated?.upstreamKey {
                expect(updatedReference.id != originalReference.id, "连接变更使用新的 Keychain UUID")
                expect((try? keyStore.load(id: originalReference.id)) == nil, "连接切换删除旧 UUID")
                expect((try? keyStore.load(id: updatedReference.id)) == "replacement-secret", "新 UUID 保存候选 Key")
                currentReference = updatedReference
            } else {
                expect(false, "替换后厂家仍应持有唯一 Key")
            }
        } catch {
            expect(false, "测试成功的厂家编辑应保存：\(error)")
        }
    } else {
        expect(false, "候选新地址与 Key 应测试成功")
    }

    ModelRelayURLProtocol.reset { request in
        expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-secret",
            "只改地址时使用当前已存 Key 测试"
        )
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"url-only-model\"}]}".utf8)]
        )
    }
    let urlOnlyTest = await testConnection(
        service,
        providerID: secondProvider.id,
        baseURL: "https://url-only.example/v1",
        secret: nil
    )
    if case .success(let connection) = urlOnlyTest {
        let beforeURLChange = currentReference
        do {
            try service.updateProvider(id: secondProvider.id, name: "second-custom", using: connection)
            let updated = service.snapshot().providers.first { $0.id == secondProvider.id }
            if let updatedReference = updated?.upstreamKey {
                expect(updatedReference.id != beforeURLChange.id, "只改 URL 也轮换 Key UUID")
                expect((try? keyStore.load(id: beforeURLChange.id)) == nil, "只改 URL 后删除旧连接 UUID")
                expect((try? keyStore.load(id: updatedReference.id)) == "replacement-secret", "只改 URL 时安全迁移原 Key")
                currentReference = updatedReference
            } else {
                expect(false, "只改 URL 后仍应持有唯一 Key")
            }
        } catch {
            expect(false, "通过测试的 URL 单独修改应保存：\(error)")
        }
    } else {
        expect(false, "只改 URL 时当前 Key 应可通过连接测试")
    }

    do {
        try service.updateProvider(id: secondProvider.id, name: "renamed-only", using: nil)
        expect(
            service.snapshot().providers.first { $0.id == secondProvider.id }?.name == "renamed-only",
            "只改名称无需重新测试连接"
        )
    } catch {
        expect(false, "只改名称应成功：\(error)")
    }

    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"rollback-model\"}]}".utf8)]
        )
    }
    let replacementRollbackTest = await testConnection(
        service,
        providerID: secondProvider.id,
        baseURL: "https://rollback.example/v1",
        secret: "rollback-candidate"
    )
    configStore.saveError = ModelRelayError.configurationCorrupt
    if case .success(let test) = replacementRollbackTest {
        do {
            try service.updateProvider(id: secondProvider.id, name: "should-not-save", using: test)
            expect(false, "配置失败时替换 Key 应失败")
        } catch {
            expect(true, "替换 Key 配置失败被传播")
        }
    }
    expect(
        (try? keyStore.load(id: currentReference.id)) == "replacement-secret",
        "替换配置失败时恢复原 Keychain secret"
    )
    expect(!keyStore.snapshot.values.contains("rollback-candidate"), "替换配置失败不遗留候选 Keychain 项")
    expect(
        service.snapshot().providers.first { $0.id == secondProvider.id }?.name == "renamed-only",
        "替换配置失败时保留原厂家元数据"
    )
    do {
        try service.deleteProvider(id: secondProvider.id)
        expect(false, "配置失败时删除厂家应失败")
    } catch {
        expect(true, "删除厂家配置失败被传播")
    }
    expect(
        service.snapshot().providers.contains { $0.id == secondProvider.id }
            && (try? keyStore.load(id: currentReference.id)) == "replacement-secret",
        "删除配置失败时恢复厂家及 Keychain"
    )
    configStore.saveError = nil
    do {
        try service.deleteProvider(id: secondProvider.id)
        expect(!service.snapshot().providers.contains { $0.id == secondProvider.id }, "删除厂家移除元数据")
        expect((try? keyStore.load(id: currentReference.id)) == nil, "删除厂家移除唯一 Keychain secret")
    } catch {
        expect(false, "恢复后厂家应可删除：\(error)")
    }

    let rollbackStore = MemoryModelRelayConfigStore()
    let rollbackKeys = MemoryModelRelayKeyStore()
    let rollbackService = ModelRelayService(
        configStore: rollbackStore,
        upstreamKeyStore: rollbackKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"atomic-model\"}]}".utf8)]
        )
    }
    let rollbackTest = await testConnection(
        rollbackService,
        baseURL: "https://atomic.example/v1",
        secret: "atomic-secret"
    )
    rollbackStore.saveError = ModelRelayError.configurationCorrupt
    if case .success(let connection) = rollbackTest {
        do {
            _ = try rollbackService.createProvider(name: "atomic", using: connection)
            expect(false, "配置保存失败时厂家创建应失败")
        } catch {
            expect(true, "配置保存失败被原样传播")
        }
    }
    expect(rollbackService.snapshot().providers.isEmpty, "配置失败不留下厂家元数据")
    expect(rollbackKeys.snapshot.isEmpty, "配置失败回滚 Keychain 项")

    let cleanupStore = MemoryModelRelayConfigStore()
    let cleanupKeys = MemoryModelRelayKeyStore()
    let cleanupService = ModelRelayService(
        configStore: cleanupStore,
        upstreamKeyStore: cleanupKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    cleanupStore.failOnSaveNumber = 2
    cleanupKeys.deleteError = ModelRelayError.keychain(errSecAuthFailed)
    if case .success(let connection) = rollbackTest {
        do {
            _ = try cleanupService.createProvider(name: "cleanup-failure", using: connection)
            expect(false, "配置与回滚都失败时不得报告成功")
        } catch let error as ModelRelayError {
            if case .persistenceRollback = error {
                expect(true, "Keychain 清理失败返回明确持久化回滚错误")
            } else {
                expect(false, "Keychain 清理失败应返回 persistenceRollback")
            }
        } catch {
            expect(false, "Keychain 清理失败应返回模型中转错误")
        }
    }
    expect(cleanupStore.configuration.pendingUpstreamKeyDeletions.count == 1, "清理失败保留持久化删除日志")
    expect(cleanupKeys.snapshot.values.contains("atomic-secret"), "清理失败的候选 Key 仍由删除日志跟踪")
    cleanupKeys.deleteError = nil
    _ = ModelRelayService(
        configStore: cleanupStore,
        upstreamKeyStore: cleanupKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    expect(cleanupStore.configuration.pendingUpstreamKeyDeletions.isEmpty, "重启恢复会清空候选 Key 删除日志")
    expect(cleanupKeys.snapshot.isEmpty, "重启恢复会删除已记录的候选 Key")

    let deferredReference = ModelRelayUpstreamKeyReference(name: "默认")
    let deferredProvider = ModelRelayProvider(
        name: "deferred",
        baseURL: "https://deferred.example/v1",
        keys: [deferredReference],
        models: [ModelRelayModelRoute(upstreamModelID: "before", alias: "before")]
    )
    let deferredStore = MemoryModelRelayConfigStore(
        ModelRelayConfiguration(providers: [deferredProvider])
    )
    let deferredKeys = MemoryModelRelayKeyStore([deferredReference.id: "deferred-secret"])
    let deferredService = ModelRelayService(
        configStore: deferredStore,
        upstreamKeyStore: deferredKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    deferredKeys.deleteErrorIDs = [deferredReference.id]
    do {
        try deferredService.updateProvider(
            id: deferredProvider.id,
            name: deferredProvider.name,
            using: ModelRelayProviderConnectionTest(
                providerID: deferredProvider.id,
                baseURL: "https://deferred-new.example/v1",
                secret: "deferred-new-secret",
                replacesKey: true,
                modelIDs: ["after"]
            )
        )
        expect(true, "旧 Key 暂时无法删除时新连接仍保持一致可用")
    } catch {
        expect(false, "有持久化删除日志时连接切换不应失败：\(error)")
    }
    let deferredUpdated = deferredService.snapshot().providers.first { $0.id == deferredProvider.id }
    expect(deferredUpdated?.baseURL == "https://deferred-new.example/v1", "延迟清理不回滚已提交的新连接")
    expect(
        deferredStore.configuration.pendingUpstreamKeyDeletions == [deferredReference.id],
        "旧 Key 删除失败进入持久化清理日志"
    )
    deferredKeys.deleteErrorIDs = []
    _ = ModelRelayService(
        configStore: deferredStore,
        upstreamKeyStore: deferredKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    expect(deferredStore.configuration.pendingUpstreamKeyDeletions.isEmpty, "重启重试后移除旧 Key 清理日志")
    expect(deferredKeys.snapshot[deferredReference.id] == nil, "重启重试删除旧连接 Key")
    expect(
        deferredUpdated?.upstreamKey.flatMap { deferredKeys.snapshot[$0.id] } == "deferred-new-secret",
        "重启清理不影响当前连接 Key"
    )

    let deniedConfig = MemoryModelRelayConfigStore()
    let deniedService = ModelRelayService(
        configStore: deniedConfig,
        upstreamKeyStore: DeniedModelRelayKeyStore(),
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    let deniedTest = await testConnection(
        deniedService,
        baseURL: "https://denied.example/v1",
        secret: "denied-secret"
    )
    if case .success(let connection) = deniedTest {
        do {
            _ = try deniedService.createProvider(name: "denied", using: connection)
            expect(false, "Keychain 拒绝时厂家不得保存")
        } catch {
            if let relayError = error as? ModelRelayError, case .keychain = relayError {
                expect(true, "Keychain 拒绝原样传播")
            } else {
                expect(false, "Keychain 拒绝应返回钥匙串错误")
            }
        }
    }
    expect(deniedConfig.configuration.providers.isEmpty, "Keychain 拒绝时不写厂家配置")

    let legacyA = ModelRelayUpstreamKeyReference(name: "A")
    let legacyB = ModelRelayUpstreamKeyReference(name: "B")
    let legacyProvider = ModelRelayProvider(
        name: "legacy",
        baseURL: "https://legacy.example/v1",
        keys: [legacyA, legacyB],
        models: [ModelRelayModelRoute(upstreamModelID: "legacy-model", alias: "legacy-model")]
    )
    let legacyStore = MemoryModelRelayConfigStore(
        ModelRelayConfiguration(providers: [legacyProvider])
    )
    let legacyService = ModelRelayService(
        configStore: legacyStore,
        upstreamKeyStore: MemoryModelRelayKeyStore([
            legacyA.id: "legacy-a",
            legacyB.id: "legacy-b"
        ]),
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    let migrated = legacyService.snapshot().providers
    expect(migrated.count == 2, "历史多 Key 厂家无损拆成多个实体")
    expect(migrated.allSatisfy { $0.keys.count == 1 }, "迁移后每个厂家只有一个 Key")
    expect(
        Set(migrated.compactMap { $0.upstreamKey?.id }) == Set([legacyA.id, legacyB.id]),
        "迁移保留全部 Keychain UUID"
    )
    expect(Set(migrated.map { $0.name.lowercased() }).count == 2, "迁移生成唯一厂家名称")
    expect(migrated.allSatisfy { $0.models.map(\.upstreamModelID) == ["legacy-model"] }, "迁移后每个厂家立即保留模型目录")
    expect(
        Set(migrated.flatMap(\.models).map { $0.alias.lowercased() }).count == 2,
        "迁移后自动派生全局唯一模型名"
    )
    expect(
        migrated.contains { $0.models.contains { $0.alias == "legacy-model" } },
        "首个厂家直接暴露上游 model id"
    )
    expect(legacyStore.configuration.providers == migrated, "迁移结果原子写回配置")

    let corruptStore = CorruptModelRelayConfigStore()
    let unavailableService = ModelRelayService(
        configStore: corruptStore,
        upstreamKeyStore: MemoryModelRelayKeyStore(),
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    if case .failed = unavailableService.runState {
        expect(true, "配置损坏时服务保持明确失败状态")
    } else {
        expect(false, "配置损坏时服务不得伪装为可运行")
    }
    do {
        try unavailableService.start()
        expect(false, "配置损坏时不得启动空配置 listener")
    } catch {
        expect(error as? ModelRelayError == .configurationCorrupt, "配置损坏时启动失败关闭")
    }
    let corruptPortResult: Result<Void, Error> = await withCheckedContinuation { continuation in
        unavailableService.updatePort(28_001) {
            continuation.resume(returning: $0)
        }
    }
    if case .success = corruptPortResult {
        expect(false, "配置损坏时不得借改端口覆盖配置")
    } else {
        expect(true, "配置损坏时拒绝改端口")
    }
    expect(corruptStore.saveCount == 0, "配置损坏时不写回默认配置")
}

func testModelRelayStaleRefreshCannotOverwriteNewConnection() async {
    let oldReference = ModelRelayUpstreamKeyReference(name: "默认")
    let provider = ModelRelayProvider(
        name: "stale-refresh",
        baseURL: "https://old-refresh.example/v1",
        keys: [oldReference],
        models: [ModelRelayModelRoute(upstreamModelID: "old-model", alias: "old-model")]
    )
    let keyStore = MemoryModelRelayKeyStore([oldReference.id: "old-secret"])
    let service = ModelRelayService(
        configStore: MemoryModelRelayConfigStore(
            ModelRelayConfiguration(providers: [provider])
        ),
        upstreamKeyStore: keyStore,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: ModelRelayUpstreamClient(
            sessionConfiguration: modelRelayTestSessionConfiguration()
        )
    )
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    ModelRelayURLProtocol.reset { _ in
        started.signal()
        _ = release.wait(timeout: .now() + 2)
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"stale-model\"}]}".utf8)]
        )
    }
    let refresh = Task {
        await withCheckedContinuation { continuation in
            service.fetchModels(providerID: provider.id) {
                continuation.resume(returning: $0)
            }
        }
    }
    expect(waitForModelRelaySignal(started), "旧连接模型刷新已发出")

    do {
        try service.updateProvider(
            id: provider.id,
            name: provider.name,
            using: ModelRelayProviderConnectionTest(
                providerID: provider.id,
                baseURL: "https://new-refresh.example/v1",
                secret: "new-secret",
                replacesKey: true,
                modelIDs: ["fresh-model"]
            )
        )
    } catch {
        release.signal()
        expect(false, "新连接应在旧刷新返回前保存：\(error)")
        _ = await refresh.value
        return
    }
    release.signal()
    let refreshResult = await refresh.value
    if case .failure(let error) = refreshResult {
        expect(error as? ModelRelayError == .providerNotFound, "过期刷新被连接版本校验拒绝")
    } else {
        expect(false, "过期刷新不得覆盖新连接模型")
    }
    let updated = service.snapshot().providers.first { $0.id == provider.id }
    expect(updated?.baseURL == "https://new-refresh.example/v1", "过期刷新后仍保留新连接地址")
    expect(updated?.models.map(\.upstreamModelID) == ["fresh-model"], "过期刷新不能覆盖新模型目录")
    expect(updated?.upstreamKey?.id != oldReference.id, "连接版本通过新 Key UUID 隔离")
    expect(keyStore.snapshot[oldReference.id] == nil, "新连接提交后旧 Key 已删除")
}

func testModelRelayUpstreamProxy() async {
    let vault = ModelRelayLocalKeyVault(iterations: 1)
    let keyStore = MemoryModelRelayKeyStore()
    let router = ModelRelayRouter(
        configuration: ModelRelayConfiguration(),
        keyStore: keyStore,
        vault: vault
    )
    let client = ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())

    ModelRelayURLProtocol.reset { request in
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer catalog-key", "模型目录请求携带上游 Bearer")
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"object\":\"list\",\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"a\"}]}".utf8)]
        )
    }
    do {
        let models = try await client.fetchModels(baseURL: "https://catalog.example/v1", secret: "catalog-key")
        expect(models == ["a", "b"], "上游模型目录去重并排序")
    } catch {
        expect(false, "上游模型目录请求应成功：\(error)")
    }
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(status: 401, chunks: [Data()])
    }
    do {
        _ = try await client.fetchModels(baseURL: "https://catalog.example/v1", secret: "invalid")
        expect(false, "模型目录 401 应失败")
    } catch {
        expect(error as? ModelRelayError == .upstreamHTTP(401), "模型目录保留 401 状态供健康路由永久隔离")
    }

    let firstID = UUID()
    let secondID = UUID()
    let route = ModelRelayResolvedRoute(alias: "local-model", candidates: [
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
            providerName: "厂家",
            keyID: firstID,
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "bad-key"
        ),
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
            providerName: "厂家",
            keyID: secondID,
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "good-key"
        )
    ])
    ModelRelayURLProtocol.reset { request in
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer bad-key" {
            return ModelRelayStubResponse(status: 500, chunks: [Data("bad".utf8)])
        }
        let object = try! JSONSerialization.jsonObject(with: modelRelayURLRequestBody(request)) as! [String: Any]
        expect(object["model"] as? String == "upstream-model", "代理将本地别名替换为上游模型 id")
        return ModelRelayStubResponse(status: 200, chunks: [Data("{\"ok\":true}".utf8)])
    }
    do {
        let output = try await runModelRelayProxy(
            client: client,
            request: modelRelayRequest(),
            route: route,
            router: router
        )
        let text = String(data: output, encoding: .utf8) ?? ""
        expect(text.contains("HTTP/1.1 502"), "唯一上游 5xx 时明确返回 502")
        expect(!text.contains("{\"ok\":true}"), "唯一上游失败时不伪装成功")
        expect(ModelRelayURLProtocol.requests.count == 1, "代理不会尝试第二个 Key")
    } catch {
        expect(false, "唯一上游 5xx 应生成明确失败响应：\(error)")
    }

    for status in [401, 403, 429] {
        let statusRoute = ModelRelayResolvedRoute(alias: "local-model", candidates: [
            ModelRelayUpstreamCandidate(
                providerID: UUID(),
                providerName: "厂家",
                keyID: UUID(),
                baseURL: "https://proxy.example/v1",
                upstreamModelID: "upstream-model",
                secret: "status-\(status)"
            ),
            ModelRelayUpstreamCandidate(
                providerID: UUID(),
                providerName: "厂家",
                keyID: UUID(),
                baseURL: "https://proxy.example/v1",
                upstreamModelID: "upstream-model",
                secret: "status-good"
            )
        ])
        ModelRelayURLProtocol.reset { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer status-\(status)" {
                return ModelRelayStubResponse(status: status)
            }
            return ModelRelayStubResponse(status: 200, chunks: [Data("{\"ok\":true}".utf8)])
        }
        do {
            let output = try await runModelRelayProxy(
                client: client,
                request: modelRelayRequest(),
                route: statusRoute,
                router: router
            )
            expect(
                String(data: output, encoding: .utf8)?.contains("HTTP/1.1 502") == true
                    && ModelRelayURLProtocol.requests.count == 1,
                "唯一上游 HTTP \(status) 明确失败且不切 Key"
            )
        } catch {
            expect(false, "HTTP \(status) 应生成明确失败响应：\(error)")
        }
    }

    let networkRoute = ModelRelayResolvedRoute(alias: "local-model", candidates: [
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
            providerName: "厂家",
            keyID: UUID(),
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "network-bad"
        ),
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
            providerName: "厂家",
            keyID: UUID(),
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "network-good"
        )
    ])
    ModelRelayURLProtocol.reset { request in
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer network-bad" {
            throw URLError(.cannotConnectToHost)
        }
        return ModelRelayStubResponse(status: 200, chunks: [Data("{\"ok\":true}".utf8)])
    }
    do {
        let output = try await runModelRelayProxy(
            client: client,
            request: modelRelayRequest(),
            route: networkRoute,
            router: router
        )
        expect(
            String(data: output, encoding: .utf8)?.contains("HTTP/1.1 502") == true
                && ModelRelayURLProtocol.requests.count == 1,
            "唯一上游连接失败明确返回 502 且不切 Key"
        )
    } catch {
        expect(false, "连接失败应生成明确失败响应：\(error)")
    }

    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [
                Data("data: first\n\n".utf8),
                Data("data: [DONE]\n\n".utf8)
            ]
        )
    }
    do {
        let output = try await runModelRelayProxy(
            client: client,
            request: modelRelayRequest(),
            route: ModelRelayResolvedRoute(alias: "local-model", candidates: [route.candidates[1]]),
            router: router
        )
        let text = String(data: output, encoding: .utf8) ?? ""
        expect(text.contains("Transfer-Encoding: chunked"), "SSE 使用 chunked 增量回写")
        expect(text.contains("data: first"), "SSE 首块及时透传")
        expect(text.hasSuffix("0\r\n\r\n"), "正常 SSE 以终止 chunk 结束")
    } catch {
        expect(false, "SSE 代理应成功：\(error)")
    }

    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data("data: partial\n\n".utf8)],
            errorAfterChunks: URLError(.networkConnectionLost)
        )
    }
    do {
        let output = try await runModelRelayProxy(
            client: client,
            request: modelRelayRequest(),
            route: route,
            router: router
        )
        let text = String(data: output, encoding: .utf8) ?? ""
        expect(ModelRelayURLProtocol.requests.count == 1, "流开始后网络失败禁止尝试下一 Key")
        expect(text.contains("data: partial"), "流开始后的已收数据不被丢弃")
        expect(!text.hasSuffix("0\r\n\r\n"), "截断流不伪造正常终止 chunk")
    } catch {
        expect(false, "截断流应结束而非拼接重试：\(error)")
    }
}

func testModelRelayHTTPServerRuntime() async {
    let vault = ModelRelayLocalKeyVault(iterations: 1)
    let local = try! vault.create(name: "runtime", viewingPassword: "password-123")
    let upstreamKey = ModelRelayUpstreamKeyReference(name: "runtime-upstream")
    let provider = ModelRelayProvider(
        name: "runtime-provider",
        baseURL: "https://runtime.example/v1",
        keys: [upstreamKey],
        models: [ModelRelayModelRoute(upstreamModelID: "upstream-runtime", alias: "runtime-model")]
    )
    let configuration = ModelRelayConfiguration(
        providers: [provider],
        localKeys: [local.record]
    )
    let keyStore = MemoryModelRelayKeyStore([upstreamKey.id: "upstream-secret"])
    let router = ModelRelayRouter(configuration: configuration, keyStore: keyStore, vault: vault)
    let upstream = ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    ModelRelayURLProtocol.reset { request in
        let object = try? JSONSerialization.jsonObject(
            with: modelRelayURLRequestBody(request)
        ) as? [String: Any]
        if object?["stream"] as? Bool == true {
            return ModelRelayStubResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data("data: runtime\n\ndata: [DONE]\n\n".utf8)]
            )
        }
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"model\":\"upstream-runtime\",\"ok\":true}".utf8)]
        )
    }
    let server = ModelRelayHTTPServer(router: router, upstream: upstream)
    let port: UInt16
    do {
        port = try await startModelRelayTestServerOnAvailablePort(server)
    } catch {
        expect(false, "运行态中转服务应能绑定 loopback：\(error)")
        return
    }
    defer { server.stop() }

    do {
        let (_, response) = try await modelRelayLocalRequest(port: port, path: "/v1/models")
        expect(response.statusCode == 401, "运行态 /v1/models 拒绝未鉴权请求")

        let (modelsData, modelsResponse) = try await modelRelayLocalRequest(
            port: port,
            path: "/v1/models",
            token: local.secret
        )
        let modelsText = String(data: modelsData, encoding: .utf8) ?? ""
        expect(modelsResponse.statusCode == 200, "运行态 /v1/models 鉴权后成功")
        expect(modelsText.contains("runtime-model"), "运行态 /v1/models 返回本地别名")

        for path in ["/v1/chat/completions", "/v1/responses"] {
            let (data, response) = try await modelRelayLocalRequest(
                port: port,
                path: path,
                method: "POST",
                token: local.secret,
                object: ["model": "runtime-model", "input": "ping"]
            )
            expect(response.statusCode == 200, "运行态 \(path) 普通响应成功")
            expect(
                String(data: data, encoding: .utf8)?.contains("\"ok\":true") == true,
                "运行态 \(path) 透传上游正文"
            )
        }

        let (streamData, streamResponse) = try await modelRelayLocalRequest(
            port: port,
            path: "/v1/responses",
            method: "POST",
            token: local.secret,
            object: ["model": "runtime-model", "input": "ping", "stream": true]
        )
        expect(streamResponse.statusCode == 200, "运行态 SSE 响应成功")
        expect(
            String(data: streamData, encoding: .utf8)?.contains("data: runtime") == true,
            "运行态 SSE 内容完整到达客户端"
        )
    } catch {
        expect(false, "运行态 HTTP E2E 不应失败：\(error)")
    }

    let conflictingServer = ModelRelayHTTPServer(router: router, upstream: upstream)
    do {
        try await startModelRelayTestServer(conflictingServer, port: port)
        expect(false, "端口占用时第二个 listener 不应启动")
        conflictingServer.stop()
    } catch {
        expect(true, "端口占用返回明确失败")
    }

    ModelRelayBlockingURLProtocol.reset()
    let blockingUpstream = ModelRelayUpstreamClient(
        sessionConfiguration: modelRelayBlockingSessionConfiguration()
    )
    let disconnectServer = ModelRelayHTTPServer(router: router, upstream: blockingUpstream)
    do {
        let disconnectPort = try await startModelRelayTestServerOnAvailablePort(disconnectServer)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(disconnectPort)/v1/responses")!
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "runtime-model",
            "input": "wait",
            "stream": true
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(local.secret)", forHTTPHeaderField: "Authorization")
        let localSession = URLSession(configuration: .ephemeral)
        let task = localSession.dataTask(with: request)
        task.resume()
        let upstreamStarted = ModelRelayBlockingURLProtocol.waitUntilStarted(timeout: 2)
        expect(upstreamStarted, "客户端断开测试已建立上游流")
        task.cancel()
        expect(
            ModelRelayBlockingURLProtocol.waitUntilStopped(timeout: 3),
            "本地客户端断开会取消上游任务"
        )
        localSession.invalidateAndCancel()
        disconnectServer.stop()
    } catch {
        disconnectServer.stop()
        expect(false, "客户端断开运行态测试不应失败：\(error)")
    }
}

func testModelRelayPortRollback() async {
    let keyStore = MemoryModelRelayKeyStore()
    let vault = ModelRelayLocalKeyVault(iterations: 1)
    let upstream = ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    var service: ModelRelayService?
    var originalPort: UInt16 = 0
    for _ in 0..<10 {
        let candidate = UInt16(Int.random(in: 31_000...59_000))
        let candidateService = ModelRelayService(
            configStore: MemoryModelRelayConfigStore(ModelRelayConfiguration(port: candidate)),
            upstreamKeyStore: keyStore,
            localKeyVault: vault,
            upstreamClient: upstream
        )
        do {
            try candidateService.start()
            for _ in 0..<50 {
                if candidateService.runState == .running(port: candidate) { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if candidateService.runState == .running(port: candidate) {
                service = candidateService
                originalPort = candidate
                break
            }
            candidateService.stop()
        } catch {
            candidateService.stop()
        }
    }
    guard let service else {
        expect(false, "端口回滚测试应能启动初始 listener")
        return
    }
    defer { service.stop() }

    let blocker = ModelRelayHTTPServer(router: service.router, upstream: upstream)
    let occupiedPort: UInt16
    do {
        occupiedPort = try await startModelRelayTestServerOnAvailablePort(blocker)
    } catch {
        expect(false, "端口回滚测试应能建立占用 listener")
        return
    }
    defer { blocker.stop() }
    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
        service.updatePort(Int(occupiedPort)) {
            continuation.resume(returning: $0)
        }
    }
    if case .success = result {
        expect(false, "切换到占用端口应失败")
    } else {
        expect(true, "切换到占用端口返回失败")
    }
    expect(service.snapshot().port == originalPort, "端口冲突时不持久化新端口")
    expect(service.runState == .running(port: originalPort), "端口冲突后恢复原 listener")

    let startupKey = ModelRelayUpstreamKeyReference(name: "startup")
    let startupProvider = ModelRelayProvider(
        name: "startup-provider",
        baseURL: "https://startup.example/v1",
        keys: [startupKey]
    )
    let failedStartupService = ModelRelayService(
        configStore: MemoryModelRelayConfigStore(
            ModelRelayConfiguration(port: occupiedPort, providers: [startupProvider])
        ),
        upstreamKeyStore: MemoryModelRelayKeyStore([startupKey.id: "startup-secret"]),
        localKeyVault: vault,
        upstreamClient: upstream
    )
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"should-not-load\"}]}".utf8)]
        )
    }
    do {
        try failedStartupService.start()
        for _ in 0..<50 {
            if case .failed = failedStartupService.runState { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .failed = failedStartupService.runState {
            expect(true, "listener 未 ready 时服务状态明确失败")
        } else {
            expect(false, "占用端口启动应进入失败状态")
        }
        expect(
            ModelRelayURLProtocol.requests.isEmpty,
            "listener 未 ready 时不启动后台目录刷新"
        )
    } catch {
        expect(true, "占用端口同步失败同样不得启动后台刷新")
    }
    failedStartupService.stop()
}

func testModelRelayManualAndLegacyAKContract() {
    let manual = UserManual.pages.map { $0.title + "\n" + $0.body }.joined(separator: "\n")
    expect(manual.contains("顶层「模型」"), "说明书标明独立顶层模型中转站")
    expect(manual.contains("「状态」「端口」「厂家」「密钥」"), "说明书标明四项菜单文案")
    expect(manual.contains("打开当日调用明细日志文件"), "说明书标明状态窗打开日志文件")
    expect(manual.contains("不统计 token"), "说明书标明按调用次数而非 token")
    expect(manual.contains("直接打开与新增相同的编辑弹窗"), "说明书写明厂家点击直达编辑弹窗")
    expect(manual.contains("不提供人工别名"), "说明书明确无模型别名配置")
    expect(!manual.contains("模型别名"), "说明书不再出现模型别名入口")
    expect(manual.contains("AK → AK-模型"), "说明书保留既有 AK 模型入口")
    expect(ExtendedSettingsStore.topLevelFolderTitle == "AK", "既有 AK 顶层夹名称保持不变")
    expect(ExtendedSettingsStore.modelMenuTitle == "AK-模型", "既有 AK-模型名称保持不变")
}

func testModelRelayCallMetricsStore() {
    do {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tocode-metrics-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = ModelRelayCallMetricsStore(home: home.path)
        let providerA = UUID()
        let providerB = UUID()
        let now = Date()

        store.record(ModelRelayCallEvent(
            timestamp: now,
            route: "chat/completions",
            providerID: providerA,
            providerName: "A",
            publishedModel: "model-a",
            upstreamModel: "upstream-a",
            status: 200,
            durationMs: 12,
            ok: true
        ))
        store.record(ModelRelayCallEvent(
            timestamp: now.addingTimeInterval(1),
            route: "responses",
            providerID: providerA,
            providerName: "A",
            publishedModel: "model-a",
            upstreamModel: "upstream-a",
            status: 200,
            durationMs: 8,
            ok: true
        ))
        store.record(ModelRelayCallEvent(
            timestamp: now.addingTimeInterval(2),
            route: "chat/completions",
            providerID: providerB,
            providerName: "B",
            publishedModel: "model-b",
            upstreamModel: "upstream-b",
            status: 502,
            durationMs: 3,
            ok: false
        ))

        expect(store.lastUsedProviderID == providerB, "lastUsed 记录最近一次厂家")
        let sixHour = store.series(providerID: providerA, range: .sixHours, now: now)
        expect(sixHour.count == 36, "近六小时固定 36 个十分钟桶")
        expect(sixHour.map(\.count).reduce(0, +) == 2, "同厂家两次入站各记一次")
        let week = store.series(providerID: providerA, range: .week, now: now)
        expect(week.count == 7 && week.last?.count == 2, "近一周按自然日聚合当日两次")
        let month = store.series(providerID: providerA, range: .month, now: now)
        expect(month.count == 5 && month.last?.count == 2, "近一月按自然周聚合")

        let logURL = try store.ensureTodayLogFile()
        let attrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        expect(mode == 0o600, "调用日志权限为 0600")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        expect(content.contains("route=chat/completions"), "日志含 route 元数据")
        expect(content.contains("providerName=A"), "日志含厂家名")
        expect(!content.contains("Authorization"), "日志不含 Authorization")
        expect(!content.contains("Bearer"), "日志不含 Bearer")
        expect(!content.lowercased().contains("token"), "日志不统计 token")
        expect(!content.contains("messages"), "日志不含请求正文字段")

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
        store.record(ModelRelayCallEvent(
            timestamp: tomorrow,
            route: "chat/completions",
            providerID: providerA,
            providerName: "A",
            publishedModel: "model-a",
            upstreamModel: "upstream-a",
            status: 200,
            durationMs: 1,
            ok: true
        ))
        let rolled = try String(contentsOf: logURL, encoding: .utf8)
        expect(rolled.contains("durationMs=1"), "换日后写入新明细")
        expect(!rolled.contains("durationMs=12"), "换日覆盖旧明细")
    } catch {
        expect(false, "调用观测存储测试不应抛错：\(error)")
    }
}

func testModelRelayProxyRecordsOneCallEvenOnUpstreamRetryExhaustion() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ModelRelayURLProtocol.self]
    let client = ModelRelayUpstreamClient(sessionConfiguration: config)
    let metrics = MemoryModelRelayCallMetricsStore()
    let providerID = UUID()
    let router = ModelRelayRouter(
        configuration: ModelRelayConfiguration(),
        keyStore: MemoryModelRelayKeyStore(),
        vault: ModelRelayLocalKeyVault()
    )
    let route = ModelRelayResolvedRoute(alias: "local-model", candidates: [
        ModelRelayUpstreamCandidate(
            providerID: providerID,
            providerName: "厂家",
            keyID: UUID(),
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "bad-key"
        )
    ])
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(status: 500, chunks: [Data("bad".utf8)])
    }
    do {
        let output = try await runModelRelayProxy(
            client: client,
            request: modelRelayRequest(),
            route: route,
            router: router,
            metrics: metrics
        )
        expect(String(data: output, encoding: .utf8)?.contains("HTTP/1.1 502") == true, "上游失败返回 502")
        expect(metrics.events.count == 1, "入站一次只记一次，即使上游失败")
        expect(metrics.events.first?.providerID == providerID, "调用记录绑定厂家")
        expect(metrics.events.first?.ok == false, "失败调用 ok=false")
        expect(metrics.lastUsedProviderID == providerID, "失败调用仍更新 lastUsed")
    } catch {
        expect(false, "应返回明确失败响应：\(error)")
    }
}
