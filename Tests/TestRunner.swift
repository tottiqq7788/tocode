import Foundation
import AppKit
import CoreGraphics
import SQLite3

var failures = 0

func expect(_ cond: Bool, _ msg: String) {
    if cond {
        print("PASS: \(msg)")
    } else {
        print("FAIL: \(msg)")
        failures += 1
    }
}

func testFileSystemService() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("tocode-test-\(UUID().uuidString)").path
    try! fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    try! fm.createDirectory(atPath: (tmp as NSString).appendingPathComponent("z-folder"), withIntermediateDirectories: false)
    try! fm.createDirectory(atPath: (tmp as NSString).appendingPathComponent("folder-a"), withIntermediateDirectories: false)
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent("b-file.txt"), contents: Data())
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent("a-file.txt"), contents: Data())
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent(".hidden"), contents: Data())

    let fs = FileSystemService()
    let entries = fs.entries(in: tmp)

    expect(entries.count == 5, "条目数 == 5（含隐藏文件）")

    let dirs = entries.filter { $0.kind == .directory }
    expect(dirs.count == 2, "2 个文件夹")
    expect(dirs.map { $0.name } == ["folder-a", "z-folder"], "文件夹按名称升序")

    let files = entries.filter { $0.kind == .file }
    expect(files.count == 3, "3 个文件（含 .hidden）")

    let aIdx = files.firstIndex { $0.name == "a-file.txt" }
    let bIdx = files.firstIndex { $0.name == "b-file.txt" }
    expect(aIdx != nil && bIdx != nil, "a-file.txt / b-file.txt 都存在")
    if let a = aIdx, let b = bIdx { expect(a < b, "a-file.txt 排在 b-file.txt 前") }

    let hidden = entries.first { $0.name == ".hidden" }
    expect(hidden?.isHidden == true, ".hidden 的 isHidden 标记为 true")
    expect(hidden?.kind == .file, ".hidden 类型为文件")

    expect(fs.isExistingDirectory(tmp), "isExistingDirectory(目录) == true")
    expect(!fs.isExistingDirectory((tmp as NSString).appendingPathComponent("b-file.txt")), "isExistingDirectory(文件) == false")
    expect(!fs.isExistingDirectory((tmp as NSString).appendingPathComponent("nope")), "isExistingDirectory(不存在) == false")

    let empty = (tmp as NSString).appendingPathComponent("empty-dir")
    try! fm.createDirectory(atPath: empty, withIntermediateDirectories: false)
    expect(fs.entries(in: empty).isEmpty, "空目录返回空数组")

    let visibleOnly = fs.entries(in: tmp, includeHidden: false)
    expect(visibleOnly.contains { $0.name == ".hidden" } == false, "includeHidden=false 过滤点号文件")
    expect(visibleOnly.count == 5, "过滤点号后剩余可见项（含 empty-dir）")

    let flagged = (tmp as NSString).appendingPathComponent("flagged.txt")
    fm.createFile(atPath: flagged, contents: Data())
    var values = URLResourceValues()
    values.isHidden = true
    var flaggedURL = URL(fileURLWithPath: flagged)
    try! flaggedURL.setResourceValues(values)
    expect(fs.isHiddenEntry(name: "flagged.txt", path: flagged), "hidden 属性条目判定为隐藏")
    let hiddenOff = fs.entries(in: tmp, includeHidden: false)
    expect(hiddenOff.contains { $0.name == "flagged.txt" } == false, "includeHidden=false 过滤 hidden 属性文件")
    let hiddenOn = fs.entries(in: tmp, includeHidden: true)
    expect(hiddenOn.contains { $0.name == "flagged.txt" && $0.isHidden }, "includeHidden=true 保留 hidden 属性文件")
}

func testRootPathStore() {
    let suite = "tocode-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let fm = FileManager.default
    let store = RootPathStore(defaults: defaults)

    // 初始为 nil
    expect(store.load() == nil, "RootPathStore 初始为 nil")

    // 保存后读取一致
    store.save("/tmp/some/path")
    expect(store.load() == "/tmp/some/path", "RootPathStore 保存后读取一致")

    // 已保存且存在 → 返回保存值
    let savedDir = "/tmp/tocode-saved-\(UUID().uuidString)"
    try! fm.createDirectory(atPath: savedDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: savedDir) }
    store.save(savedDir)
    expect(store.resolveRoot(isDirectory: { fm.fileExists(atPath: $0, isDirectory: nil) }) == savedDir,
           "resolveRoot 已保存且存在时返回保存值")

    // 已保存但不存在 → 回退默认目录
    store.save("/tmp/tocode-nonexistent-\(UUID().uuidString)")
    expect(store.resolveRoot(isDirectory: { $0 == RootPathStore.defaultRoot }) == RootPathStore.defaultRoot,
           "resolveRoot 保存值不存在时回退默认目录")

    // 未保存 → 回退默认目录
    defaults.removePersistentDomain(forName: suite)
    expect(store.resolveRoot(isDirectory: { $0 == RootPathStore.defaultRoot }) == RootPathStore.defaultRoot,
           "resolveRoot 未保存时回退默认目录")

    // reset → 默认目录
    store.save("/tmp/other/path")
    store.reset()
    expect(store.load() == RootPathStore.defaultRoot, "reset 后根目录为默认目录")
    expect(RootPathStore.defaultRoot == "/Users/admin/Documents", "默认目录为 /Users/admin/Documents")
}

func testClipboardService() {
    let name = NSPasteboard.Name("tocode-test-\(UUID().uuidString)")
    let pb = NSPasteboard(name: name)
    let clip = ClipboardService(pasteboard: pb)
    clip.copy("/Users/test/hello.txt")
    expect(clip.read() == "/Users/test/hello.txt", "ClipboardService 写入后读取一致")

    clip.copyPath("/Users/test/folder")
    expect(clip.read() == "「/Users/test/folder」", "ClipboardService.copyPath 用「」包裹路径")
}

func testCodexProjectService() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("codex-root-\(UUID().uuidString)").path
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }

    func stateJSON(selectedType: String?, projectID: String?, projects: String) -> String {
        var selected = "null"
        if let selectedType = selectedType, let projectID = projectID {
            selected = "{\"type\":\"\(selectedType)\",\"projectId\":\"\(projectID)\"}"
        }
        return "{\"selected-project\":\(selected),\"local-projects\":\(projects)}"
    }

    let goodProjects = """
    {"p1":{"id":"p1","name":"tocode","rootPaths":["\(root)"]}}
    """
    let fs = FileSystemService()

    // 成功解析项目名与根目录
    let success = CodexProjectService(
        home: "/tmp",
        fs: fs,
        reader: { _ in Data(stateJSON(selectedType: "local", projectID: "p1", projects: goodProjects).utf8) }
    )
    let project = success.resolveProject()
    expect(project?.name == "tocode", "Codex 成功解析项目名")
    expect(project?.rootPath == root, "Codex 成功解析根目录并标准化")

    // 文件缺失
    let missing = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in nil })
    expect(missing.resolveProject() == nil, "Codex 文件缺失返回 nil")

    // JSON 损坏
    let corrupt = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in Data("not json".utf8) })
    expect(corrupt.resolveProject() == nil, "Codex JSON 损坏返回 nil")

    // 无 selected-project
    let noSelected = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in
        Data("{\"local-projects\":\(goodProjects)}".utf8)
    })
    expect(noSelected.resolveProject() == nil, "Codex 无 selected-project 返回 nil")

    // type != local
    let remote = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in
        Data(stateJSON(selectedType: "cloud", projectID: "p1", projects: goodProjects).utf8)
    })
    expect(remote.resolveProject() == nil, "Codex type != local 返回 nil")

    // 项目 ID 未注册
    let unregistered = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in
        Data(stateJSON(selectedType: "local", projectID: "p2", projects: goodProjects).utf8)
    })
    expect(unregistered.resolveProject() == nil, "Codex 项目 ID 未注册返回 nil")

    // rootPaths 为空
    let emptyRoot = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in
        Data(stateJSON(selectedType: "local", projectID: "p1", projects: "{\"p1\":{\"id\":\"p1\",\"name\":\"x\",\"rootPaths\":[]}}").utf8)
    })
    expect(emptyRoot.resolveProject() == nil, "Codex rootPaths 为空返回 nil")

    // 根目录不存在
    let noDir = CodexProjectService(home: "/tmp", fs: fs, reader: { _ in
        Data(stateJSON(selectedType: "local", projectID: "p1", projects: "{\"p1\":{\"id\":\"p1\",\"name\":\"x\",\"rootPaths\":[\"/tmp/definitely-missing-\(UUID().uuidString)]}}").utf8)
    })
    expect(noDir.resolveProject() == nil, "Codex 根目录不存在返回 nil")
}

func testCodexSyncSettingsStore() {
    let suite = "tocode-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = CodexSyncSettingsStore(defaults: defaults)
    expect(store.syncEnabled == false, "CodexSyncSettingsStore 默认 false")
    store.syncEnabled = true
    expect(store.syncEnabled == true, "CodexSyncSettingsStore 写入后读取 true")
    store.syncEnabled = false
    expect(store.syncEnabled == false, "CodexSyncSettingsStore 关闭后恢复 false")
}

private final class MockCodexModelURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw NSError(domain: "MockCodexModelURLProtocol", code: 1)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct CodexModelFixture {
    let root: URL
    let databasePath: String
    let configPath: String
}

private func makeCodexModelFixture() -> CodexModelFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-model-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databasePath = root.appendingPathComponent("cc-switch.db").path
    let configPath = root.appendingPathComponent("config.toml").path
    let template = """
    model_provider = "custom"
    model = "v_model/gpt-5.5"
    model_reasoning_effort = "high"

    [model_providers.custom]
    base_url = "https://ai-router.anker-in.com/v1"
    experimental_bearer_token = "provider-managed"
    """
    let settings: [String: Any] = [
        "auth": ["OPENAI_API_KEY": "unit-test-key"],
        "config": template,
        "untouched": ["enabled": true]
    ]
    let settingsData = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    let settingsJSON = String(data: settingsData, encoding: .utf8)!

    var database: OpaquePointer?
    expect(sqlite3_open(databasePath, &database) == SQLITE_OK, "模型切换夹具创建 SQLite")
    let createSQL = """
    CREATE TABLE providers (
      id TEXT NOT NULL,
      app_type TEXT NOT NULL,
      name TEXT NOT NULL,
      settings_config TEXT NOT NULL,
      is_current BOOLEAN NOT NULL DEFAULT 0,
      PRIMARY KEY (id, app_type)
    );
    """
    expect(sqlite3_exec(database, createSQL, nil, nil, nil) == SQLITE_OK, "模型切换夹具创建 providers")
    var statement: OpaquePointer?
    let insertSQL = "INSERT INTO providers(id, app_type, name, settings_config, is_current) VALUES(?, 'codex', 'Anker AI Router', ?, 1)"
    expect(sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK, "模型切换夹具准备 Provider")
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, "anker", -1, transient)
    sqlite3_bind_text(statement, 2, settingsJSON, -1, transient)
    expect(sqlite3_step(statement) == SQLITE_DONE, "模型切换夹具写入 Provider")
    sqlite3_finalize(statement)
    sqlite3_close(database)

    let live = """
    model_provider = "custom"
    model = "v_model/gpt-5.5"
    model_reasoning_effort = "high"

    [desktop]
    conversationDetailMode = "STEPS_PROSE"
    """
    try! live.write(toFile: configPath, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: configPath
    )
    return CodexModelFixture(root: root, databasePath: databasePath, configPath: configPath)
}

private func readProviderSettings(at path: String) -> [String: Any] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        return [:]
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT settings_config FROM providers WHERE id='anker' AND app_type='codex'",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        return [:]
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let bytes = sqlite3_column_text(statement, 0),
          let data = String(cString: bytes).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

