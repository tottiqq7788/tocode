import Foundation
import AppKit

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
        ModelRelayPrompts.providerChoices(existingBaseURL: presets[1].baseURL) == presets,
        "编辑预设厂商时仍选中既有预设"
    )
    let legacyURL = "http://127.0.0.1:11434/v1"
    let legacyChoices = ModelRelayPrompts.providerChoices(existingBaseURL: legacyURL)
    expect(
        legacyChoices.count == presets.count + 1
            && legacyChoices.last?.baseURL == legacyURL,
        "旧自定义厂商编辑时保留原地址"
    )

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
    let secondKey = ModelRelayUpstreamKeyReference(name: "second")
    let provider = ModelRelayProvider(
        name: "provider",
        baseURL: "https://example.com/v1",
        keys: [firstKey, secondKey],
        models: [ModelRelayModelRoute(upstreamModelID: "upstream-a", alias: "local-a")]
    )
    let configuration = ModelRelayConfiguration(
        providers: [provider],
        localKeys: [local.record]
    )
    let keyStore = MemoryModelRelayKeyStore([
        firstKey.id: "upstream-key-1",
        secondKey.id: "upstream-key-2"
    ])
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
    expect(first.candidates.first?.keyID == firstKey.id, "健康 Key 轮询第一次选择首 Key")
    expect(second.candidates.first?.keyID == secondKey.id, "健康 Key 轮询第二次选择次 Key")

    router.recordFailure(keyID: firstKey.id, statusCode: 401)
    let afterAuthenticationFailure = try! router.resolve(alias: "local-a")
    expect(
        afterAuthenticationFailure.candidates.allSatisfy { $0.keyID != firstKey.id },
        "401 后 Key 保持不可用直至手动重置"
    )
    router.resetHealth(keyIDs: [firstKey.id])
    expect(try! router.resolve(alias: "local-a").candidates.contains { $0.keyID == firstKey.id }, "手动刷新重置 401 健康状态")

    router.recordFailure(keyID: secondKey.id, statusCode: 429)
    expect(
        !(try! router.resolve(alias: "local-a").candidates.contains { $0.keyID == secondKey.id }),
        "429 Key 在冷却期内不可用"
    )
    clock.now = clock.now.addingTimeInterval(61)
    expect(
        try! router.resolve(alias: "local-a").candidates.contains { $0.keyID == secondKey.id },
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
                ModelRelayModelRoute(upstreamModelID: "a", alias: "shared"),
                ModelRelayModelRoute(upstreamModelID: "b", alias: "other")
            ]
        )
    ])
    let service = ModelRelayService(
        configStore: MemoryModelRelayConfigStore(initial),
        upstreamKeyStore: MemoryModelRelayKeyStore(),
        localKeyVault: vault,
        upstreamClient: ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    )
    do {
        _ = try service.addProvider(name: "ONE", baseURL: "https://two.example/v1")
        expect(false, "厂商名称应忽略大小写保持唯一")
    } catch {
        expect(error as? ModelRelayError == .duplicateProviderName, "重复厂商名返回明确错误")
    }
    do {
        try service.updateAlias(
            routeID: initial.providers[0].models[1].id,
            alias: "SHARED"
        )
        expect(false, "模型别名应忽略大小写保持全局唯一")
    } catch {
        expect(error as? ModelRelayError == .duplicateAlias, "重复模型别名返回明确错误")
    }
    _ = try! service.createLocalKey(name: "client-a", password: "password-123")
    do {
        _ = try service.createLocalKey(name: "CLIENT-A", password: "password-456")
        expect(false, "本地 Key 名称应保持唯一")
    } catch {
        expect(error as? ModelRelayError == .duplicateKeyName, "重复本地 Key 名返回明确错误")
    }
}

