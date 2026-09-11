import Foundation
import SQLite3

/// Synthetic credentials only. These tests never write to the user's home or make network calls.
private final class AnkerFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tocode-anker-test-\(UUID().uuidString)")
    let oldKey = "fixture-old-key"
    let newKey = "fixture-new-key"
    let template = "model_provider = \"custom\"\nmodel = \"v_model/gpt-6-astra\"\n[model_providers.custom]\nbase_url = \"https://ai-router.anker-in.com/v1\"\nwire_api = \"responses\"\nexperimental_bearer_token = \"fixture-old-key\" # preserve comment\n"
    let paths = [".config/opencode/opencode.json", ".pi/agent/models.json", ".pi/agent/auth.json", ".local/share/opencode/auth.json", ".hermes/.env", ".hermes/config.yaml", ".hermes/auth.json", ".codex/config.toml", ".cc-switch/settings.json"]

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try json(".config/opencode/opencode.json", ["model": "anker/current-model", "provider": [
            "anker": ["npm": "@ai-sdk/openai-compatible", "options": ["baseURL": AnkerCredentialService.endpoint, "apiKey": oldKey], "models": ["fixture-model": ["name": "Fixture"]]],
            "other": ["options": ["apiKey": "unrelated-key"]]
        ]])
        try json(".pi/agent/models.json", ["providers": ["anker": ["baseUrl": AnkerCredentialService.endpoint, "api": "openai-completions", "apiKey": "!node /fixture/anker-auth.cjs", "authHeader": true, "models": [["id": "fixture-model", "name": "Fixture"]]], "other": ["apiKey": "unrelated-key"]]])
        try json(".pi/agent/auth.json", ["anker": ["type": "api_key", "key": oldKey], "other": ["type": "api_key", "key": "unrelated-key"]])
        try json(".local/share/opencode/auth.json", ["anker": ["type": "api", "key": oldKey]])
        try text(".hermes/.env", "# Existing settings\nDEEPSEEK_API_KEY=unrelated-key\nWEIXIN_TOKEN=fixture-wechat-token\nTERMINAL_TIMEOUT=60\n")
        try text(".hermes/config.yaml", "model:\n  default: deepseek-v4-pro\n  provider: deepseek\n  base_url: ''\n# agent settings\nagent:\n  max_turns: 90\n")
        try json(".hermes/auth.json", ["credential_pool": ["deepseek": ["fixture": true]], "providers": [:]])
        try text(".codex/config.toml", template.replacingOccurrences(of: AnkerCredentialService.endpoint, with: "http://127.0.0.1:15721/v1").replacingOccurrences(of: oldKey, with: "local-proxy-token"))
        try json(".cc-switch/settings.json", ["currentProviderCodex": "anker-provider", "unrelated": true])
        try withDB { db in
            try sql(db, "CREATE TABLE providers(id TEXT, app_type TEXT, name TEXT, settings_config TEXT, is_current INTEGER)")
            try sql(db, "CREATE TABLE proxy_live_backup(app_type TEXT, original_config TEXT, backed_up_at TEXT)")
            try sql(db, "CREATE TABLE proxy_config(app_type TEXT, listen_port INTEGER, enabled INTEGER, auto_failover_enabled INTEGER)")
            let provider = String(decoding: try JSONSerialization.data(withJSONObject: ["config": template, "auth": ["OPENAI_API_KEY": oldKey, "unrelated": "retain"], "extra": 42]), as: UTF8.self)
            try sql(db, "INSERT INTO providers VALUES ('anker-provider','codex','Anker AI Router',?,1)", [provider])
            try sql(db, "INSERT INTO providers VALUES ('other-provider','codex','Other',?,0)", [provider])
            try sql(db, "INSERT INTO proxy_live_backup VALUES ('codex',?,'original-date')", [provider])
            try sql(db, "INSERT INTO proxy_config VALUES ('codex',15721,1,0)")
        }
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func text(_ path: String, _ value: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    func json(_ path: String, _ value: [String: Any]) throws {
        try text(path, String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }

    func contents(_ path: String) throws -> String { try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }
    func object(_ path: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(path))) as! [String: Any] }
    func snapshot() throws -> [String: Data] { try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: home.appendingPathComponent($0))) }) }

    func withDB<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent(".cc-switch/cc-switch.db").path, &pointer) == SQLITE_OK, let pointer else { throw AnkerCredentialError.database }
        defer { sqlite3_close(pointer) }
        return try action(pointer)
    }

    func sql(_ db: OpaquePointer, _ query: String, _ values: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw AnkerCredentialError.database }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnkerCredentialError.database }
    }

    func row(_ query: String) throws -> String {
        try withDB { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw AnkerCredentialError.database }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw AnkerCredentialError.database }
            return String(cString: text)
        }
    }

    func currentKey() throws -> String {
        try row("SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE is_current=1")
    }
}

