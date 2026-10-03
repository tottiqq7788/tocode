import Foundation

protocol TogentRuntimeExecuting: AnyObject {
    func execute(role: TogentRole, prompt: String) async throws -> String
    func stop(roleID: UUID) async
    func stopAll() async
}

actor TogentRuntimeService: TogentRuntimeExecuting {
    private struct Signature: Equatable {
        let workspacePath: String
        let modelID: String
        let relayBaseURL: String
    }

    private final class Entry {
        let signature: Signature
        let client: TogentRPCClient
        let broker: TogentGitBroker

        init(signature: Signature, client: TogentRPCClient, broker: TogentGitBroker) {
            self.signature = signature
            self.client = client
            self.broker = broker
        }

        func stop() {
            client.stop()
            broker.stop()
        }
    }

    private let relayAccess: @Sendable () -> TogentRelayAccess
    private let runtimeDirectory: URL
    private let sandboxExecutable: URL
    private let sandbox: TogentSandbox
    private let fileManager: FileManager
    private var entries: [UUID: Entry] = [:]

    init(
        relayAccess: @escaping @Sendable () -> TogentRelayAccess,
        runtimeDirectory: URL? = nil,
        sandboxExecutable: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        sandbox: TogentSandbox = TogentSandbox(),
        fileManager: FileManager = .default
    ) {
        self.relayAccess = relayAccess
        self.runtimeDirectory = runtimeDirectory
            ?? Bundle.main.resourceURL!.appendingPathComponent("Togent", isDirectory: true)
        self.sandboxExecutable = sandboxExecutable
        self.sandbox = sandbox
        self.fileManager = fileManager
    }

    func execute(role: TogentRole, prompt: String) async throws -> String {
        guard !role.publishedModelID.isEmpty else {
            await stop(roleID: role.id)
            throw TogentError.modelNotConfigured
        }
        let access = relayAccess()
        guard access.models.contains(where: {
            $0.publishedModelID == role.publishedModelID
        }) else {
            await stop(roleID: role.id)
            throw TogentError.modelUnavailable
        }
        let signature = Signature(
            workspacePath: role.workspacePath,
            modelID: role.publishedModelID,
            relayBaseURL: access.baseURL
        )
        let entry: Entry
        if let existing = entries[role.id], existing.signature == signature {
            entry = existing
        } else {
            await stop(roleID: role.id)
            entry = try await startEntry(role: role, access: access, signature: signature)
            entries[role.id] = entry
        }
        do {
            return try await entry.client.promptAndWait(prompt)
        } catch {
            entry.stop()
            entries.removeValue(forKey: role.id)
            throw error
        }
    }

    func stop(roleID: UUID) async {
        entries.removeValue(forKey: roleID)?.stop()
    }

    func stopAll() async {
        let values = Array(entries.values)
        entries.removeAll()
        values.forEach { $0.stop() }
    }

    private func startEntry(
        role: TogentRole,
        access: TogentRelayAccess,
        signature: Signature
    ) async throws -> Entry {
        let pi = runtimeDirectory.appendingPathComponent("pi")
        guard fileManager.isExecutableFile(atPath: pi.path),
              fileManager.isExecutableFile(atPath: sandboxExecutable.path) else {
            throw TogentError.runtimeMissing
        }
        let workspace = URL(fileURLWithPath: role.workspacePath, isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TogentError.workspace("角色 project 文件夹不存在")
        }

        let layout: TogentRuntimeLayout
        do {
            layout = try sandbox.prepare(
                role: role,
                bundledRuntime: runtimeDirectory,
                relayAccess: access
            )
            try fileManager.createDirectory(
                at: URL(
                    fileURLWithPath: TogentSandbox.safeEnvironment(
                        layout: layout,
                        relayToken: access.bearerToken
                    )["HOME"]!
                ),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch let error as TogentError {
            throw error
        } catch {
            throw TogentError.workspace(error.localizedDescription)
        }

        var lastError: Error?
        for attempt in 0..<3 {
            let broker = TogentGitBroker(socketURL: layout.gitSocket, projectRoot: project)
            do {
                try broker.start()
                let piArguments = [
                    "--mode", "rpc",
                    "--provider", "tocode",
                    "--model", role.publishedModelID,
                    "--session-dir", layout.sessions.path,
                    "--continue",
                    "--no-approve",
                    "--no-extensions",
                    "--no-skills",
                    "--no-prompt-templates",
                    "--no-themes",
                    "--offline"
                ]
                let arguments = [
                    "-f", layout.sandboxProfile.path,
                    "/bin/sh", "-c", "umask 077; exec \"$@\"", "togent-pi",
                    pi.path
                ] + piArguments
                let client = TogentRPCClient(
                    executableURL: sandboxExecutable,
                    arguments: arguments,
                    environment: TogentSandbox.safeEnvironment(
                        layout: layout,
                        relayToken: access.bearerToken
                    ),
                    workingDirectory: workspace
                )
                try client.start()
                return Entry(signature: signature, client: client, broker: broker)
            } catch {
                broker.stop()
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(1 << attempt) * 1_000_000_000
                    )
                }
            }
        }
        throw lastError ?? TogentError.runtimeLaunch("未知启动失败")
    }
}