func testCodexModelTOMLAndCatalog() {
    let source = """
    # model = "commented"
    model_provider = "custom"
    model = "v_model/gpt-5.5" # current

    [desktop]
    model = "nested"
    """
    expect(
        (try? CodexTOMLModel.read(from: source, location: "test")) == "v_model/gpt-5.5",
        "模型解析只读取唯一顶层 model"
    )
    let replaced = try! CodexTOMLModel.replacing(
        in: source,
        with: "v_model/gpt-6-astra",
        location: "test"
    )
    expect(replaced.contains("model = \"v_model/gpt-6-astra\" # current"), "模型替换保留原行格式与注释")
    expect(replaced.contains("model = \"nested\""), "模型替换不改表内同名键")
    expect(
        (try? CodexTOMLModel.read(from: "model = \"a\"\nmodel = \"b\"\n", location: "test")) == nil,
        "重复顶层 model 被拒绝"
    )
    expect(
        (try? CodexTOMLModel.read(from: "[desktop]\nmodel = \"nested\"\n", location: "test")) == nil,
        "只有表内 model 时被拒绝"
    )

    let sol = CodexModelCatalog.descriptor(for: "v_model/gpt-5.5")
    expect(sol.displayName == "GPT-5.6 Sol", "Sol 使用友好名称")
    expect(sol.compatibility == .verified, "Sol 标记为已验证")
    let appsKimi = CodexModelCatalog.descriptor(for: "apps/v_model/kimi")
    expect(appsKimi.displayName == "Kimi · Apps", "重名模型显示来源")
    if case .unsupported = CodexModelCatalog.descriptor(for: "apps/v_model/glm-image").compatibility {
        expect(true, "图片模型标记为不可选择")
    } else {
        expect(false, "图片模型标记为不可选择")
    }
    if case .unsupported = CodexModelCatalog.descriptor(for: "anthropic/v_model/deepseek-v4-pro").compatibility {
        expect(true, "已知 /responses 不兼容模型被禁用")
    } else {
        expect(false, "已知 /responses 不兼容模型被禁用")
    }
    let deduplicated = CodexModelCatalog.descriptors(for: [
        "apps/v_model/kimi", "apps/v_model/kimi", "v_model/gpt-5.5"
    ])
    expect(deduplicated.count == 2, "实时模型目录按 ID 去重")
}

func testCodexModelSwitchIntegrationAndFaults() {
    let fixture = makeCodexModelFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = CodexModelSwitchService(
        databasePath: fixture.databasePath,
        liveConfigPath: fixture.configPath
    )
    let initial = try! service.currentState()
    expect(initial.liveModelID == "v_model/gpt-5.5", "模型状态读取实时配置")
    expect(initial.providerModelID == "v_model/gpt-5.5", "模型状态读取 Provider 模板")
    expect(initial.isConsistent, "初始双配置一致")

    try! service.switchModel(to: "v_model/gpt-6-astra")
    let switched = try! service.currentState()
    expect(switched.liveModelID == "v_model/gpt-6-astra", "切换写入 Codex 实时配置")
    expect(switched.providerModelID == "v_model/gpt-6-astra", "切换写入 CC Switch Provider 模板")
    let live = try! String(contentsOfFile: fixture.configPath, encoding: .utf8)
    expect(live.contains("model_reasoning_effort = \"high\""), "实时配置非 model 内容保持")
    expect(live.contains("conversationDetailMode = \"STEPS_PROSE\""), "实时配置表内容保持")
    let liveAttributes = try! FileManager.default.attributesOfItem(atPath: fixture.configPath)
    expect(
        (liveAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
        "原子替换保持 Codex 配置 0600 权限"
    )
    let settings = readProviderSettings(at: fixture.databasePath)
    let auth = settings["auth"] as? [String: Any]
    expect(auth?["OPENAI_API_KEY"] as? String == "unit-test-key", "Provider 凭据保持不变")
    let untouched = settings["untouched"] as? [String: Any]
    expect(untouched?["enabled"] as? Bool == true, "Provider JSON 其他字段保持不变")

    let failedWriter = CodexModelSwitchService(
        databasePath: fixture.databasePath,
        liveConfigPath: fixture.configPath,
        fileWriter: { _, _ in
            throw NSError(domain: "intentional-write-failure", code: 1)
        }
    )
    expect(
        (try? failedWriter.switchModel(to: "v_model/gpt-5.5")) == nil,
        "实时配置写入失败时切换失败"
    )
    let afterFailure = try! service.currentState()
    expect(afterFailure.liveModelID == "v_model/gpt-6-astra", "写入失败后实时配置保持原值")
    expect(afterFailure.providerModelID == "v_model/gpt-6-astra", "写入失败后数据库事务回滚")

    let validLive = live
    try! "model = \"a\"\nmodel = \"b\"\n".write(
        toFile: fixture.configPath,
        atomically: true,
        encoding: .utf8
    )
    expect((try? service.switchModel(to: "v_model/gpt")) == nil, "歧义实时配置拒绝切换")
    try! validLive.write(toFile: fixture.configPath, atomically: true, encoding: .utf8)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockCodexModelURLProtocol.self]
    let networkService = CodexModelSwitchService(
        databasePath: fixture.databasePath,
        liveConfigPath: fixture.configPath,
        session: URLSession(configuration: configuration)
    )
    var requestedURL: URL?
    var authorization: String?
    MockCodexModelURLProtocol.handler = { request in
        requestedURL = request.url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = Data(#"{"data":[{"id":"v_model/gpt-5.5"},{"id":"apps/v_model/glm-image"},{"id":"v_model/gpt-5.5"}]}"#.utf8)
        return (response, data)
    }
    let loaded = DispatchSemaphore(value: 0)
    var loadedModels: [CodexModelDescriptor] = []
    networkService.fetchModels { result in
        if case .success(let models) = result {
            loadedModels = models
        }
        loaded.signal()
    }
    _ = loaded.wait(timeout: .now() + 2)
    expect(requestedURL?.absoluteString == "https://ai-router.anker-in.com/v1/models", "目录只请求固定 Anker HTTPS 地址")
    expect(authorization == "Bearer unit-test-key", "目录使用当前 Provider 凭据")
    expect(loadedModels.count == 2, "目录响应解析并去重")

    func catalogRequestFails(status: Int, body: String) -> Bool {
        MockCodexModelURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        let semaphore = DispatchSemaphore(value: 0)
        var failed = false
        networkService.fetchModels { result in
            if case .failure = result { failed = true }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return failed
    }
    expect(catalogRequestFails(status: 401, body: ""), "目录 HTTP 401 明确失败")
    expect(catalogRequestFails(status: 500, body: ""), "目录 HTTP 500 明确失败")
    expect(catalogRequestFails(status: 200, body: "not-json"), "目录畸形 JSON 明确失败")
    expect(catalogRequestFails(status: 200, body: #"{"data":[]}"#), "目录空列表明确失败")
    MockCodexModelURLProtocol.handler = nil
}

func testCodexApplicationRestarter() {
    var alive = Set<pid_t>([101, 202])
    var signaled: [pid_t] = []
    var scheduledDelay: TimeInterval?
    var scheduledWork: (() -> Void)?
    var launchCount = 0
    var completionSucceeded = false
    let restarter = CodexApplicationRestarter(
        pidProvider: { Array(alive).sorted() },
        signalSender: { pid in
            signaled.append(pid)
            alive.remove(pid)
            return CodexSignalResult(status: .sent)
        },
        processChecker: { alive.contains($0) },
        scheduler: { delay, work in
            scheduledDelay = delay
            scheduledWork = work
        },
        launcher: { completion in
            launchCount += 1
            completion(.success(()))
        }
    )
    restarter.forceRestart(after: 2) { result in
        if case .success = result { completionSucceeded = true }
    }
    expect(scheduledDelay == 2, "Codex 强制重启固定延迟两秒")
    expect(signaled.isEmpty, "两秒到达前不发送终止信号")
    expect(launchCount == 0, "两秒到达前不启动新 Codex")
    scheduledWork?()
    expect(signaled == [101, 202], "两秒后向全部 Codex PID 发送强杀")
    expect(launchCount == 1, "旧 PID 消失后只启动一个 Codex")
    expect(completionSucceeded, "强制重启成功回调")

    var immediateLaunches = 0
    let notRunning = CodexApplicationRestarter(
        pidProvider: { [] },
        scheduler: { _, _ in expect(false, "Codex 未运行时不应等待") },
        launcher: { completion in
            immediateLaunches += 1
            completion(.success(()))
        }
    )
    notRunning.forceRestart(after: 2) { _ in }
    expect(immediateLaunches == 1, "Codex 未运行时直接启动")

    var permissionLaunches = 0
    var permissionFailure = false
    let denied = CodexApplicationRestarter(
        pidProvider: { [303] },
        signalSender: { _ in CodexSignalResult(status: .failed(EPERM)) },
        processChecker: { _ in true },
        scheduler: { delay, work in
            expect(delay == 2, "权限失败路径仍先等待两秒")
            work()
        },
        launcher: { _ in permissionLaunches += 1 }
    )
    denied.forceRestart(after: 2) { result in
        if case .failure = result { permissionFailure = true }
    }
    expect(permissionFailure, "SIGKILL 权限失败被报告")
    expect(permissionLaunches == 0, "SIGKILL 权限失败不重启")

    var esrchLaunches = 0
    let alreadyExited = CodexApplicationRestarter(
        pidProvider: { [404] },
        signalSender: { _ in CodexSignalResult(status: .alreadyExited) },
        processChecker: { _ in false },
        scheduler: { _, work in work() },
        launcher: { completion in
            esrchLaunches += 1
            completion(.success(()))
        }
    )
    alreadyExited.forceRestart(after: 2) { _ in }
    expect(esrchLaunches == 1, "ESRCH 视为已退出并重新启动")
}

final class MockVisibilityStore: FinderVisibilityStore {
    var value: Bool?
    var writeShouldFail = false
    var writes: [Bool] = []

    func readShowAllFiles() -> Bool? { value }

    func writeShowAllFiles(_ newValue: Bool) -> Bool {
        writes.append(newValue)
        if writeShouldFail { return false }
        value = newValue
        return true
    }
}

final class MockRelauncher: FinderRelauncher {
    var shouldFail = false
    var calls = 0

    func relaunch() -> Bool {
        calls += 1
        return !shouldFail
    }
}

func testFinderVisibilityService() {
    let store = MockVisibilityStore()
    let relauncher = MockRelauncher()
    let service = FinderVisibilityService(store: store, relauncher: relauncher)

    expect(service.currentShowAllFiles() == false, "缺失偏好视为隐藏")

    store.value = false
    expect(service.setShowAllFiles(true), "写入并重启成功")
    expect(store.value == true, "偏好已更新为显示")
    expect(relauncher.calls == 1, "成功路径重启一次")

    store.writeShouldFail = true
    let beforeFail = store.value
    let writeCalls = store.writes.count
    expect(!service.setShowAllFiles(false), "写入失败返回 false")
    expect(store.value == beforeFail, "写入失败不改权威值")
    expect(relauncher.calls == 1, "写入失败不重启")
    expect(store.writes.count == writeCalls + 1, "失败写入仍被尝试")

    store.writeShouldFail = false
    store.value = true
    relauncher.shouldFail = true
    expect(!service.setShowAllFiles(false), "重启失败返回 false")
    expect(store.value == true, "重启失败后恢复旧值")
    expect(store.writes.suffix(2).map { $0 } == [false, true], "重启失败先写新值再回滚")
}

struct MockScript: AppleScriptRunning {
    var result: Result<String, FinderSelectionError>

    func execute(_ source: String) -> Result<String, FinderSelectionError> {
        _ = source
        return result
    }
}

func testFinderSelectionService() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("tocode-sel-\(UUID().uuidString)").path
    try! fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    let file = (tmp as NSString).appendingPathComponent("note.txt")
    fm.createFile(atPath: file, contents: Data())
    let fs = FileSystemService()

    func service(result: Result<String, FinderSelectionError>) -> FinderSelectionService {
        FinderSelectionService(script: MockScript(result: result), fs: fs)
    }

    switch service(result: .success("")).resolveInitializationDirectory() {
    case .failure(.notExactlyOne):
        expect(true, "空选择视为非恰好一项")
    default:
        expect(false, "空选择视为非恰好一项")
    }

    switch service(result: .failure(.notExactlyOne)).resolveInitializationDirectory() {
    case .failure(.notExactlyOne):
        expect(true, "多选/非恰好一项失败")
    default:
        expect(false, "多选/非恰好一项失败")
    }

    switch service(result: .success(tmp)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "单选文件夹使用自身")
    default:
        expect(false, "单选文件夹使用自身")
    }

    switch service(result: .success(file)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "单选文件使用父级文件夹")
    default:
        expect(false, "单选文件使用父级文件夹")
    }

    let fileURL = URL(fileURLWithPath: file).absoluteString
    switch service(result: .success(fileURL)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "Finder 文件 URL 解码后使用父级文件夹")
    default:
        expect(false, "Finder 文件 URL 解码后使用父级文件夹")
    }

    switch service(result: .success("file://%")).resolveInitializationDirectory() {
    case .failure(.invalidPath):
        expect(true, "无效 Finder 文件 URL 拒绝设根")
    default:
        expect(false, "无效 Finder 文件 URL 拒绝设根")
    }

    switch service(result: .success(tmp + "/missing-item")).resolveInitializationDirectory() {
    case .failure(.invalidPath):
        expect(true, "失效路径拒绝设根")
    default:
        expect(false, "失效路径拒绝设根")
    }

    switch service(result: .failure(.notPermitted)).resolveInitializationDirectory() {
    case .failure(.notPermitted):
        expect(true, "自动化权限拒绝")
    default:
        expect(false, "自动化权限拒绝")
    }

    switch service(result: .failure(.scriptFailed)).resolveInitializationDirectory() {
    case .failure(.scriptFailed):
        expect(true, "脚本错误拒绝设根")
    default:
        expect(false, "脚本错误拒绝设根")
    }
}