func testAnkerCredentialSynchronization() {
    do {
        let fixture = try AnkerFixture()
        let before = try fixture.snapshot()
        let service = AnkerCredentialService(home: fixture.home)
        try service.validateConfiguration()
        expect(try fixture.snapshot() == before, "安克只读预检不修改任何文件")
        try service.update("  \(fixture.newKey)\n")
        let opencode = try fixture.object(".config/opencode/opencode.json")
        let ocProviders = opencode["provider"] as! [String: Any]
        let ocAnker = ocProviders["anker"] as! [String: Any]
        expect((ocAnker["options"] as! [String: Any])["apiKey"] as? String == fixture.newKey, "OpenCode 安克密钥已更新")
        expect(opencode["model"] as? String == "anker/current-model", "OpenCode 原模型保持不变")
        let other = ocProviders["other"] as! [String: Any]
        expect((other["options"] as! [String: Any])["apiKey"] as? String == "unrelated-key", "其他服务商凭据保持不变")
        let pi = (try fixture.object(".pi/agent/models.json"))["providers"] as! [String: Any]
        let piKeySource = (pi["anker"] as! [String: Any])["apiKey"] as? String ?? ""
        expect(piKeySource.hasPrefix("!/usr/bin/plutil -extract provider.anker.options.apiKey") && !piKeySource.contains(fixture.newKey), "pi 每次请求从统一来源读取新密钥")
        let readKey = Process()
        readKey.executableURL = URL(fileURLWithPath: "/bin/sh")
        readKey.arguments = ["-c", String(piKeySource.dropFirst())]
        let output = Pipe(); readKey.standardOutput = output; readKey.standardError = Pipe()
        try readKey.run()
        let resolvedKey = output.fileHandleForReading.readDataToEndOfFile()
        readKey.waitUntilExit()
        expect(readKey.terminationStatus == 0 && String(decoding: resolvedKey, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == fixture.newKey, "pi 动态凭据命令真实读取同步后的密钥")
        for path in [".pi/agent/auth.json", ".local/share/opencode/auth.json"] {
            expect(((try fixture.object(path))["anker"] as! [String: Any])["key"] as? String == fixture.newKey, "同步已有的 Anker 认证覆盖项")
        }
        expect(try fixture.currentKey() == fixture.newKey, "CC Switch 当前 Provider 使用新密钥")
        expect(try fixture.row("SELECT json_extract(original_config, '$.auth.OPENAI_API_KEY') FROM proxy_live_backup") == fixture.newKey, "CC Switch 恢复备份同步，停用代理不恢复旧密钥")
        expect(try fixture.row("SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE is_current=0") == fixture.oldKey, "CC Switch 非当前 Provider 不修改")
        let expectedTemplate = fixture.template.replacingOccurrences(of: fixture.oldKey, with: fixture.newKey)
        expect(try fixture.row("SELECT json_extract(settings_config, '$.config') FROM providers WHERE is_current=1") == expectedTemplate, "CC Switch 模板仅更新嵌入密钥，模型、网关和注释保持原样")
        expect(try fixture.row("SELECT json_extract(original_config, '$.config') FROM proxy_live_backup") == expectedTemplate, "CC Switch 恢复模板内的密钥同步更新")
        expect(try fixture.row("SELECT backed_up_at FROM proxy_live_backup") == "original-date", "恢复备份其他字段保持不变")
        let env = try fixture.contents(".hermes/.env")
        expect(env.contains("ANKER_API_KEY=\(fixture.newKey)\n") && env.contains("WEIXIN_TOKEN=fixture-wechat-token\n"), "Hermes 新密钥保存且微信配置不变")
        let yaml = try fixture.contents(".hermes/config.yaml")
        expect(yaml.contains("default: \(AnkerCredentialService.hermesModel)") && yaml.contains("provider: custom") && yaml.contains(AnkerCredentialService.endpoint), "Hermes 接入安克 DeepSeek V4 Pro")
        expect(yaml.contains("api_key: \"${ANKER_API_KEY}\"") && !yaml.contains(fixture.newKey) && yaml.contains("agent:\n  max_turns: 90"), "Hermes 配置引用环境变量且其他设置保留")
        let after = try fixture.snapshot()
        for path in [".codex/config.toml", ".cc-switch/settings.json", ".hermes/auth.json"] {
            expect(after[path] == before[path], "本地代理令牌、服务商选择和无关认证数据不变")
        }
        for path in fixture.paths where after[path] != before[path] {
            let mode = try FileManager.default.attributesOfItem(atPath: fixture.home.appendingPathComponent(path).path)[.posixPermissions] as! NSNumber
            expect(mode.intValue & 0o777 == 0o600, "更新后的凭据文件仅当前用户可读写")
        }
        try service.update(fixture.newKey)
        expect(try fixture.snapshot() == after, "重复保存相同密钥具有幂等性")
    } catch { expect(false, "安克同步测试意外失败（错误内容不输出）") }
}

func testAnkerCredentialFailures() {
    do {
        let invalid = ["", "  ", "Bearer fixture", "fixture\ninjection", "fixture\tkey", "fixture\u{0000}key", "$(command)", "${ENV}", "\"quote\"", String(repeating: "a", count: 4097)]
        for value in invalid {
            expect((try? AnkerCredentialService.normalizedKey(value)) == nil, "拒绝无效密钥而不回显输入")
        }
        // Fail before and after each file replacement; SQLite and all already-written files recover.
        for failAt in 1...6 {
            for afterWrite in [false, true] {
                let fixture = try AnkerFixture()
                let before = try fixture.snapshot()
                var writes = 0
                let service = AnkerCredentialService(home: fixture.home, writer: { data, url in
                    writes += 1
                    if writes == failAt && !afterWrite { throw AnkerCredentialError.writeFailed }
                    try AnkerCredentialService.atomicWrite(data, to: url)
                    if writes == failAt && afterWrite { throw AnkerCredentialError.writeFailed }
                })
                do { try service.update(fixture.newKey); expect(false, "写入故障必须返回错误") }
                catch { expect(!(error is CocoaError), "对外错误不包含底层文件内容") }
                expect(try fixture.snapshot() == before && fixture.currentKey() == fixture.oldKey, "任一文件写入前后失败均恢复全部文件及数据库")
            }
        }
        let fixture = try AnkerFixture()
        let before = try fixture.snapshot()
        let service = AnkerCredentialService(home: fixture.home, beforeCommit: { throw AnkerCredentialError.database })
        do { try service.update(fixture.newKey); expect(false, "提交故障必须返回错误") } catch {}
        expect(try fixture.snapshot() == before && fixture.currentKey() == fixture.oldKey, "数据库提交前失败恢复所有配置")

        let concurrent = try AnkerFixture()
        let conflict = AnkerCredentialService(home: concurrent.home, beforeCommit: {
            try concurrent.text(".config/opencode/opencode.json", "external-edit")
        })
        do { try conflict.update(concurrent.newKey); expect(false, "并发修改必须失败") }
        catch { expect((error as? AnkerCredentialError)?.localizedDescription == AnkerCredentialError.recoveryFailed.localizedDescription, "无法安全恢复时明确报告部分配置不一致") }
        expect(try concurrent.contents(".config/opencode/opencode.json") == "external-edit", "不覆盖其他进程并发修改")
        expect(try concurrent.currentKey() == concurrent.oldKey, "并发修改仍回滚数据库")

        let rollback = try AnkerFixture()
        var writes = 0
        let broken = AnkerCredentialService(home: rollback.home, writer: { data, url in
            writes += 1
            if writes >= 2 { throw AnkerCredentialError.writeFailed }
            try AnkerCredentialService.atomicWrite(data, to: url)
        })
        do { try broken.update(rollback.newKey); expect(false, "回滚故障必须失败") }
        catch { expect((error as? AnkerCredentialError)?.localizedDescription == AnkerCredentialError.recoveryFailed.localizedDescription, "回滚写入故障不能伪装成功") }
    } catch { expect(false, "安克故障测试意外失败（错误内容不输出）") }
}

func testAnkerConfigurationGuards() {
    let mutations: [(String, (AnkerFixture) throws -> Void)] = [
        ("缺失配置", { try FileManager.default.removeItem(at: $0.home.appendingPathComponent(".hermes/config.yaml")) }),
        ("重复环境变量", { try $0.text(".hermes/.env", "ANKER_API_KEY=one\nexport ANKER_API_KEY=two\n") }),
        ("重复模型字段", { try $0.text(".hermes/config.yaml", "model:\n  default: old\n  provider: deepseek\n  provider: custom\n  base_url: ''\n") }),
        ("重复根模型块", { try $0.text(".hermes/config.yaml", "model:\n  default: old\n  provider: deepseek\n  base_url: ''\nmodel: {provider: other}\n") }),
        ("非安克 Hermes 路由", { try $0.text(".hermes/config.yaml", "model:\n  default: old\n  provider: custom\n  base_url: https://other.example/v1\n") }),
        ("Hermes 凭据池覆盖", { try $0.json(".hermes/auth.json", ["credential_pool": ["custom:anker": ["credential": "fixture"]]]) }),
        ("pi OAuth 覆盖", { try $0.json(".pi/agent/auth.json", ["anker": ["type": "oauth", "access": "fixture"]]) }),
        ("非安克 OpenCode 网关", { try $0.json(".config/opencode/opencode.json", ["provider": ["anker": ["options": ["baseURL": "https://ai-router.anker-in.com.attacker.example/v1"]]]]) }),
        ("服务商选择不一致", { try $0.json(".cc-switch/settings.json", ["currentProviderCodex": "other-provider"]) }),
        ("重复当前 Provider", { f in try f.withDB { try f.sql($0, "UPDATE providers SET is_current=1") } }),
        ("自动故障转移启用", { f in try f.withDB { try f.sql($0, "UPDATE proxy_config SET auto_failover_enabled=1") } }),
        ("CC Switch 环境密钥覆盖", { f in try f.withDB { try f.sql($0, "UPDATE providers SET settings_config=json_set(settings_config, '$.env.OPENAI_API_KEY', 'fixture-env') WHERE is_current=1") } }),
        ("当前模板不是安克", { f in
            let value = String(decoding: try JSONSerialization.data(withJSONObject: ["auth": ["OPENAI_API_KEY": "fixture"], "config": f.template.replacingOccurrences(of: AnkerCredentialService.endpoint, with: "https://other.example/v1") + "# ai-router.anker-in.com\n"]), as: UTF8.self)
            try f.withDB { try f.sql($0, "UPDATE providers SET settings_config=? WHERE is_current=1", [value]) }
        }),
        ("实时 Codex 未接代理", { f in try f.text(".codex/config.toml", f.template) }),
        ("畸形恢复备份", { f in try f.withDB { try f.sql($0, "UPDATE proxy_live_backup SET original_config='{}'") } }),
        ("符号链接凭据文件", { f in
            let source = f.home.appendingPathComponent(".hermes/.env")
            let other = f.home.appendingPathComponent("external-env")
            try FileManager.default.moveItem(at: source, to: other)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        })
    ]
    for (label, mutate) in mutations {
        do {
            let fixture = try AnkerFixture()
            try mutate(fixture)
            let original = try fixture.currentKey()
            var writes = 0
            let service = AnkerCredentialService(home: fixture.home, writer: { _, _ in writes += 1 })
            do { try service.update(fixture.newKey); expect(false, "\(label) 必须拒绝保存") }
            catch { expect(writes == 0, "\(label) 在任何写入前拒绝") }
            expect(try fixture.currentKey() == original, "\(label) 不改变数据库凭据")
        } catch { expect(false, "配置保护夹具构建失败：\(label)") }
    }
    do {
        let template = "model_provider = \"custom\"\n[model_providers.other]\nbase_url = \"https://other.example/v1\"\nexperimental_bearer_token = \"unrelated\"\n[model_providers.custom]\nbase_url = \"https://ai-router.anker-in.com/v1\"\nexperimental_bearer_token = 'old' # keep\n"
        let updated = try AnkerCredentialService.rotateEmbeddedBearer(template, key: "fixture-new")
        expect(updated.contains("experimental_bearer_token = \"unrelated\"") && updated.contains("experimental_bearer_token = \"fixture-new\" # keep"), "仅更新实际选中 Provider 的模板凭据")
        expect((try? AnkerCredentialService.rotateEmbeddedBearer(template + "env_key = \"OVERRIDE\"\n", key: "fixture-new")) == nil, "拒绝模板中的环境凭据覆盖")
        let fixture = try AnkerFixture()
        try fixture.json(".pi/agent/auth.json", [:])
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".local/share/opencode/auth.json"))
        try fixture.withDB { try fixture.sql($0, "DELETE FROM proxy_live_backup") }
        try AnkerCredentialService(home: fixture.home).update(fixture.newKey)
        expect(try fixture.currentKey() == fixture.newKey, "认证覆盖项和恢复备份不存在时仍能更新")
        expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".local/share/opencode/auth.json").path), "不创建多余的 OpenCode 认证文件")
    } catch { expect(false, "可选配置测试意外失败") }
}
