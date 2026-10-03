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
                "input": ["text"],
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
            modelsFile: models
        )
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