func snapshot(
    _ keyCode: Int64,
    down: Bool,
    repeat isRepeat: Bool = false,
    synthesized: Bool = false,
    shift: Bool = false,
    option: Bool = false,
    control: Bool = false,
    command: Bool = true
) -> KeyboardEventSnapshot {
    var flags: CGEventFlags = command ? .maskCommand : []
    if shift { flags.insert(.maskShift) }
    if option { flags.insert(.maskAlternate) }
    if control { flags.insert(.maskControl) }
    return ShortcutKeyClassifier.snapshot(
        keyCode: keyCode,
        flags: flags,
        isKeyDown: down,
        isAutoRepeat: isRepeat,
        userData: synthesized ? GlobalShortcutEngine.synthesizerMarker : 0
    )
}

let finderApp = FrontmostAppInfo(pid: 10, bundleIdentifier: "com.apple.finder", localizedName: "Finder")
let safariApp = FrontmostAppInfo(pid: 20, bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func testShortcutSettingsStoreDefaults() {
    let suite = "tocode-shortcut-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = ShortcutSettingsStore(defaults: defaults)
    expect(!store.finderMoveHotkeysEnabled, "finderMove 默认关闭")
    expect(!store.doubleCommandQEnabled, "doubleCommandQ 默认关闭")

    store.finderMoveHotkeysEnabled = true
    store.doubleCommandQEnabled = true
    expect(store.finderMoveHotkeysEnabled, "finderMove 可持久化为开启")
    expect(store.doubleCommandQEnabled, "doubleCommandQ 可持久化为开启")
    expect(!store.finderCommandQEnabled, "finderCommandQ 默认关闭")

    store.finderCommandQEnabled = true
    expect(store.finderCommandQEnabled, "finderCommandQ 可持久化为开启")

    store.finderMoveHotkeysEnabled = false
    expect(!store.finderMoveHotkeysEnabled, "finderMove 可写回关闭")
}

func testShortcutEventClassification() {
    let cmdX = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyX,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: false,
        userData: 0
    )
    expect(cmdX.key == .commandX && cmdX.isKeyDown, "⌘X keyDown 分类")

    let cmdVUp = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyV,
        flags: .maskCommand,
        isKeyDown: false,
        isAutoRepeat: false,
        userData: 0
    )
    expect(cmdVUp.key == .commandV && !cmdVUp.isKeyDown, "⌘V keyUp 分类")

    let cmdQ = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyQ,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: true,
        userData: 0
    )
    expect(cmdQ.key == .commandQ && cmdQ.isAutoRepeat, "⌘Q 自动重复分类")

    let plainX = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyX,
        flags: [],
        isKeyDown: true,
        isAutoRepeat: false,
        userData: 0
    )
    expect(plainX.key == .other, "无 Command 的 X 不分类为快捷键")

    let synth = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyC,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: false,
        userData: GlobalShortcutEngine.synthesizerMarker
    )
    expect(synth.isSynthesized && synth.key == .other, "合成 ⌘C 带标记且不进入 X/V/Q")

    let rewritten = ShortcutEventApplicator.flags(for: .rewriteOptionCommandV, current: .maskCommand)
    expect(rewritten?.contains(.maskAlternate) == true && rewritten?.contains(.maskCommand) == true, "⌘V 改写附加 Option")
    expect(ShortcutEventApplicator.flags(for: .suppress, current: .maskCommand) == nil, "suppress 不返回 flags")
}

func testFinderMoveStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setFinderMoveEnabled(true)

    let xDown = snapshot(ShortcutKeyClassifier.keyX, down: true)
    let xUp = snapshot(ShortcutKeyClassifier.keyX, down: false)
    let vDown = snapshot(ShortcutKeyClassifier.keyV, down: true)
    let vUp = snapshot(ShortcutKeyClassifier.keyV, down: false)

    expect(
        engine.process(xDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1) == .pass,
        "非 Finder 的 ⌘X 透传"
    )
    expect(!engine.isCutPrepared, "非 Finder 不进入剪切预备")

    let probe = engine.process(xDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(probe.action == .suppress && probe.effect == .probeFinderCut, "Finder ⌘X keyDown 吞掉并探测")
    expect(!engine.isCutPrepared, "探测开始时清掉旧预备")
    expect(engine.process(xUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "Finder ⌘X keyUp 吞掉")

    let repeatX = snapshot(ShortcutKeyClassifier.keyX, down: true, repeat: true)
    expect(engine.process(repeatX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "⌘X 自动重复不探测")

    let shiftX = snapshot(ShortcutKeyClassifier.keyX, down: true, shift: true)
    expect(engine.process(shiftX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "⌘⇧X 透传")

    let synthX = snapshot(ShortcutKeyClassifier.keyX, down: true, synthesized: true)
    expect(engine.process(synthX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "合成 ⌘X 防递归透传")

    engine.armCut(changeCount: 4)
    expect(engine.process(vDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 4) == .pass, "非 Finder 的 ⌘V 不改写")
    expect(engine.isCutPrepared, "离开 Finder 不清除仍有效的预备")

    let rewrite = engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 4)
    expect(rewrite.action == .rewriteOptionCommandV, "有效预备下 ⌘V 改写为 ⌥⌘V")
    expect(!engine.isCutPrepared, "完成一次移动后清除预备")
    expect(
        engine.process(vUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 5).action == .rewriteOptionCommandV,
        "对应 keyUp 一并改写"
    )
    expect(engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 5) == .pass, "无预备时普通粘贴透传")

    engine.armCut(changeCount: 7)
    engine.invalidateCutIfNeeded(currentChangeCount: 8)
    expect(!engine.isCutPrepared, "剪贴板变化取消预备")
    expect(engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 8) == .pass, "剪贴板已变则普通粘贴")

    engine.setFinderMoveEnabled(false)
    engine.armCut(changeCount: 9)
    engine.setFinderMoveEnabled(false)
    expect(!engine.isCutPrepared, "关闭开关清除预备")
    expect(engine.process(xDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 9) == .pass, "开关关闭时 Finder ⌘X 透传")
}

func testDoubleCommandQStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setDoubleCommandQEnabled(true)
    let qDown = snapshot(ShortcutKeyClassifier.keyQ, down: true)
    let qUp = snapshot(ShortcutKeyClassifier.keyQ, down: false)

    expect(engine.process(qDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "第一次 ⌘Q keyDown 吞掉")
    expect(engine.process(qUp, frontmost: safariApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "第一次 ⌘Q keyUp 吞掉")
    expect(engine.quitArm?.pid == safariApp.pid, "记录前台 PID")

    let repeatQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, repeat: true)
    expect(engine.process(repeatQ, frontmost: safariApp, now: t0.addingTimeInterval(0.2), pasteboardChangeCount: 1).action == .suppress, "自动重复不算第二次")
    expect(engine.quitArm != nil, "自动重复不解除武装")

    let second = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(1.0), pasteboardChangeCount: 1)
    expect(second == .pass, "2 秒内同 PID 第二次放行")
    expect(engine.quitArm == nil, "确认退出后解除武装")
    expect(engine.process(qUp, frontmost: safariApp, now: t0.addingTimeInterval(1.0), pasteboardChangeCount: 1) == .pass, "第二次 keyUp 放行")

    let firstAgain = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(1.1), pasteboardChangeCount: 1)
    expect(firstAgain.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: false), "新周期第一次发出提示")
    let switched = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(1.5), pasteboardChangeCount: 1)
    expect(switched.action == .suppress && switched.effect == .notifyQuitArmed(appName: "Safari", finderDismiss: false), "切换应用重新计数")

    _ = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(10), pasteboardChangeCount: 1)
    let timedOut = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(12.1), pasteboardChangeCount: 1)
    expect(timedOut.action == .suppress, "超时后本次当作新的第一次")

    let shiftQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, shift: true)
    expect(engine.process(shiftQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "⌘⇧Q 不拦截")
    let optionQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, option: true)
    expect(engine.process(optionQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "⌥⌘Q 不拦截")
    let synthQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, synthesized: true)
    expect(engine.process(synthQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "合成 ⌘Q 透传")
    expect(engine.process(qDown, frontmost: nil, now: t0.addingTimeInterval(30), pasteboardChangeCount: 1) == .pass, "无前台应用时 ⌘Q fail-open")

    engine.setDoubleCommandQEnabled(false)
    expect(engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(40), pasteboardChangeCount: 1) == .pass, "开关关闭时 ⌘Q 零处理")
}

final class MockShortcutPermissions: ShortcutPermissionChecking {
    var accessibility = false
    var grantOnRequest = false
    var requests = 0

    func hasAccessibilityAccess() -> Bool { accessibility }
    func requestAccessibilityAccess() -> Bool {
        requests += 1
        if grantOnRequest { accessibility = true }
        return accessibility
    }
}

final class MockShortcutTap: ShortcutTapControlling {
    var isInstalled = false
    var isEnabled = false
    var installShouldFail = false
    var reenableShouldFail = false
    var installCount = 0
    var removeCount = 0
    var handler: ((CGEventType, CGEvent) -> ShortcutAction)?

    func install(handler: @escaping (CGEventType, CGEvent) -> ShortcutAction) -> Bool {
        if installShouldFail { return false }
        self.handler = handler
        isInstalled = true
        isEnabled = true
        installCount += 1
        return true
    }

    func remove() {
        isInstalled = false
        isEnabled = false
        handler = nil
        removeCount += 1
    }

    func reenable() -> Bool {
        if reenableShouldFail {
            isEnabled = false
            return false
        }
        isEnabled = true
        return isInstalled
    }
}

final class MockFrontmost: FrontmostApplicationProviding {
    var app: FrontmostAppInfo?
    func frontmost() -> FrontmostAppInfo? { app }
}

final class MockFilePasteboard: FilePasteboardReading {
    var changeCount = 1
    var hasFiles = false
    func containsFileURLs() -> Bool { hasFiles }
}

final class MockSynthesizer: KeyboardEventSynthesizing {
    var posted: [String] = []
    func postCommandX() { posted.append("x") }
    func postCommandC() { posted.append("c") }
}

final class MockEditingContext: FinderEditingContextChecking {
    var editing = false
    func isEditingText() -> Bool { editing }
}

final class MockClock: ShortcutClock {
    var current = t0
    func now() -> Date { current }
}

final class ManualScheduler: ShortcutScheduling {
    var pending: [() -> Void] = []
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func asyncAfter(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        _ = seconds
        pending.append(work)
    }
    func runNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }
    func runAll() {
        while !pending.isEmpty { runNext() }
    }
}

final class MockAlerts: ShortcutAlerting {
    var titles: [String] = []
    func notify(title: String, body: String) {
        _ = body
        titles.append(title)
    }
}

final class MockCommandQTarget: CommandQTargetProviding {
    let frontmost: MockFrontmost
    var override: FrontmostAppInfo?
    var unknown = false

    init(frontmost: MockFrontmost) {
        self.frontmost = frontmost
    }

    func commandQTarget() -> FrontmostAppInfo? {
        if unknown { return nil }
        return override ?? frontmost.app
    }
}

final class MockFinderDismiss: FinderWindowDismissing {
    var calls = 0
    var result: Result<Void, FinderDismissError> = .success(())

    func dismissWindowsAndHide() -> Result<Void, FinderDismissError> {
        calls += 1
        return result
    }
}

final class MockFinderHider: FinderHiding {
    var calls = 0
    var succeed = true

    func hideFinder() -> Bool {
        calls += 1
        return succeed
    }
}

/// 真机可用探针 Hider：模拟真实 WorkspaceFinderHider 的语义——
/// 若 Finder 未运行返回 true（无需隐藏）；否则向 mock 进程发出 hide()
/// 请求即返回 true，不把 hide() 的瞬时返回 false 当作失败。
final class MockWorkspaceFinderHider: FinderHiding {
    struct FinderProc {
        var returnsSuccess: Bool
        var isHiddenAfterRequest: Bool
    }

    var apps: [FinderProc] = [FinderProc(returnsSuccess: false, isHiddenAfterRequest: true)]

    func hideFinder() -> Bool {
        if apps.isEmpty { return true }
        return true
    }
}

