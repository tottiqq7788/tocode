import Foundation
import Darwin

struct TogentRuntimeLayout: Equatable {
    let roleRoot: URL
    let sessions: URL
    let agentDirectory: URL
    let temporaryDirectory: URL
    let binDirectory: URL
    let sandboxProfile: URL
    let gitSocket: URL
    let modelsFile: URL
    let settingsFile: URL
}

final class TogentSandbox {
    private let fileManager: FileManager
    private let applicationSupportRoot: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.applicationSupportRoot = applicationSupportRoot ?? home
            .appendingPathComponent(
                "Library/Application Support/com.tocode.app/togent/roles",
                isDirectory: true
            )
    }

    func prepare(
        role: TogentRole,
        bundledRuntime: URL,
        relayAccess: TogentRelayAccess
    ) throws -> TogentRuntimeLayout {
        let roleRoot = applicationSupportRoot
            .appendingPathComponent(role.id.uuidString, isDirectory: true)
        let sessions = roleRoot.appendingPathComponent("sessions", isDirectory: true)
        let agent = roleRoot.appendingPathComponent("agent", isDirectory: true)
        let temporary = roleRoot.appendingPathComponent("tmp", isDirectory: true)
        let bin = roleRoot.appendingPathComponent("bin", isDirectory: true)
        let profile = roleRoot.appendingPathComponent("sandbox.sb")
        // Darwin 的 sockaddr_un.sun_path 很短；Application Support + UUID 会超限。
        let socket = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "tocode-tg-\(role.id.uuidString.prefix(12)).sock"
            )
        let models = agent.appendingPathComponent("models.json")
        let settings = agent.appendingPathComponent("settings.json")

        for directory in [roleRoot, sessions, agent, temporary, bin] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }

        let modelEntries = relayAccess.models.map { option in
            [
                "id": option.publishedModelID,
                "name": option.displayName,
                "reasoning": false,
                "input": option.imageInput == .multimodal
                    ? ["text", "image"]
                    : ["text"],
                "contextWindow": 128_000,
                "maxTokens": 16_384
            ] as [String: Any]
        }
        let modelConfiguration: [String: Any] = [
            "providers": [
                "tocode": [
                    "baseUrl": relayAccess.baseURL,
                    "api": "openai-completions",
                    "apiKey": "${TOGENT_RELAY_KEY}",
                    "models": modelEntries
                ] as [String: Any]
            ]
        ]
        let modelData = try JSONSerialization.data(
            withJSONObject: modelConfiguration,
            options: [.prettyPrinted, .sortedKeys]
        )
        try modelData.write(to: models, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: models.path
        )
        // 受管单文件运行时无法可靠加载 Pi 的图片缩放 worker；关闭自动缩放可避免
        // read 工具把已归档的有效图片静默降级成纯文本错误。原图仍只在角色归档内读取。
        let settingsData = try JSONSerialization.data(
            withJSONObject: ["images": ["autoResize": false]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try settingsData.write(to: settings, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: settings.path
        )

        let gitHelper = bin.appendingPathComponent("togent-git")
        try Data(Self.gitHelperScript.utf8).write(to: gitHelper, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: gitHelper.path
        )

        let sandboxText = profileText(
            workspace: URL(fileURLWithPath: role.workspacePath, isDirectory: true),
            runtimeRoot: roleRoot,
            bundledRuntime: bundledRuntime
        )
        try Data(sandboxText.utf8).write(to: profile, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: profile.path
        )

        return TogentRuntimeLayout(
            roleRoot: roleRoot,
            sessions: sessions,
            agentDirectory: agent,
            temporaryDirectory: temporary,
            binDirectory: bin,
            sandboxProfile: profile,
            gitSocket: socket,
            modelsFile: models,
            settingsFile: settings
        )
    }

    func redactPersistedSessionImages(in sessions: URL) throws {
        let managedRoot = applicationSupportRoot.standardizedFileURL
        let requested = sessions.standardizedFileURL
        let roleRoot = requested.deletingLastPathComponent()
        guard requested.lastPathComponent == "sessions",
              roleRoot.deletingLastPathComponent() == managedRoot,
              UUID(uuidString: roleRoot.lastPathComponent) != nil else {
            throw TogentError.runtimeLaunch("Pi 会话目录不属于受管角色边界")
        }

        let rootFD = try Self.openDirectory(path: managedRoot.path)
        defer { Darwin.close(rootFD) }
        let roleFD = try Self.openDirectory(
            named: roleRoot.lastPathComponent,
            relativeTo: rootFD
        )
        defer { Darwin.close(roleFD) }
        let sessionsFD = try Self.openDirectory(named: "sessions", relativeTo: roleFD)
        defer { Darwin.close(sessionsFD) }

        for name in try Self.directoryEntryNames(descriptor: sessionsFD)
        where name.lowercased().hasSuffix(".jsonl") {
            let descriptor = name.withCString {
                Darwin.openat(
                    sessionsFD,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if descriptor < 0, errno == ELOOP {
                continue
            }
            guard descriptor >= 0 else {
                throw TogentError.runtimeLaunch("无法安全打开 Pi 会话文件")
            }
            defer { Darwin.close(descriptor) }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            do {
                try Self.redactPersistedSessionImages(descriptor: descriptor)
            } catch {
                throw TogentError.runtimeLaunch(
                    "Pi 会话图片正文脱敏失败：\(error.localizedDescription)"
                )
            }
        }
    }

    private static func openDirectory(path: String) throws -> Int32 {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw TogentError.runtimeLaunch("无法安全打开 Pi 受管会话根目录")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw TogentError.runtimeLaunch("Pi 受管会话根目录不是目录")
        }
        return descriptor
    }

    private static func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TogentError.runtimeLaunch("无法安全打开 Pi 角色会话目录")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw TogentError.runtimeLaunch("Pi 角色会话路径不是目录")
        }
        return descriptor
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw TogentError.runtimeLaunch("无法枚举 Pi 角色会话目录")
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw TogentError.runtimeLaunch("无法枚举 Pi 角色会话目录")
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw TogentError.runtimeLaunch("枚举 Pi 角色会话目录失败")
        }
        return names
    }

    private static func redactPersistedSessionImages(descriptor: Int32) throws {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw TogentError.runtimeLaunch("无法读取 Pi 会话")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw TogentError.runtimeLaunch("无法读取 Pi 会话")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw TogentError.runtimeLaunch("Pi 会话不是 UTF-8 JSONL")
        }
        var changed = false
        let sanitized = try text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map { line -> String in
            guard !line.isEmpty else { return "" }
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let result = redactingImages(in: object)
            changed = changed || result.changed
            guard let value = String(
                data: try JSONSerialization.data(withJSONObject: result.value),
                encoding: .utf8
            ) else {
                throw TogentError.runtimeLaunch("无法编码已脱敏 Pi 会话")
            }
            return value
        }.joined(separator: "\n")
        guard changed else { return }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw TogentError.runtimeLaunch("无法重写已脱敏 Pi 会话")
        }
        let output = Data(sanitized.utf8)
        try output.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw TogentError.runtimeLaunch("无法重写已脱敏 Pi 会话")
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw TogentError.runtimeLaunch("无法同步已脱敏 Pi 会话")
        }
    }

    private static func redactingImages(in value: Any) -> (value: Any, changed: Bool) {
        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "image",
               dictionary["data"] is String {
                return (
                    [
                        "type": "text",
                        "text": "[已从持久会话移除归档图片正文；如仍需识图，请重新读取原工作区相对路径。]"
                    ],
                    true
                )
            }
            var changed = false
            var result: [String: Any] = [:]
            for (key, nested) in dictionary {
                let redacted = redactingImages(in: nested)
                result[key] = redacted.value
                changed = changed || redacted.changed
            }
            return (result, changed)
        }
        if let array = value as? [Any] {
            var changed = false
            let result = array.map { nested -> Any in
                let redacted = redactingImages(in: nested)
                changed = changed || redacted.changed
                return redacted.value
            }
            return (result, changed)
        }
        return (value, false)
    }

    func profileText(
        workspace: URL,
        runtimeRoot: URL,
        bundledRuntime: URL
    ) -> String {
        let fixedReadOnlyRoots = [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/dev",
            "/private/etc",
            "/private/var/db",
            "/Library/Apple",
            "/Library/Developer",
            "/Applications/Xcode.app",
            "/opt/homebrew"
        ]
        let urlReadOnlyRoots = [bundledRuntime, workspace, runtimeRoot]
            .flatMap { [$0.standardizedFileURL.path, Self.canonicalPath($0)] }
        let readOnlyRoots = Array(Set(fixedReadOnlyRoots + urlReadOnlyRoots)).sorted()
        let readRules = readOnlyRoots.map {
            let escaped = Self.escape($0)
            return """
            (allow file-read* (literal "\(escaped)"))
            (allow file-read* (subpath "\(escaped)"))
            """
        }.joined(separator: "\n")
        let writeRoots = Array(Set(
            [workspace, runtimeRoot].flatMap {
                [$0.standardizedFileURL.path, Self.canonicalPath($0)]
            }
        )).sorted()
        let writeRules = writeRoots.map {
            "(allow file-write* (subpath \"\(Self.escape($0))\"))"
        }.joined(separator: "\n")
        let archive = workspace.appendingPathComponent("wechat", isDirectory: true)
        let archiveRoots = Array(Set([
            archive.standardizedFileURL.path,
            Self.canonicalPath(archive)
        ])).sorted()
        let archiveWriteDenials = archiveRoots.map {
            let escaped = Self.escape($0)
            return """
            (deny file-write* (literal "\(escaped)"))
            (deny file-write* (subpath "\(escaped)"))
            """
        }.joined(separator: "\n")

        return """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process*)
        (allow signal (target self))
        (allow sysctl-read)
        (allow network*)
        (allow mach-lookup)
        (deny mach-lookup
            (global-name "com.apple.securityd")
            (global-name "com.apple.securityd.xpc")
            (global-name "com.apple.pboard")
            (global-name "com.apple.pbs"))
        (allow file-read-metadata)
        \(readRules)
        \(writeRules)
        \(archiveWriteDenials)
        (allow file-write* (literal "/dev/null"))
        """
    }

    static func safeEnvironment(
        layout: TogentRuntimeLayout,
        relayToken: String
    ) -> [String: String] {
        [
            "HOME": layout.roleRoot.appendingPathComponent("home", isDirectory: true).path,
            "TMPDIR": layout.temporaryDirectory.path + "/",
            "PI_CODING_AGENT_DIR": layout.agentDirectory.path,
            "TOGENT_RELAY_KEY": relayToken,
            "TOGENT_REDACT_PERSISTED_IMAGES": "1",
            "TOGENT_GIT_SOCKET": layout.gitSocket.path,
            "PATH": [
                layout.binDirectory.path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ].joined(separator: ":"),
            "LANG": "zh_CN.UTF-8",
            "LC_ALL": "zh_CN.UTF-8",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1"
        ]
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(
            atPath: existing.path,
            isDirectory: &isDirectory
        ) {
            suffix.insert(existing.lastPathComponent, at: 0)
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path {
                return url.standardizedFileURL.path
            }
            existing = parent
        }
        guard let pointer = realpath(existing.path, nil) else {
            return url.standardizedFileURL.path
        }
        defer { free(pointer) }
        var resolved = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        // `standardizedFileURL` 会把 `/private/var` 再折叠成 `/var`，而
        // sandbox-exec 按内核解析后的真实路径匹配规则，必须保留 realpath。
        return resolved.path
    }

    private static let gitHelperScript = """
    #!/usr/bin/python3
    import json
    import os
    import socket
    import sys

    if len(sys.argv) < 2:
        print("用法: togent-git clone|fetch|pull|push [参数]", file=sys.stderr)
        sys.exit(2)

    request = {
        "operation": sys.argv[1],
        "repositoryPath": os.getcwd(),
        "arguments": sys.argv[2:],
    }
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(300)
    client.connect(os.environ["TOGENT_GIT_SOCKET"])
    client.sendall(json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\\n")
    data = b""
    while b"\\n" not in data:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    response = json.loads(data.split(b"\\n", 1)[0].decode("utf-8"))
    output = response.get("output") or response.get("error") or ""
    if output:
        print(output)
    sys.exit(0 if response.get("ok") else 1)
    """
}