func testModelRelayValidatedKeyControlPlane() async {
    let firstProvider = ModelRelayProvider(
        name: "first",
        baseURL: "https://first.example/v1",
        models: [ModelRelayModelRoute(upstreamModelID: "shared", alias: "shared")]
    )
    let secondProvider = ModelRelayProvider(
        name: "second",
        baseURL: "https://second.example/v1"
    )
    let configStore = MemoryModelRelayConfigStore(
        ModelRelayConfiguration(providers: [firstProvider, secondProvider])
    )
    let keyStore = MemoryModelRelayKeyStore()
    let client = ModelRelayUpstreamClient(sessionConfiguration: modelRelayTestSessionConfiguration())
    let service = ModelRelayService(
        configStore: configStore,
        upstreamKeyStore: keyStore,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    ModelRelayURLProtocol.reset { request in
        expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-secret",
            "新增上游 Key 在保存前使用输入 secret 校验目录"
        )
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"shared\"}]}".utf8)]
        )
    }
    let addition: Result<ModelRelayUpstreamKeyReference, Error> = await withCheckedContinuation { continuation in
        service.addUpstreamKey(
            providerID: secondProvider.id,
            name: "primary",
            secret: "valid-secret"
        ) {
            continuation.resume(returning: $0)
        }
    }
    switch addition {
    case .failure(let error):
        expect(false, "有效上游 Key 应新增成功：\(error)")
    case .success(let reference):
        let savedProvider = service.snapshot().providers.first { $0.id == secondProvider.id }
        expect(savedProvider?.keys == [reference], "校验成功后才保存上游 Key 元数据")
        expect(savedProvider?.models.first?.alias == "second/shared", "冲突模型默认使用 厂商/model-id 别名")
        expect((try? keyStore.load(id: reference.id)) == "valid-secret", "校验成功后 secret 写入 Keychain 抽象")

        ModelRelayURLProtocol.reset { _ in
            ModelRelayStubResponse(status: 401, chunks: [Data("{\"error\":\"unauthorized\"}".utf8)])
        }
        let replacement: Result<Void, Error> = await withCheckedContinuation { continuation in
            service.replaceUpstreamKey(
                providerID: secondProvider.id,
                keyID: reference.id,
                name: "primary",
                secret: "invalid-secret"
            ) {
                continuation.resume(returning: $0)
            }
        }
        if case .success = replacement {
            expect(false, "校验失败的替换 Key 不应保存")
        } else {
            expect(true, "校验失败的替换 Key 被拒绝")
        }
        expect(
            (try? keyStore.load(id: reference.id)) == "valid-secret",
            "替换校验失败时保留原上游 secret"
        )
    }

    let healthyReference = ModelRelayUpstreamKeyReference(name: "healthy")
    let rejectedReference = ModelRelayUpstreamKeyReference(name: "rejected")
    let refreshProvider = ModelRelayProvider(
        name: "refresh-all",
        baseURL: "https://refresh.example/v1",
        keys: [healthyReference, rejectedReference]
    )
    let refreshKeys = MemoryModelRelayKeyStore([
        healthyReference.id: "healthy-secret",
        rejectedReference.id: "rejected-secret"
    ])
    let refreshService = ModelRelayService(
        configStore: MemoryModelRelayConfigStore(
            ModelRelayConfiguration(providers: [refreshProvider])
        ),
        upstreamKeyStore: refreshKeys,
        localKeyVault: ModelRelayLocalKeyVault(iterations: 1),
        upstreamClient: client
    )
    ModelRelayURLProtocol.reset { request in
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer rejected-secret" {
            return ModelRelayStubResponse(status: 401)
        }
        return ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"refresh-model\"}]}".utf8)]
        )
    }
    let refreshResult: Result<[ModelRelayModelRoute], Error> = await withCheckedContinuation { continuation in
        refreshService.fetchModels(providerID: refreshProvider.id) {
            continuation.resume(returning: $0)
        }
    }
    if case .failure(let error) = refreshResult {
        expect(false, "至少一个健康 Key 时刷新应成功：\(error)")
    }
    expect(ModelRelayURLProtocol.requests.count == 2, "一次刷新会校验厂商下全部上游 Key")
    do {
        let route = try refreshService.router.resolve(alias: "refresh-model")
        expect(
            route.candidates.map(\.keyID) == [healthyReference.id],
            "刷新时 401 Key 被永久隔离且不进入健康轮询"
        )
    } catch {
        expect(false, "刷新后的健康模型应可路由：\(error)")
    }

    refreshService.router.recordFailure(keyID: healthyReference.id, statusCode: 401)
    ModelRelayURLProtocol.reset { _ in
        ModelRelayStubResponse(
            status: 200,
            chunks: [Data("{\"data\":[{\"id\":\"refresh-model\"}]}".utf8)]
        )
    }
    let automaticResult: Result<[ModelRelayModelRoute], Error> = await withCheckedContinuation { continuation in
        refreshService.fetchModels(
            providerID: refreshProvider.id,
            resetAuthenticationFailures: false
        ) {
            continuation.resume(returning: $0)
        }
    }
    if case .success = automaticResult {
        expect(false, "自动刷新不得恢复 401/403 Key")
    } else {
        expect(true, "自动刷新保留鉴权失败状态")
    }
    expect(ModelRelayURLProtocol.requests.isEmpty, "自动刷新跳过全部鉴权失败 Key")

    let manualResult: Result<[ModelRelayModelRoute], Error> = await withCheckedContinuation { continuation in
        refreshService.fetchModels(providerID: refreshProvider.id) {
            continuation.resume(returning: $0)
        }
    }
    if case .failure(let error) = manualResult {
        expect(false, "手动刷新应重新校验鉴权失败 Key：\(error)")
    }
    expect(ModelRelayURLProtocol.requests.count == 2, "手动刷新重新校验厂商全部 Key")
    do {
        let route = try refreshService.router.resolve(alias: "refresh-model")
        expect(route.candidates.count == 2, "手动刷新成功后恢复两个 Key 的健康轮询")
    } catch {
        expect(false, "手动刷新恢复后模型应可路由：\(error)")
    }

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
            keyID: firstID,
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "bad-key"
        ),
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
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
        expect(text.contains("HTTP/1.1 200"), "响应前 5xx 故障转移到下一 Key")
        expect(text.contains("{\"ok\":true}"), "普通 JSON 响应透传")
        expect(ModelRelayURLProtocol.requests.count == 2, "响应前故障恰好尝试两个 Key")
    } catch {
        expect(false, "普通代理与故障转移应成功：\(error)")
    }

    for status in [401, 403, 429] {
        let statusRoute = ModelRelayResolvedRoute(alias: "local-model", candidates: [
            ModelRelayUpstreamCandidate(
                providerID: UUID(),
                keyID: UUID(),
                baseURL: "https://proxy.example/v1",
                upstreamModelID: "upstream-model",
                secret: "status-\(status)"
            ),
            ModelRelayUpstreamCandidate(
                providerID: UUID(),
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
                String(data: output, encoding: .utf8)?.contains("HTTP/1.1 200") == true
                    && ModelRelayURLProtocol.requests.count == 2,
                "响应前 HTTP \(status) 会故障转移"
            )
        } catch {
            expect(false, "HTTP \(status) 故障转移应成功：\(error)")
        }
    }

    let networkRoute = ModelRelayResolvedRoute(alias: "local-model", candidates: [
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
            keyID: UUID(),
            baseURL: "https://proxy.example/v1",
            upstreamModelID: "upstream-model",
            secret: "network-bad"
        ),
        ModelRelayUpstreamCandidate(
            providerID: UUID(),
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
            String(data: output, encoding: .utf8)?.contains("HTTP/1.1 200") == true
                && ModelRelayURLProtocol.requests.count == 2,
            "响应前连接失败会故障转移"
        )
    } catch {
        expect(false, "连接失败故障转移应成功：\(error)")
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
    expect(manual.contains("AK → AK-模型"), "说明书保留既有 AK 模型入口")
    expect(ExtendedSettingsStore.topLevelFolderTitle == "AK", "既有 AK 顶层夹名称保持不变")
    expect(ExtendedSettingsStore.modelMenuTitle == "AK-模型", "既有 AK-模型名称保持不变")
}