func makeShortcutHarness(
    accessibility: Bool = true,
    tapShouldFail: Bool = false
) -> (
    GlobalShortcutService,
    ShortcutSettingsStore,
    MockShortcutPermissions,
    MockShortcutTap,
    MockFrontmost,
    MockFilePasteboard,
    MockSynthesizer,
    MockEditingContext,
    MockClock,
    ManualScheduler,
    MockAlerts,
    MockCommandQTarget,
    MockFinderDismiss
) {
    let suite = "tocode-shortcut-svc-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = ShortcutSettingsStore(defaults: defaults)
    let permissions = MockShortcutPermissions()
    permissions.accessibility = accessibility
    let tap = MockShortcutTap()
    tap.installShouldFail = tapShouldFail
    let frontmost = MockFrontmost()
    let pasteboard = MockFilePasteboard()
    let synthesizer = MockSynthesizer()
    let editing = MockEditingContext()
    let clock = MockClock()
    let scheduler = ManualScheduler()
    let alerts = MockAlerts()
    let qTarget = MockCommandQTarget(frontmost: frontmost)
    let dismiss = MockFinderDismiss()
    let service = GlobalShortcutService(
        settings: settings,
        permissions: permissions,
        tap: tap,
        frontmostApps: frontmost,
        commandQTargets: qTarget,
        pasteboard: pasteboard,
        synthesizer: synthesizer,
        editingContext: editing,
        dismisser: dismiss,
        clock: clock,
        scheduler: scheduler,
        alerts: alerts
    )
    return (service, settings, permissions, tap, frontmost, pasteboard, synthesizer, editing, clock, scheduler, alerts, qTarget, dismiss)
}

func testShortcutServiceLifecycleAndFaults() {
    do {
        let (service, settings, _, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(accessibility: false)
        service.applySavedSettings()
        expect(!settings.finderMoveHotkeysEnabled && !settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "启动时默认开关关闭")
        expect(!tap.isInstalled, "默认不安装钩子")
        expect(!service.isFinderMoveEffective && !service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "默认无效")
        expect(alerts.titles.isEmpty, "默认关闭不提示")
    }

    do {
        let (service, settings, permissions, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(accessibility: false)
        expect(!service.setFinderMoveEnabled(true), "无辅助功能授权时开启失败")
        expect(!settings.finderMoveHotkeysEnabled, "失败后开关保持关闭")
        expect(!service.isFinderMoveEffective, "失败后不显示开启")
        expect(!tap.isInstalled, "无权限不安装钩子")
        expect(permissions.requests == 1, "只请求一次辅助功能授权")
        expect(alerts.titles.contains("无法开启快捷键"), "无权限给出提示")
    }

    do {
        let (service, settings, permissions, tap, _, _, _, _, _, _, _, _, _) = makeShortcutHarness(accessibility: false)
        permissions.grantOnRequest = true
        expect(service.setDoubleCommandQEnabled(true), "辅助功能请求即时获准后可开启")
        expect(settings.doubleCommandQEnabled && service.isDoubleCommandQEffective, "获准并安装钩子后才显示开启")
        expect(tap.isInstalled, "辅助功能获准后安装钩子")
        expect(permissions.requests == 1, "不会请求额外 Input Monitoring 或 PostEvent")
    }

    do {
        let (service, settings, _, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(tapShouldFail: true)
        expect(!service.setFinderMoveEnabled(true), "钩子创建失败则开启失败")
        expect(!settings.finderMoveHotkeysEnabled, "钩子失败后开关关闭")
        expect(!tap.isInstalled, "创建失败不保留钩子")
        expect(alerts.titles.contains("无法开启快捷键"), "钩子失败给出提示")
    }

    do {
        let (service, settings, _, tap, _, _, _, _, _, _, _, _, _) = makeShortcutHarness()
        expect(service.setFinderMoveEnabled(true), "权限与钩子可用时开启移动")
        expect(settings.finderMoveHotkeysEnabled && service.isFinderMoveEffective, "生效后才算开启")
        expect(tap.installCount == 1, "首次开启安装一次钩子")
        expect(service.setDoubleCommandQEnabled(true), "第二项复用同一钩子")
        expect(tap.installCount == 1, "共享钩子不重复安装")
        expect(service.isDoubleCommandQEffective, "第二项也生效")
        expect(service.setFinderCommandQEnabled(true), "第三项复用同一钩子")
        expect(tap.installCount == 1, "第三项不重复安装")
        expect(service.isFinderCommandQEffective, "第三项也生效")

        expect(service.setFinderMoveEnabled(false), "关闭其中一项")
        expect(tap.isInstalled, "仍有一项开启时保留钩子")
        expect(!service.isFinderMoveEffective && service.isDoubleCommandQEffective, "只关闭被关的一项")

        expect(service.setDoubleCommandQEnabled(false), "关闭第二项后仍保留钩子")
        expect(tap.isInstalled, "第三项仍开启时保留钩子")
        expect(service.setFinderCommandQEnabled(false), "关闭最后一项")
        expect(!tap.isInstalled, "全部关闭后移除钩子")
        expect(tap.removeCount >= 1, "全部关闭会拆除钩子")
    }

    do {
        let suite = "tocode-shortcut-apply-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = ShortcutSettingsStore(defaults: defaults)
        settings.finderMoveHotkeysEnabled = true
        settings.doubleCommandQEnabled = true
        settings.finderCommandQEnabled = true
        let permissions = MockShortcutPermissions()
        let tap = MockShortcutTap()
        let alerts = MockAlerts()
        let service = GlobalShortcutService(
            settings: settings,
            permissions: permissions,
            tap: tap,
            frontmostApps: MockFrontmost(),
            pasteboard: MockFilePasteboard(),
            synthesizer: MockSynthesizer(),
            editingContext: MockEditingContext(),
            clock: MockClock(),
            scheduler: ManualScheduler(),
            alerts: alerts
        )
        service.applySavedSettings()
        expect(!settings.finderMoveHotkeysEnabled && !settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "启动恢复失败则写回关闭")
        expect(!service.isFinderMoveEffective && !service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "启动恢复失败不生效")
    }

    do {
        let (service, settings, _, tap, frontmost, _, _, _, _, scheduler, alerts, _, _) = makeShortcutHarness()
        expect(service.setDoubleCommandQEnabled(true), "开启双击以便注入钩子停用")
        tap.isEnabled = false
        tap.reenableShouldFail = true
        _ = tap.handler?(.tapDisabledByTimeout, CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
        scheduler.runAll()
        expect(!settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "无法恢复时关闭开关")
        expect(!service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "无法恢复后不显示开启")
        expect(!tap.isInstalled, "无法恢复后拆除钩子")
        expect(alerts.titles.contains("快捷键保护已关闭"), "无法恢复时提示并放行")
        _ = frontmost
    }
}

func testFinderCutProbeAndQuitEffects() {
    let (service, _, _, _, frontmost, pasteboard, synthesizer, editing, clock, scheduler, alerts, _, _) = makeShortcutHarness()
    expect(service.setFinderMoveEnabled(true), "测试探测前开启移动")
    expect(service.setDoubleCommandQEnabled(true), "测试探测前开启双击")
    frontmost.app = finderApp

    editing.editing = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runAll()
    expect(synthesizer.posted == ["x"], "文本编辑回放 ⌘X")
    expect(!service.isCutPrepared, "文本编辑不进入剪切预备")

    synthesizer.posted.removeAll()
    editing.editing = false
    pasteboard.changeCount = 3
    pasteboard.hasFiles = false
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    expect(synthesizer.posted == ["c"], "文件上下文补发 ⌘C")
    scheduler.runAll()
    expect(!service.isCutPrepared, "无文件 URL 不沿用旧剪贴板")

    pasteboard.changeCount = 5
    pasteboard.hasFiles = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    pasteboard.changeCount = 6
    scheduler.runAll()
    expect(service.isCutPrepared, "changeCount 变化且含文件 URL 才预备")

    frontmost.app = safariApp
    let foreign = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(foreign == .pass, "切到其他应用后 ⌘V 透传")
    expect(service.isCutPrepared, "其他应用不消耗预备")

    frontmost.app = finderApp
    pasteboard.changeCount = 9
    let stale = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(stale == .pass, "剪贴板被改写后普通粘贴")
    expect(!service.isCutPrepared, "剪贴板变化取消预备")

    pasteboard.changeCount = 10
    pasteboard.hasFiles = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    pasteboard.changeCount = 11
    scheduler.runAll()
    let moved = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(moved.action == .rewriteOptionCommandV, "有效预备改写为移动")

    frontmost.app = safariApp
    clock.current = t0
    alerts.titles.removeAll()
    let firstQ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(firstQ.action == .suppress, "服务层第一次 ⌘Q 吞掉")
    expect(alerts.titles.isEmpty, "第一次按下后不立即通知（静默待命）")
    clock.current = t0.addingTimeInterval(1)
    let secondQ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(secondQ == .pass, "同 PID 时间窗内第二次放行")
    scheduler.runAll()
    expect(!alerts.titles.contains("再次按 ⌘Q 退出 Safari"), "窗口内确认退出后撤销补发通知")
    expect(service.isDoubleCommandQEffective, "确认退出后开关仍生效")

    // 只按一次、2 秒后无第二次 → 超时才补发一条通知。
    alerts.titles.removeAll()
    clock.current = t0.addingTimeInterval(10)
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(alerts.titles.isEmpty, "新一轮第一次仍静默")
    scheduler.runAll()
    expect(alerts.titles == ["再次按 ⌘Q 退出 Safari"], "超时未二次按下仅补发一次通知")
}

func testShortcutMenuAppearance() {
    let item = NSMenuItem()

    ShortcutMenuAppearance.apply(to: item, enabled: false)
    expect(item.state == .off, "快捷键关闭时菜单 state 为 off")
    expect(ShortcutMenuAppearance.symbolName(enabled: false) == "circle", "快捷键关闭时使用 circle")
    expect(item.image != nil, "快捷键关闭图标可创建")

    ShortcutMenuAppearance.apply(to: item, enabled: true)
    expect(item.state == .off, "快捷键生效后不显示额外系统勾选")
    expect(
        ShortcutMenuAppearance.symbolName(enabled: true) == "checkmark.circle.fill",
        "快捷键生效后立即使用勾选图标"
    )
    expect(item.image != nil, "快捷键开启图标可创建")
}

func testFinderCommandQStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setFinderCommandQEnabled(true)
    let qDown = snapshot(ShortcutKeyClassifier.keyQ, down: true)
    let qUp = snapshot(ShortcutKeyClassifier.keyQ, down: false)

    expect(engine.process(qDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1) == .pass, "仅关窗隐藏时非 Finder 透传")
    let dismiss = engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(dismiss.action == .suppress && dismiss.effect == .dismissFinderWindows, "仅关窗隐藏时 Finder 单击关窗隐藏")
    expect(engine.process(qUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "关窗隐藏后吞掉配对 keyUp")

    let shiftQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, shift: true)
    expect(engine.process(shiftQ, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "⌘⇧Q 不关窗")
    let repeatQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, repeat: true)
    expect(engine.process(repeatQ, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "自动重复不算另一次关窗")
    expect(
        engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1, commandQTargetUnknown: true) == .pass,
        "目标不明时放行"
    )

    engine.setDoubleCommandQEnabled(true)
    let first = engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(
        first.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true),
        "双开时第一次只提示关窗隐藏"
    )
    let second = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(1), pasteboardChangeCount: 1)
    expect(second.action == .suppress && second.effect == .dismissFinderWindows, "双开时第二次关窗隐藏且不放行原生 ⌘Q")

    _ = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(10), pasteboardChangeCount: 1)
    let switched = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(11), pasteboardChangeCount: 1)
    expect(
        switched.action == .suppress && switched.effect == .notifyQuitArmed(appName: "Safari", finderDismiss: false),
        "切换 PID 后重新第一次"
    )
    _ = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1)
    let timedOut = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(22.1), pasteboardChangeCount: 1)
    expect(timedOut.action == .suppress && timedOut.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true), "超时后重新第一次")

    let optionQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, option: true)
    expect(engine.process(optionQ, frontmost: finderApp, now: t0.addingTimeInterval(30), pasteboardChangeCount: 1) == .pass, "⌥⌘Q 不关窗")
}

func testCommandQTargetResolver() {
    let finder = FrontmostAppInfo(
        pid: 10,
        bundleIdentifier: "com.apple.finder",
        localizedName: "Finder",
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    )
    let safari = FrontmostAppInfo(
        pid: 20,
        bundleIdentifier: "com.apple.Safari",
        localizedName: "Safari",
        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )
    let running = [finder, safari]

    switch AppSwitcherSelectionResolver.resolve(
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        title: "Finder",
        running: running
    ) {
    case .selected(let app):
        expect(app.isFinder, "URL 优先解析为 Finder")
    default:
        expect(false, "URL 优先解析为 Finder")
    }

    switch AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: "Safari", running: running) {
    case .selected(let app):
        expect(app.bundleIdentifier == "com.apple.Safari", "唯一标题匹配 Safari")
    default:
        expect(false, "唯一标题匹配 Safari")
    }

    let twins = [
        FrontmostAppInfo(pid: 1, bundleIdentifier: "a", localizedName: "Notes"),
        FrontmostAppInfo(pid: 2, bundleIdentifier: "b", localizedName: "Notes")
    ]
    if case .unresolved = AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: "Notes", running: twins) {
        expect(true, "标题歧义视为未知")
    } else {
        expect(false, "标题歧义视为未知")
    }

    if case .unresolved = AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: nil, running: running) {
        expect(true, "无 URL 无标题视为未知")
    } else {
        expect(false, "无 URL 无标题视为未知")
    }

    if case .unresolved = DockSwitcherLookupDecision.fromFocused(.timedOut) {
        expect(true, "AX 焦点超时视为未知")
    } else {
        expect(false, "AX 焦点超时视为未知")
    }
    if case .inactive = DockSwitcherLookupDecision.fromFocused(.missing) {
        expect(true, "无焦点视为切换器未打开")
    } else {
        expect(false, "无焦点视为切换器未打开")
    }
    if case .unresolved = DockSwitcherLookupDecision.fromSelectedChildren(.timedOut) {
        expect(true, "选中项超时视为未知")
    } else {
        expect(false, "选中项超时视为未知")
    }

    final class MockSwitcher: AppSwitcherInspecting {
        var lookupResult: AppSwitcherLookup = .inactive
        func lookup() -> AppSwitcherLookup { lookupResult }
    }
    let switcher = MockSwitcher()
    let frontmost = MockFrontmost()
    frontmost.app = safari
    let provider = WorkspaceCommandQTargetProvider(frontmost: frontmost, switcher: switcher)
    expect(provider.commandQTarget()?.bundleIdentifier == "com.apple.Safari", "切换器未打开时用前台")
    switcher.lookupResult = .selected(finder)
    expect(provider.commandQTarget()?.isFinder == true, "切换器选中 Finder 覆盖前台")
    switcher.lookupResult = .unresolved
    expect(provider.commandQTarget() == nil, "切换器歧义或超时不回退前台")
}

func testFinderDismissServiceFaults() {
    let hider = MockFinderHider()
    let permitted = FinderDismissService(script: MockScript(result: .success("")), hider: hider)
    if case .success = permitted.dismissWindowsAndHide() {
        expect(true, "关窗成功后隐藏")
    } else {
        expect(false, "关窗成功后隐藏")
    }
    expect(hider.calls == 1, "零窗口或关窗成功后仍隐藏")

    hider.calls = 0
    let denied = FinderDismissService(script: MockScript(result: .failure(.notPermitted)), hider: hider)
    if case .failure(.notPermitted) = denied.dismissWindowsAndHide() {
        expect(true, "Automation 拒绝")
    } else {
        expect(false, "Automation 拒绝")
    }
    expect(hider.calls == 0, "Automation 失败不隐藏")

    let failed = FinderDismissService(script: MockScript(result: .failure(.scriptFailed)), hider: hider)
    if case .failure(.scriptFailed) = failed.dismissWindowsAndHide() {
        expect(true, "脚本失败")
    } else {
        expect(false, "脚本失败")
    }
    expect(hider.calls == 0, "脚本失败不隐藏")

    hider.succeed = false
    let hideFail = FinderDismissService(script: MockScript(result: .success("")), hider: hider)
    if case .failure(.hideFailed) = hideFail.dismissWindowsAndHide() {
        expect(true, "隐藏失败单独报告")
    } else {
        expect(false, "隐藏失败单独报告")
    }
}

func testFinderDismissHideTransientResult() {
    // 回归：close every window 收尾期间系统 hide() 瞬时返回 false，但 Finder
    // 随后仍成功隐藏（真机探针 /tmp/finder_hide_probe：hide()=false、
    // isHidden@300ms/1s=true）。hider 应把隐藏请求已提交视为成功，不再误报失败。
    let hiddenHider = MockWorkspaceFinderHider()
    hiddenHider.apps = [MockWorkspaceFinderHider.FinderProc(returnsSuccess: false, isHiddenAfterRequest: true)]
    let ok = FinderDismissService(script: MockScript(result: .success("")), hider: hiddenHider)
    if case .success = ok.dismissWindowsAndHide() {
        expect(true, "hide() 瞬时 false 视为请求已提交成功")
    } else {
        expect(false, "hide() 瞬时 false 视为请求已提交成功")
    }

    let noApp = MockWorkspaceFinderHider()
    noApp.apps = []
    let okNoApp = FinderDismissService(script: MockScript(result: .success("")), hider: noApp)
    if case .success = okNoApp.dismissWindowsAndHide() {
        expect(true, "Finder 未运行视为无需隐藏")
    } else {
        expect(false, "Finder 未运行视为无需隐藏")
    }

    let ok2 = FinderDismissService(script: MockScript(result: .success("")), hider: MockWorkspaceFinderHider())
    if case .success = ok2.dismissWindowsAndHide() {
        expect(true, "默认多 Finder 进程同样视为成功")
    } else {
        expect(false, "默认多 Finder 进程同样视为成功")
    }
}

func testFinderCommandQServiceEffects() {
    let (service, _, _, _, frontmost, _, _, _, _, scheduler, alerts, qTarget, dismiss) = makeShortcutHarness()
    expect(service.setFinderCommandQEnabled(true), "开启关窗隐藏")
    frontmost.app = safariApp
    qTarget.override = finderApp
    let switched = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(switched.effect == .dismissFinderWindows, "Command-Tab 选中 Finder 时仍关窗")
    scheduler.runAll()
    expect(dismiss.calls == 1, "异步执行关窗隐藏")

    qTarget.override = nil
    qTarget.unknown = true
    let unknown = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(unknown == .pass, "切换器目标不明时透传")
    expect(dismiss.calls == 1, "目标不明不关窗")

    qTarget.unknown = false
    frontmost.app = finderApp
    dismiss.result = .failure(.notPermitted)
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    scheduler.runAll()
    expect(alerts.titles.contains("无法关闭访达窗口"), "Automation 失败给出提示")

    expect(service.setDoubleCommandQEnabled(true), "同时开启双击")
    dismiss.result = .success(())
    dismiss.calls = 0
    alerts.titles.removeAll()
    let first = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(first.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true), "服务层双开第一次提示关窗")
    expect(alerts.titles.isEmpty, "服务层第一次按下静默待命")
    expect(dismiss.calls == 0, "第一次不关窗")
    let second = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(second.effect == .dismissFinderWindows, "窗口内第二次关窗隐藏")
    scheduler.runAll()
    expect(dismiss.calls == 1, "第二次异步执行关窗隐藏")
    expect(!alerts.titles.contains("再次按 ⌘Q 强关访达"), "窗口内确认关窗后撤销补发通知")

    // 只按一次、超时未再按 → 才补发一次针对 Finder 关窗的提示。
    alerts.titles.removeAll()
    dismiss.calls = 0
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(alerts.titles.isEmpty, "新一轮第一次静默")
    scheduler.runAll()
    expect(alerts.titles == ["再次按 ⌘Q 强关访达"], "超时未二次按下仅补发一次关窗提示")
    expect(dismiss.calls == 0, "超时补发提示不关窗")
}

final class MockLaunchAtLoginBackend: LaunchAtLoginBacking {
    var registration: LaunchAtLoginRegistration = .notEnabled
    var registerResult: Result<LaunchAtLoginRegistration, LaunchAtLoginError> = .success(.enabled)
    var unregisterResult: Result<LaunchAtLoginRegistration, LaunchAtLoginError> = .success(.notEnabled)
    var registerCalls = 0
    var unregisterCalls = 0
    var openSettingsCalls = 0

    func register() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError> {
        registerCalls += 1
        if case .success(let status) = registerResult {
            registration = status
        } else if case .failure(.needsApproval) = registerResult {
            registration = .needsApproval
        }
        return registerResult
    }

    func unregister() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError> {
        unregisterCalls += 1
        if case .success(let status) = unregisterResult {
            registration = status
        }
        return unregisterResult
    }

    func openLoginItemsSettings() {
        openSettingsCalls += 1
    }
}

func testLaunchAtLoginService() {
    expect(LaunchAtLoginService.menuTitle == "开机自启", "菜单标题为开机自启")

    let backend = MockLaunchAtLoginBackend()
    let service = LaunchAtLoginService(backend: backend)
    expect(!service.isEnabled, "默认未登记则关闭")

    if case .success = service.setEnabled(true) {
        expect(true, "登记成功")
    } else {
        expect(false, "登记成功")
    }
    expect(service.isEnabled, "登记成功后显示开启")
    expect(backend.registerCalls == 1, "开启时登记一次")

    if case .success = service.setEnabled(true) {
        expect(true, "已开启再开是空操作")
    } else {
        expect(false, "已开启再开是空操作")
    }
    expect(backend.registerCalls == 1, "已开启不再重复登记")

    if case .success = service.setEnabled(false) {
        expect(true, "撤销成功")
    } else {
        expect(false, "撤销成功")
    }
    expect(!service.isEnabled, "撤销后显示关闭")
    expect(backend.unregisterCalls == 1, "关闭时撤销一次")

    backend.registration = .notEnabled
    backend.registerResult = .failure(.needsApproval)
    if case .failure(.needsApproval) = service.setEnabled(true) {
        expect(true, "待批准不得宣称开启")
    } else {
        expect(false, "待批准不得宣称开启")
    }
    expect(!service.isEnabled, "待批准时菜单保持关闭")
    expect(backend.openSettingsCalls == 1, "待批准打开登录项设置")

    backend.registration = .notEnabled
    backend.registerResult = .failure(.registerFailed)
    if case .failure(.registerFailed) = service.setEnabled(true) {
        expect(true, "登记失败单独报告")
    } else {
        expect(false, "登记失败单独报告")
    }
    expect(!service.isEnabled, "登记失败保持关闭")

    backend.registration = .enabled
    backend.unregisterResult = .failure(.unregisterFailed)
    if case .failure(.unregisterFailed) = service.setEnabled(false) {
        expect(true, "撤销失败单独报告")
    } else {
        expect(false, "撤销失败单独报告")
    }
    expect(service.isEnabled, "撤销失败仍按系统权威显示开启")

    backend.registration = .needsApproval
    backend.unregisterResult = .success(.notEnabled)
    if case .success = service.setEnabled(false) {
        expect(true, "待批准也可撤销")
    } else {
        expect(false, "待批准也可撤销")
    }
    expect(!service.isEnabled, "撤销待批准后关闭")
}

final class MockMouseWheelTap: MouseWheelTapControlling {
    var isInstalled = false
    var isEnabled = false
    var installShouldFail = false
    var reenableShouldFail = false
    var installCount = 0
    var removeCount = 0
    var handler: ((CGEventType, CGEvent) -> Void)?

    func install(handler: @escaping (CGEventType, CGEvent) -> Void) -> Bool {
        if installShouldFail { return false }
        self.handler = handler
        isInstalled = true
        isEnabled = true
        installCount += 1
        return true
    }

    func remove() {
        isInstalled = false
        isEnabled = false
        handler = nil
        removeCount += 1
    }

    func reenable() -> Bool {
        if reenableShouldFail {
            isEnabled = false
            return false
        }
        isEnabled = true
        return isInstalled
    }
}

func makeWheelHarness(
    accessibility: Bool = true,
    tapShouldFail: Bool = false
) -> (
    MouseWheelReverseService,
    MouseWheelReverseStore,
    MockShortcutPermissions,
    MockMouseWheelTap,
    ManualScheduler,
    MockAlerts
) {
    let suite = "tocode-wheel-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = MouseWheelReverseStore(defaults: defaults)
    let permissions = MockShortcutPermissions()
    permissions.accessibility = accessibility
    let tap = MockMouseWheelTap()
    tap.installShouldFail = tapShouldFail
    let scheduler = ManualScheduler()
    let alerts = MockAlerts()
    let service = MouseWheelReverseService(
        settings: settings,
        permissions: permissions,
        tap: tap,
        scheduler: scheduler,
        alerts: alerts
    )
    return (service, settings, permissions, tap, scheduler, alerts)
}

func testMouseWheelReverse() {
    expect(MouseWheelReverseStore.verticalTitle == "对调垂直滚轮", "垂直菜单标题")
    expect(MouseWheelReverseStore.horizontalTitle == "对调横向滚轮", "横向菜单标题")

    let suite = "tocode-wheel-store-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MouseWheelReverseStore(defaults: defaults)
    expect(!store.reverseVerticalEnabled && !store.reverseHorizontalEnabled, "两键默认关闭")
    store.reverseVerticalEnabled = true
    expect(store.reverseVerticalEnabled && !store.reverseHorizontalEnabled, "垂直可单独开启")

    let discrete = ScrollWheelSnapshot(
        isContinuous: false,
        line1: 3,
        point1: 30,
        fixed1: 1.5,
        line2: 2,
        point2: 20,
        fixed2: 0.5
    )
    let continuous = ScrollWheelSnapshot(
        isContinuous: true,
        line1: 3,
        point1: 30,
        fixed1: 1.5,
        line2: 2,
        point2: 20,
        fixed2: 0.5
    )
    expect(
        MouseWheelReverse.apply(continuous, reverseVertical: true, reverseHorizontal: true) == continuous,
        "连续滚动不改写"
    )
    let onlyV = MouseWheelReverse.apply(discrete, reverseVertical: true, reverseHorizontal: false)
    expect(onlyV.line1 == -3 && onlyV.point1 == -30 && onlyV.fixed1 == -1.5, "只开垂直取反 Axis1")
    expect(onlyV.line2 == 2 && onlyV.point2 == 20 && onlyV.fixed2 == 0.5, "只开垂直不改 Axis2")
    let onlyH = MouseWheelReverse.apply(discrete, reverseVertical: false, reverseHorizontal: true)
    expect(onlyH.line2 == -2 && onlyH.point2 == -20 && onlyH.fixed2 == -0.5, "只开横向取反 Axis2")
    expect(onlyH.line1 == 3 && onlyH.point1 == 30 && onlyH.fixed1 == 1.5, "只开横向不改 Axis1")
    let both = MouseWheelReverse.apply(discrete, reverseVertical: true, reverseHorizontal: true)
    expect(both.line1 == -3 && both.line2 == -2, "双开两轴都取反")

    do {
        let (service, settings, _, tap, _, alerts) = makeWheelHarness()
        service.applySavedSettings()
        expect(!settings.reverseVerticalEnabled && !settings.reverseHorizontalEnabled, "启动默认关闭")
        expect(!tap.isInstalled, "默认不安装滚动钩子")
        expect(!service.isVerticalEffective && !service.isHorizontalEffective, "默认无效")
        expect(alerts.titles.isEmpty, "默认关闭不提示")
    }

    do {
        let (service, settings, permissions, tap, _, alerts) = makeWheelHarness(accessibility: false)
        expect(!service.setVerticalEnabled(true), "无辅助功能时开启失败")
        expect(!settings.reverseVerticalEnabled, "失败后垂直保持关闭")
        expect(!service.isVerticalEffective, "失败后不显示开启")
        expect(!tap.isInstalled, "无权限不安装滚动钩子")
        expect(permissions.requests == 1, "只请求一次辅助功能授权")
        expect(alerts.titles.contains("无法对调鼠标滚轮"), "无权限给出提示")
    }

    do {
        let (service, settings, _, tap, _, alerts) = makeWheelHarness(tapShouldFail: true)
        expect(!service.setHorizontalEnabled(true), "钩子创建失败则开启失败")
        expect(!settings.reverseHorizontalEnabled, "钩子失败后横向关闭")
        expect(!tap.isInstalled, "创建失败不保留滚动钩子")
        expect(alerts.titles.contains("无法对调鼠标滚轮"), "钩子失败给出提示")
    }

    do {
        let (service, _, _, tap, _, _) = makeWheelHarness()
        expect(service.setVerticalEnabled(true), "权限与钩子可用时开启垂直")
        expect(service.isVerticalEffective, "垂直生效后才算开启")
        expect(tap.installCount == 1, "首次开启安装一次滚动钩子")
        expect(service.setHorizontalEnabled(true), "横向复用同一滚动钩子")
        expect(tap.installCount == 1, "共享滚动钩子不重复安装")
        expect(service.isHorizontalEffective, "横向也生效")
        expect(service.setVerticalEnabled(false), "关闭垂直")
        expect(tap.isInstalled, "仍有横向时保留滚动钩子")
        expect(!service.isVerticalEffective && service.isHorizontalEffective, "只关闭垂直")
        expect(service.setHorizontalEnabled(false), "关闭最后一项")
        expect(!tap.isInstalled, "全部关闭后移除滚动钩子")
        expect(!service.isHorizontalEffective, "全部关闭会拆除滚动钩子")
    }

    do {
        let (service, settings, _, tap, _, _) = makeWheelHarness()
        settings.reverseVerticalEnabled = true
        settings.reverseHorizontalEnabled = true
        tap.installShouldFail = true
        service.applySavedSettings()
        expect(!settings.reverseVerticalEnabled && !settings.reverseHorizontalEnabled, "启动恢复失败则写回关闭")
        expect(!service.isVerticalEffective && !service.isHorizontalEffective, "启动恢复失败不生效")
    }

    do {
        let (service, settings, _, tap, scheduler, alerts) = makeWheelHarness()
        expect(service.setVerticalEnabled(true), "开启垂直以便注入钩子停用")
        tap.isEnabled = false
        tap.reenableShouldFail = true
        tap.handler?(.tapDisabledByTimeout, CGEvent(source: nil)!)
        scheduler.runAll()
        expect(!settings.reverseVerticalEnabled, "无法恢复时关闭滚轮开关")
        expect(!service.isVerticalEffective, "无法恢复后不显示开启")
        expect(!tap.isInstalled, "无法恢复后拆除滚动钩子")
        expect(alerts.titles.contains("滚轮对调已关闭"), "无法恢复时提示并放行")
    }
}

func dataFromHex(_ value: String) -> Data {
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        data.append(UInt8(value[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@MainActor
final class MockScreenBlackoutOverlay: ScreenBlackoutOverlaying {
    var isPresented = false
    var showCount = 0
    var dismissCount = 0

    func show() {
        isPresented = true
        showCount += 1
    }

    func dismiss() {
        isPresented = false
        dismissCount += 1
    }
}

@MainActor
func testScreenBlackoutService() {
    let overlay = MockScreenBlackoutOverlay()
    let service = ScreenBlackoutService(overlay: overlay)

    expect(!service.isPresented, "黑屏初始状态未呈现")
    expect(overlay.showCount == 0, "黑屏初始未调用 show")

    service.activate()
    expect(service.isPresented, "activate 后处于呈现状态")
    expect(overlay.showCount == 1, "activate 调用一次 show")

    service.activate()
    expect(service.isPresented, "再次 activate 仍处于呈现状态")
    expect(overlay.showCount == 1, "再次 activate 是 no-op 不重复 show")

    service.dismiss()
    expect(!service.isPresented, "dismiss 清除呈现状态")
    expect(overlay.dismissCount == 1, "dismiss 调用一次 overlay.dismiss")

    service.activate()
    expect(service.isPresented, "dismiss 后可再次 activate")
    expect(overlay.showCount == 2, "再次 activate 重新 show")
}

func testWeChatModelsCryptoAndState() {
    let voiceJSON = Data(#"{"type":3,"voice_item":{"text_item":{"text":"语音内容"}}}"#.utf8)
    let voice = try! JSONDecoder().decode(WeChatItem.self, from: voiceJSON)
    expect(voice.type == 3, "微信协议解析语音类型 3")
    expect(voice.voiceItem?.transcription == "语音内容", "语音缺少顶层 text 时仍解析 ASR")

    let qr = try! JSONDecoder().decode(
        WeChatQRCode.self,
        from: Data(#"{"qrcode":"poll-token"}"#.utf8)
    )
    expect(qr.qrcode == "poll-token", "二维码响应允许缺少 qrcode_img_content")
    expect(qr.scanURLString.contains("qrcode=poll-token"), "二维码生成微信 LiteApp 扫码地址")

    let trusted = [
        "https://weixin.qq.com",
        "https://ilinkai.weixin.qq.com/path",
        "https://novac2c.cdn.weixin.qq.com"
    ].compactMap(URL.init(string:))
    expect(trusted.allSatisfy(WeChatTrustPolicy.isTrustedAPIURL), "可信策略接受 HTTPS 微信主域与子域")
    expect(!WeChatTrustPolicy.isTrustedAPIURL(URL(string: "http://ilinkai.weixin.qq.com")!), "可信策略拒绝 HTTP")
    expect(!WeChatTrustPolicy.isTrustedAPIURL(URL(string: "https://weixin.qq.com.evil.test")!), "可信策略拒绝伪装后缀域")

    let keyHex = "000102030405060708090a0b0c0d0e0f"
    let ciphertext = dataFromHex("2c7a167d0fbcc0fa829c3a02b4f9c9fc")
    let expected = Data("hello wechat".utf8)
    expect(try! WeChatCrypto.decryptAESData(ciphertext, key: keyHex) == expected, "AES 解密接受 32 位十六进制密钥")
    let rawKeyBase64 = dataFromHex(keyHex).base64EncodedString()
    expect(try! WeChatCrypto.decryptAESData(ciphertext, key: rawKeyBase64) == expected, "AES 解密接受 Base64 原始密钥")
    let hexBase64 = Data(keyHex.utf8).base64EncodedString()
    expect(try! WeChatCrypto.decryptAESData(ciphertext, key: hexBase64) == expected, "AES 解密接受 Base64 十六进制密钥")
    do {
        _ = try WeChatCrypto.decryptAESData(ciphertext, key: "short")
        expect(false, "AES 拒绝错误长度密钥")
    } catch {
        expect(true, "AES 拒绝错误长度密钥")
    }
    do {
        _ = try WeChatCrypto.decryptAESData(Data(ciphertext.dropLast()), key: keyHex)
        expect(false, "AES 拒绝损坏密文")
    } catch {
        expect(true, "AES 拒绝损坏密文")
    }

    let message = WeChatMessage(
        fromUserID: "sender",
        contextToken: "secret-context-token",
        messageID: "message-id",
        createTime: 123,
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "hello"))]
    )
    let contextKey = WeChatDeduplication.key(for: message)
    expect(contextKey.hasPrefix("ctx:"), "去重优先使用 context_token 的哈希")
    expect(!contextKey.contains("secret-context-token"), "持久去重键不泄露 context_token")
    let msgKey = WeChatDeduplication.key(for: WeChatMessage(
        fromUserID: "sender",
        messageID: "message-id",
        items: []
    ))
    expect(msgKey.hasPrefix("msg:"), "无 context_token 时使用 msg_id 哈希")
    let fallbackKey = WeChatDeduplication.key(for: WeChatMessage(
        fromUserID: "sender",
        createTime: 123,
        items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "hello"))]
    ))
    expect(fallbackKey.hasPrefix("content:"), "无协议 ID 时使用规范化内容摘要")

    let stateDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tocode-wechat-state-\(UUID().uuidString)", isDirectory: true)
    let temp = stateDirectory.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let stateStore = FileWeChatReceiveStateStore(fileURL: temp)
    let oversized = (0...WeChatDeduplication.maximumKeys).map { "key-\($0)" }
    try! stateStore.save(WeChatReceiveState(cursor: "cursor-a", recentKeys: oversized))
    let loaded = stateStore.load()
    expect(loaded.cursor == "cursor-a", "微信游标持久化后恢复")
    expect(loaded.recentKeys.count == WeChatDeduplication.maximumKeys, "最近去重键限制为 2000 个")
    expect(loaded.recentKeys.first == "key-1", "去重键超限时淘汰最旧项")
    try! stateStore.reset()
    expect(stateStore.load() == .empty, "重绑时重置游标与去重状态")
}

func testWeChatArchiveNaming() {
    expect(
        WeChatArchiveService.sanitizedFilename("../folder\\report.pdf", fallback: "file.bin") == "report.pdf",
        "附件名去除路径分隔与上级目录"
    )
    expect(
        WeChatArchiveService.sanitizedFilename("\u{0000}\u{0007}", fallback: "file.bin") == "file.bin",
        "空或控制字符附件名使用回退名称"
    )
    let long = String(repeating: "a", count: 150) + ".txt"
    let shortened = WeChatArchiveService.sanitizedFilename(long, fallback: "file.bin")
    expect(shortened.count <= 120 && shortened.hasSuffix(".txt"), "附件名限长并保留扩展名")
    expect(
        WeChatArchiveService.sanitizedFilename("README", fallback: "file.bin") == "README",
        "无扩展名附件保持原名"
    )
}

func testWeChatBindingPage() {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(
        "tocode-wechat-page-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: directory) }
    let writer = WeChatBindingPageWriter(directory: directory)
    let page = try! writer.prepare(qrCode: WeChatQRCode(qrcode: "browser-qr-token"))
    let png = directory.appendingPathComponent("qrcode.png")
    var html = try! String(contentsOf: page, encoding: .utf8)
    expect(fm.fileExists(atPath: png.path), "浏览器绑定生成本地二维码 PNG")
    expect(html.contains("等待扫码") && html.contains("http-equiv=\"refresh\""), "等待页面每 2 秒自动刷新状态")
    expect(!html.contains("bot_token") && !html.contains("Bearer"), "浏览器页面不包含微信凭据字段")
    try! writer.update(.success)
    html = try! String(contentsOf: page, encoding: .utf8)
    expect(html.contains("微信绑定成功") && !html.contains("http-equiv=\"refresh\""), "成功页面停止刷新并提示可关闭")
}

func makeArchiveCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

func testWeChatArchive() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "tocode-wechat-archive-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: root) }
    let transport = MockWeChatTransport()
    transport.mediaResult = .success(Data("decoded-media".utf8))
    let archive = WeChatArchiveService(
        root: root,
        transport: transport,
        calendarProvider: makeArchiveCalendar
    )
    let calendar = makeArchiveCalendar()
    let receivedAt = calendar.date(from: DateComponents(
        year: 2026,
        month: 9,
        day: 7,
        hour: 8,
        minute: 9,
        second: 10,
        nanosecond: 123_000_000
    ))!
    let media = WeChatMedia(
        encryptQueryParameter: "encrypted-image",
        aesKey: Data(repeating: 1, count: 16).base64EncodedString()
    )
    let quoted = WeChatQuotedItem(
        type: 1,
        textItem: WeChatTextItem(text: "引用内容"),
        imageItem: nil,
        voiceItem: nil,
        fileItem: nil,
        videoItem: nil
    )
    let message = WeChatMessage(
        fromUserID: "sender`id",
        contextToken: "must-not-appear",
        groupID: "group-id",
        messageID: "m-1",
        items: [
            WeChatItem(
                type: 1,
                textItem: WeChatTextItem(text: "# 标题\n第二行"),
                reference: WeChatReference(messageItem: quoted)
            ),
            WeChatItem(type: 3, voiceItem: WeChatVoiceItem(
                textItem: WeChatTextItem(text: "语音转写")
            )),
            WeChatItem(type: 2, imageItem: WeChatImageItem(
                aesKey: "00112233445566778899aabbccddeeff",
                media: media
            )),
            WeChatItem(type: 4, fileItem: WeChatFileItem(
                fileName: "../folder\\报告.pdf",
                media: media
            )),
            WeChatItem(type: 5, videoItem: WeChatVideoItem(media: media))
        ]
    )

    try! await archive.archive(message, receivedAt: receivedAt)
    try! await archive.archive(message, receivedAt: receivedAt)

    let day = root.appendingPathComponent("260907", isDirectory: true)
    let log = day.appendingPathComponent("wechat260907.md")
    let markdown = try! String(contentsOf: log, encoding: .utf8)
    expect(fm.fileExists(atPath: day.path), "归档按本机时区创建 yyMMdd 日期目录")
    expect(markdown.components(separatedBy: "## 08:09:10").count - 1 == 2, "每条消息只有一个收到时间标题且既有文件追加")
    expect(markdown.contains("- 会话：群聊"), "Markdown 记录群聊类型")
    expect(markdown.contains("- 发送者：sender\\`id"), "Markdown 记录并转义发送者 iLink ID")
    expect(markdown.contains("> # 标题\n> 第二行"), "多行正文逐行使用 Markdown 引用")
    expect(markdown.contains("**语音转写**") && markdown.contains("> 语音转写"), "语音 ASR 写入 Markdown")
    expect(markdown.contains("**引用消息**") && markdown.contains("引用内容"), "归档一层引用消息")
    expect(markdown.contains("仅收到语音转写"), "无媒体描述时不伪造语音文件")
    expect(!markdown.contains("must-not-appear"), "Markdown 不写入 context_token")

    let names = (try! fm.contentsOfDirectory(atPath: day.path)).sorted()
    expect(names.contains("wechat260907.md"), "每日文件命名为 wechat<yyMMdd>.md")
    expect(names.contains { $0.hasPrefix("080910_123_01_image") && $0.hasSuffix(".jpg") }, "图片按接收时间和两位序号命名")
    expect(names.contains { $0.hasPrefix("080910_123_02_报告") && $0.hasSuffix(".pdf") }, "文件保留清理后的原名和扩展")
    expect(names.contains { $0.contains("_2.") }, "同名附件冲突时追加递增序号且不覆盖")
    let mediaFiles = names.filter { $0 != "wechat260907.md" }
    expect(mediaFiles.count == 6, "两次归档的三类媒体均保留")
    expect(transport.mediaDescriptors.count == 6, "同条消息媒体全部下载")
    expect(
        transport.mediaDescriptors.contains { $0.aesKey == "00112233445566778899aabbccddeeff" },
        "图片优先使用 image_item.aeskey"
    )

    let nextDay = calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 8, hour: 0, minute: 0, second: 1
    ))!
    try! await archive.archive(
        WeChatMessage(fromUserID: "sender", items: [
            WeChatItem(type: 1, textItem: WeChatTextItem(text: "跨日"))
        ]),
        receivedAt: nextDay
    )
    expect(
        fm.fileExists(atPath: root.appendingPathComponent("260908/wechat260908.md").path),
        "跨过本机日期边界后写入新的日期目录与每日文件"
    )

    let failingFS = FailingWeChatFileSystem()
    failingFS.failAppend = true
    let failingArchive = WeChatArchiveService(
        root: root,
        transport: transport,
        fileSystem: failingFS,
        calendarProvider: makeArchiveCalendar
    )
    do {
        try await failingArchive.archive(
            WeChatMessage(fromUserID: "sender", items: [
                WeChatItem(type: 1, textItem: WeChatTextItem(text: "disk"))
            ]),
            receivedAt: receivedAt
        )
        expect(false, "Markdown 追加失败必须向监听器抛错")
    } catch WeChatArchiveError.appendLog {
        expect(true, "Markdown 追加失败必须向监听器抛错")
    } catch {
        expect(false, "Markdown 追加失败分类")
    }

    let rollbackRoot = root.appendingPathComponent("rollback")
    let rollbackFS = FailingWeChatFileSystem()
    rollbackFS.failAppend = true
    let rollbackArchive = WeChatArchiveService(
        root: rollbackRoot,
        transport: transport,
        fileSystem: rollbackFS,
        calendarProvider: makeArchiveCalendar
    )
    do {
        try await rollbackArchive.archive(
            WeChatMessage(fromUserID: "sender", items: [
                WeChatItem(type: 2, imageItem: WeChatImageItem(media: media))
            ]),
            receivedAt: receivedAt
        )
        expect(false, "带附件的 Markdown 失败应抛错")
    } catch {
        let rollbackDay = rollbackRoot.appendingPathComponent("260907")
        let leftovers = (try? fm.contentsOfDirectory(atPath: rollbackDay.path)) ?? []
        expect(leftovers.isEmpty, "Markdown 失败会清理本次已保存附件和临时文件")
    }

    let mediaFailTransport = MockWeChatTransport()
    mediaFailTransport.mediaResult = .failure(TestWeChatError.forced)
    let mediaFailRoot = root.appendingPathComponent("media-fail")
    let mediaFailArchive = WeChatArchiveService(
        root: mediaFailRoot,
        transport: mediaFailTransport,
        calendarProvider: makeArchiveCalendar
    )
    try! await mediaFailArchive.archive(
        WeChatMessage(fromUserID: "sender", items: [
            WeChatItem(type: 2, imageItem: WeChatImageItem(media: media))
        ]),
        receivedAt: receivedAt
    )
    let failedMarkdown = try! String(
        contentsOf: mediaFailRoot
            .appendingPathComponent("260907")
            .appendingPathComponent("wechat260907.md"),
        encoding: .utf8
    )
    expect(failedMarkdown.contains("下载或解密失败"), "媒体失败写入结果后仍可完成消息归档")
}

func testWeChatProtocolContract() async {
    WeChatURLProtocol.reset()
    defer { WeChatURLProtocol.reset() }
    let session = makeWeChatTestSession()
    let client = WeChatILinkClient(session: session, randomUIN: { 42 })
    let updatesJSON = """
    {
      "ret": 0,
      "get_updates_buf": "cursor-next",
      "msgs": [{
        "from_user_id": "user@im.wechat",
        "to_user_id": "bot@im.wechat",
        "context_token": "ctx",
        "group_id": "",
        "message_type": 1,
        "msg_id": "msg-1",
        "create_time": 123,
        "item_list": [
          {"type":1,"text_item":{"text":"hello"}},
          {"type":2,"image_item":{"aeskey":"00112233445566778899aabbccddeeff","media":{"encrypt_query_param":"img"}}},
          {"type":3,"voice_item":{"text_item":{"text":"asr"}}},
          {"type":4,"file_item":{"file_name":"a.pdf","media":{"encrypt_query_param":"file","aes_key":"key"}}},
          {"type":5,"video_item":{"media":{"encrypt_query_param":"video","aes_key":"key"}}}
        ]
      }]
    }
    """
    WeChatURLProtocol.handler = { request in
        switch request.url!.path {
        case "/ilink/bot/get_bot_qrcode":
            return (200, Data(#"{"qrcode":"qr-contract","qrcode_img_content":""}"#.utf8))
        case "/ilink/bot/get_qrcode_status":
            return (200, Data(#"{"status":"confirmed","bot_token":"token","baseurl":"https://ilinkai.weixin.qq.com"}"#.utf8))
        case "/ilink/bot/getupdates":
            return (200, Data(updatesJSON.utf8))
        default:
            return (404, Data())
        }
    }

    let qr = try! await client.fetchQRCode()
    expect(qr.qrcode == "qr-contract", "协议合同：解析 QR 响应")
    let qrRequest = WeChatURLProtocol.requests[0]
    expect(qrRequest.httpMethod == "GET", "协议合同：QR 使用 GET")
    expect(URLComponents(url: qrRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "bot_type", value: "3")
    ) == true, "协议合同：QR 携带 bot_type=3")
    expect(qrRequest.value(forHTTPHeaderField: "AuthorizationType") == "ilink_bot_token", "协议合同：QR 携带 AuthorizationType")
    expect(qrRequest.value(forHTTPHeaderField: "X-WECHAT-UIN") == "NDI=", "协议合同：X-WECHAT-UIN 为随机数字 Base64")
    expect(qrRequest.value(forHTTPHeaderField: "Authorization") == nil, "协议合同：未绑定请求不携带 Bearer")

    let status = try! await client.fetchQRCodeStatus(qrcode: qr.qrcode)
    expect(status.status == "confirmed" && status.botToken == "token", "协议合同：解析扫码确认与 Token")
    let statusRequest = WeChatURLProtocol.requests[1]
    expect(statusRequest.httpMethod == "GET", "协议合同：扫码状态使用 GET")
    expect(statusRequest.url!.query?.contains("qrcode=qr-contract") == true, "协议合同：扫码状态携带 qrcode")

    let credential = WeChatCredential(token: "secret", baseURL: WeChatILinkClient.officialBaseURL)
    let updates = try! await client.getUpdates(credential: credential, cursor: "cursor-old")
    expect(updates.cursor == "cursor-next", "协议合同：解析并返回 get_updates_buf")
    expect(updates.messages.first?.items.map(\.type) == [1, 2, 3, 4, 5], "协议合同：解析 iLink 消息类型 1 至 5")
    expect(updates.messages.first?.items[2].voiceItem?.transcription == "asr", "协议合同：类型 3 解析语音转写")
    let updateRequest = WeChatURLProtocol.requests[2]
    expect(updateRequest.httpMethod == "POST", "协议合同：getupdates 使用 POST")
    expect(updateRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "协议合同：受信任地址携带 Bearer")
    let body = try! JSONSerialization.jsonObject(with: updateRequest.httpBody!) as! [String: Any]
    expect(body["get_updates_buf"] as? String == "cursor-old", "协议合同：getupdates 提交持久游标")
    let baseInfo = body["base_info"] as! [String: Any]
    expect(baseInfo["channel_version"] as? String == "2.0.1", "协议合同：getupdates 提交 channel_version")

    let beforeUntrusted = WeChatURLProtocol.requests.count
    do {
        _ = try await client.getUpdates(
            credential: WeChatCredential(
                token: "must-not-send",
                baseURL: URL(string: "https://attacker.example")!
            ),
            cursor: ""
        )
        expect(false, "不受信任 API 地址必须拒绝")
    } catch WeChatTransportError.untrustedURL {
        expect(true, "不受信任 API 地址必须拒绝")
    } catch {
        expect(false, "不受信任 API 地址错误分类")
    }
    expect(WeChatURLProtocol.requests.count == beforeUntrusted, "拒绝不受信任地址前不发出 Token 请求")

    WeChatURLProtocol.handler = { _ in (401, Data()) }
    do {
        _ = try await client.getUpdates(credential: credential, cursor: "")
        expect(false, "HTTP 401 应分类为授权失效")
    } catch WeChatTransportError.unauthorized {
        expect(true, "HTTP 401 应分类为授权失效")
    } catch {
        expect(false, "HTTP 401 授权错误分类")
    }

    WeChatURLProtocol.handler = { _ in (503, Data()) }
    do {
        _ = try await client.getUpdates(credential: credential, cursor: "")
        expect(false, "HTTP 5xx 应分类为暂时服务故障")
    } catch WeChatTransportError.serverFailure(503) {
        expect(true, "HTTP 5xx 应分类为暂时服务故障")
    } catch {
        expect(false, "HTTP 5xx 错误分类")
    }
}

@MainActor
func testWeChatAssociationAndFaults() async {
    let old = WeChatCredential(
        token: "old-token",
        baseURL: WeChatILinkClient.officialBaseURL
    )

    do {
        let transport = MockWeChatTransport()
        transport.statuses = [.success(WeChatQRCodeStatus(
            status: "expired",
            botToken: nil,
            baseURL: nil
        ))]
        let credentials = MemoryWeChatCredentialStore(old)
        let page = MockWeChatBindingPage()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: page,
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        await service.performBinding()
        expect(service.isBound && credentials.credential == old, "二维码过期不破坏旧绑定")
        expect(page.statuses.last == .expired, "二维码过期更新浏览器状态")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.statuses = [.success(WeChatQRCodeStatus(
            status: "confirmed",
            botToken: "",
            baseURL: "https://ilinkai.weixin.qq.com"
        ))]
        let credentials = MemoryWeChatCredentialStore(old)
        let page = MockWeChatBindingPage()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: page,
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        await service.performBinding()
        expect(credentials.credential == old, "confirmed 空 Token 被拒绝且保留旧绑定")
        expect(page.statuses.contains { if case .failed = $0 { return true }; return false }, "空 Token 在浏览器显示失败")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.statuses = [.success(WeChatQRCodeStatus(
            status: "confirmed",
            botToken: "new-token",
            baseURL: "https://weixin.qq.com.evil.test"
        ))]
        let credentials = MemoryWeChatCredentialStore(old)
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        await service.performBinding()
        expect(credentials.credential == old && credentials.saves.isEmpty, "不受信任 base URL 不写 Keychain")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.statuses = [.success(WeChatQRCodeStatus(
            status: "confirmed",
            botToken: "new-token",
            baseURL: "https://ilinkai.weixin.qq.com"
        ))]
        let credentials = MemoryWeChatCredentialStore(old)
        credentials.saveError = TestWeChatError.forced
        let states = MemoryWeChatStateStore(WeChatReceiveState(cursor: "old-cursor", recentKeys: []))
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: states,
            archiver: MockWeChatArchiver(),
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        await service.performBinding()
        expect(credentials.credential == old, "Keychain 写入失败保留旧绑定")
        expect(states.resetCount == 0, "Keychain 写入失败不重置旧游标")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.statuses = [.success(WeChatQRCodeStatus(
            status: "confirmed",
            botToken: "new-token",
            baseURL: "https://ilinkai.weixin.qq.com"
        ))]
        transport.updates = [.failure(CancellationError())]
        let credentials = MemoryWeChatCredentialStore(old)
        let states = MemoryWeChatStateStore(WeChatReceiveState(cursor: "old-cursor", recentKeys: []))
        states.resetError = TestWeChatError.forced
        let page = MockWeChatBindingPage()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: states,
            archiver: MockWeChatArchiver(),
            pageWriter: page,
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        await service.performBinding()
        expect(credentials.credential == old && service.isBound, "重置接收状态失败时回滚旧 Keychain 凭据")
        expect(credentials.saves == [
            WeChatCredential(token: "new-token", baseURL: WeChatILinkClient.officialBaseURL),
            old
        ], "状态重置失败先写新凭据再原子恢复旧凭据")
        expect(page.statuses.contains { if case .failed = $0 { return true }; return false }, "状态重置失败不宣称绑定成功")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.updates = [
            .failure(WeChatTransportError.serverFailure(503)),
            .failure(URLError(.notConnectedToInternet)),
            .failure(CancellationError())
        ]
        let credentials = MemoryWeChatCredentialStore(old)
        let sleeper = MockWeChatSleeper()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: sleeper
        )
        service.startBoundListener()
        _ = await waitUntil { sleeper.seconds.count >= 2 }
        expect(Array(sleeper.seconds.prefix(2)) == [5, 10], "离线与 5xx 使用 5/10 秒指数退避")
        expect(service.isBound && credentials.deleteCount == 0, "离线与 5xx 保留绑定勾选")
        service.stop()
    }

    do {
        let transport = MockWeChatTransport()
        transport.updates = [.failure(WeChatTransportError.unauthorized)]
        let credentials = MemoryWeChatCredentialStore(old)
        let notifier = MockWeChatNotifier()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: credentials,
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: notifier,
            sleeper: MockWeChatSleeper()
        )
        service.startBoundListener()
        _ = await waitUntil { credentials.deleteCount == 1 }
        expect(!service.isBound && credentials.credential == nil, "HTTP 401/403 清除 Token 并取消勾选")
        expect(notifier.notifications.contains { $0.0 == "微信授权已失效" }, "授权失效通知重新绑定")
        service.stop()
    }

    do {
        let duplicate = WeChatMessage(
            fromUserID: "sender",
            contextToken: "same-context",
            messageID: "m",
            items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "hello"))]
        )
        let transport = MockWeChatTransport()
        transport.updates = [
            .success(WeChatUpdates(messages: [duplicate, duplicate], cursor: "cursor-new")),
            .failure(CancellationError())
        ]
        let states = MemoryWeChatStateStore()
        let archiver = MockWeChatArchiver()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: MemoryWeChatCredentialStore(old),
            stateStore: states,
            archiver: archiver,
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        service.startBoundListener()
        _ = await waitUntil { states.state.cursor == "cursor-new" }
        expect(archiver.messages.count == 1, "同一响应中的重复消息只归档一次")
        expect(states.state.recentKeys.count == 1, "成功归档后持久化去重键")
        expect(states.state.cursor == "cursor-new", "全部消息成功后推进游标")
        service.stop()
    }

    do {
        let message = WeChatMessage(
            fromUserID: "sender",
            contextToken: "disk-fail",
            items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "hello"))]
        )
        let transport = MockWeChatTransport()
        transport.updates = [
            .success(WeChatUpdates(messages: [message], cursor: "must-not-commit")),
            .failure(CancellationError())
        ]
        let states = MemoryWeChatStateStore(WeChatReceiveState(cursor: "cursor-old", recentKeys: []))
        let archiver = MockWeChatArchiver()
        archiver.error = WeChatArchiveError.appendLog
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: MemoryWeChatCredentialStore(old),
            stateStore: states,
            archiver: archiver,
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        service.startBoundListener()
        _ = await waitUntil { transport.updateCursors.count >= 2 }
        expect(states.state.cursor == "cursor-old", "磁盘写入失败不推进 get_updates_buf")
        expect(states.state.recentKeys.isEmpty, "磁盘写入失败不把消息标为已处理")
        expect(transport.updateCursors.first == "cursor-old", "监听启动时从持久化游标恢复")
        service.stop()
    }

    do {
        let message = WeChatMessage(
            fromUserID: "sender",
            contextToken: "state-save-fail",
            items: [WeChatItem(type: 1, textItem: WeChatTextItem(text: "saved archive"))]
        )
        let transport = MockWeChatTransport()
        transport.updates = [
            .success(WeChatUpdates(messages: [message], cursor: "state-must-not-commit")),
            .failure(CancellationError())
        ]
        let states = MemoryWeChatStateStore(WeChatReceiveState(cursor: "state-old", recentKeys: []))
        states.saveError = TestWeChatError.forced
        let archiver = MockWeChatArchiver()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: MemoryWeChatCredentialStore(old),
            stateStore: states,
            archiver: archiver,
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        service.startBoundListener()
        _ = await waitUntil { transport.updateCursors.count >= 2 }
        expect(archiver.messages.count == 1, "状态文件失败前消息归档本身已完成")
        expect(states.state.cursor == "state-old", "状态文件保存失败不推进内存或磁盘游标")
        expect(states.state.recentKeys.isEmpty, "状态文件保存失败不推进内存或磁盘去重集合")
        service.stop()
    }

    do {
        let transport = CancellationAwareWeChatTransport()
        let service = WeChatAssociationService(
            transport: transport,
            credentialStore: MemoryWeChatCredentialStore(old),
            stateStore: MemoryWeChatStateStore(),
            archiver: MockWeChatArchiver(),
            pageWriter: MockWeChatBindingPage(),
            opener: MockWeChatOpener(),
            notifier: MockWeChatNotifier(),
            sleeper: MockWeChatSleeper()
        )
        service.startBoundListener()
        await Task.yield()
        service.stop()
        _ = await waitUntil { transport.didCancel }
        expect(transport.didCancel, "应用退出停止并取消正在等待的长轮询")
    }
}

@MainActor
func testWeChatBindingToArchiveIntegration() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "tocode-wechat-integration-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: root) }
    let transport = MockWeChatTransport()
    transport.statuses = [.success(WeChatQRCodeStatus(
        status: "confirmed",
        botToken: "integration-token",
        baseURL: "https://ilinkai.weixin.qq.com"
    ))]
    let media = WeChatMedia(
        encryptQueryParameter: "encrypted-media",
        aesKey: Data(repeating: 2, count: 16).base64EncodedString()
    )
    let message = WeChatMessage(
        fromUserID: "integration-user@im.wechat",
        contextToken: "integration-context",
        messageID: "integration-message",
        items: [
            WeChatItem(type: 1, textItem: WeChatTextItem(text: "集成文字")),
            WeChatItem(type: 3, voiceItem: WeChatVoiceItem(
                textItem: WeChatTextItem(text: "集成语音转写"),
                media: media
            )),
            WeChatItem(type: 2, imageItem: WeChatImageItem(media: media)),
            WeChatItem(type: 4, fileItem: WeChatFileItem(fileName: "集成文件.dat", media: media)),
            WeChatItem(type: 5, videoItem: WeChatVideoItem(media: media))
        ]
    )
    transport.updates = [
        .success(WeChatUpdates(messages: [message], cursor: "integration-cursor")),
        .failure(CancellationError())
    ]
    transport.mediaResult = .success(Data("decrypted-integration-media".utf8))
    let credentials = MemoryWeChatCredentialStore()
    let states = MemoryWeChatStateStore()
    let page = MockWeChatBindingPage()
    let opener = MockWeChatOpener()
    let notifier = MockWeChatNotifier()
    let archive = WeChatArchiveService(
        root: root,
        transport: transport,
        calendarProvider: makeArchiveCalendar
    )
    let fixedDate = makeArchiveCalendar().date(from: DateComponents(
        year: 2026, month: 9, day: 7, hour: 12, minute: 34, second: 56
    ))!
    let service = WeChatAssociationService(
        transport: transport,
        credentialStore: credentials,
        stateStore: states,
        archiver: archive,
        pageWriter: page,
        opener: opener,
        notifier: notifier,
        sleeper: MockWeChatSleeper(),
        now: { fixedDate },
        archiveRoot: root
    )

    await service.performBinding()
    _ = await waitUntil { states.state.cursor == "integration-cursor" }
    service.stop()

    expect(credentials.credential?.token == "integration-token", "集成：扫码 confirmed 后写入 Keychain 边界")
    expect(states.resetCount == 1, "集成：新绑定重置旧游标")
    expect(transport.updateCredentials.first?.token == "integration-token", "集成：绑定成功后自动启动长轮询")
    expect(page.statuses.last == .success, "集成：浏览器页面显示绑定成功")
    expect(opener.urls.first == page.url, "集成：使用默认浏览器打开绑定页面")
    expect(notifier.notifications.contains { $0.0 == "微信绑定成功" }, "集成：绑定成功发送本地通知")

    let day = root.appendingPathComponent("260907")
    let markdown = try? String(
        contentsOf: day.appendingPathComponent("wechat260907.md"),
        encoding: .utf8
    )
    expect(markdown?.contains("集成文字") == true, "集成：文字实时追加到每日 Markdown")
    expect(markdown?.contains("集成语音转写") == true, "集成：语音转写归档")
    let files = (try? fm.contentsOfDirectory(atPath: day.path)) ?? []
    expect(files.count == 5, "集成：Markdown 与语音/图片/文件/视频四类媒体落盘")
    expect(transport.mediaDescriptors.count == 4, "集成：下载四类实际提供的媒体")
    expect(states.state.recentKeys.count == 1, "集成：归档成功后保存去重键")
}

@main
struct TestRunnerMain {
    static func main() async {
        testFileSystemService()
        testRootPathStore()
        testClipboardService()
        testCodexProjectService()
        testCodexSyncSettingsStore()
        testCodexModelTOMLAndCatalog()
        testCodexModelSwitchIntegrationAndFaults()
        testCodexApplicationRestarter()
        testFinderVisibilityService()
        testFinderSelectionService()
        testShortcutSettingsStoreDefaults()
        testShortcutEventClassification()
        testFinderMoveStateMachine()
        testDoubleCommandQStateMachine()
        testShortcutServiceLifecycleAndFaults()
        testFinderCutProbeAndQuitEffects()
        testShortcutMenuAppearance()
        testFinderCommandQStateMachine()
        testCommandQTargetResolver()
        testFinderDismissServiceFaults()
        testFinderDismissHideTransientResult()
        testFinderCommandQServiceEffects()
        testLaunchAtLoginService()
        testMouseWheelReverse()
        testScreenBlackoutService()
        testWeChatModelsCryptoAndState()
        testWeChatArchiveNaming()
        testWeChatBindingPage()
        await testWeChatArchive()
        await testWeChatProtocolContract()
        await testWeChatAssociationAndFaults()
        await testWeChatBindingToArchiveIntegration()

        if failures == 0 {
            print("\nALL TESTS PASSED")
        } else {
            print("\n\(failures) TEST(S) FAILED")
            exit(1)
        }
    }
}
