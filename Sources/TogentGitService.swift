import Foundation
import Network

private struct TogentGitRequest: Decodable {
    let operation: String
    let repositoryPath: String
    let arguments: [String]
}

private struct TogentGitResponse: Encodable {
    let ok: Bool
    let output: String?
    let error: String?
}

final class TogentGitBroker: @unchecked Sendable {
    private let socketURL: URL
    private let projectRoot: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.tocode.togent.git.listener")
    private let operationQueue = DispatchQueue(label: "com.tocode.togent.git.operations")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (NWConnection, Data)] = [:]

    init(
        socketURL: URL,
        projectRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.socketURL = socketURL
        self.projectRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    func start() throws {
        stop()
        try fileManager.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: socketURL.path) {
            try fileManager.removeItem(at: socketURL)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                try? self?.fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: self?.socketURL.path ?? ""
                )
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let snapshot = lock.withTogentLock { () -> [NWConnection] in
            let values = connections.values.map(\.0)
            connections.removeAll()
            return values
        }
        snapshot.forEach { $0.cancel() }
        if fileManager.fileExists(atPath: socketURL.path) {
            try? fileManager.removeItem(at: socketURL)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withTogentLock {
            connections[ObjectIdentifier(connection)] = (connection, Data())
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .failed = state {
                self?.remove(connection)
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.remove(connection)
                return
            }
            if let data, !data.isEmpty {
                let completeRecord: Data? = self.lock.withTogentLock {
                    let key = ObjectIdentifier(connection)
                    var buffer = self.connections[key]?.1 ?? Data()
                    buffer.append(data)
                    guard buffer.count <= 256 * 1_024 else {
                        self.connections[key] = (connection, Data())
                        return Data()
                    }
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        let record = buffer[..<newline]
                        self.connections[key] = (connection, Data())
                        return Data(record)
                    }
                    self.connections[key] = (connection, buffer)
                    return nil
                }
                if let completeRecord {
                    guard !completeRecord.isEmpty,
                          let request = try? JSONDecoder().decode(
                            TogentGitRequest.self,
                            from: completeRecord
                          ) else {
                        self.send(
                            TogentGitResponse(ok: false, output: nil, error: "无效 Git 请求"),
                            on: connection
                        )
                        return
                    }
                    self.operationQueue.async { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        let response = self.execute(request)
                        self.send(response, on: connection)
                    }
                    return
                }
            }
            if isComplete {
                self.remove(connection)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func execute(_ request: TogentGitRequest) -> TogentGitResponse {
        do {
            let invocation = try validatedInvocation(request)
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = invocation.arguments
            process.currentDirectoryURL = invocation.currentDirectory
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            try process.run()

            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()

            var output = stdout.fileHandleForReading.readDataToEndOfFile()
            output.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let decoded = String(data: output.prefix(128 * 1_024), encoding: .utf8) ?? ""
            let cleaned = Self.sanitize(decoded)
            if process.terminationStatus == 0 {
                return TogentGitResponse(
                    ok: true,
                    output: cleaned.isEmpty ? "Git 操作完成" : cleaned,
                    error: nil
                )
            }
            return TogentGitResponse(
                ok: false,
                output: nil,
                error: cleaned.isEmpty
                    ? "git 退出码 \(process.terminationStatus)"
                    : cleaned
            )
        } catch {
            return TogentGitResponse(
                ok: false,
                output: nil,
                error: error.localizedDescription
            )
        }
    }

    private struct Invocation {
        let currentDirectory: URL
        let arguments: [String]
    }

    private func validatedInvocation(_ request: TogentGitRequest) throws -> Invocation {
        let operation = request.operation.lowercased()
        guard ["clone", "fetch", "pull", "push"].contains(operation) else {
            throw TogentError.gitOperationDenied
        }

        if operation == "clone" {
            guard request.arguments.count == 2 else {
                throw TogentError.gitOperationDenied
            }
            let source = request.arguments[0]
            let destination = request.arguments[1]
            guard Self.safeRemote(source),
                  !destination.hasPrefix("/"),
                  !destination.split(separator: "/").contains("..") else {
                throw TogentError.gitOperationDenied
            }
            let requestedRoot = try canonicalExistingDirectory(request.repositoryPath)
            guard requestedRoot == projectRoot else {
                throw TogentError.workspaceOutsideBoundary
            }
            let target = projectRoot.appendingPathComponent(destination).standardizedFileURL
            try ensureInsideProject(target, allowEqual: false)
            guard !fileManager.fileExists(atPath: target.path) else {
                throw TogentError.gitFailed("clone 目标已存在")
            }
            return Invocation(
                currentDirectory: projectRoot,
                arguments: ["clone", "--", source, target.path]
            )
        }

        guard request.arguments.allSatisfy(Self.safeArgument) else {
            throw TogentError.gitOperationDenied
        }
        let repository = try canonicalExistingDirectory(request.repositoryPath)
        try ensureInsideProject(repository, allowEqual: true)
        let gitMarker = repository.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: gitMarker.path) else {
            throw TogentError.gitFailed("当前目录不是 Git 仓库")
        }

        switch operation {
        case "fetch":
            guard request.arguments.count <= 1 else {
                throw TogentError.gitOperationDenied
            }
        case "pull", "push":
            guard request.arguments.count <= 2 else {
                throw TogentError.gitOperationDenied
            }
        default:
            throw TogentError.gitOperationDenied
        }
        return Invocation(
            currentDirectory: repository,
            arguments: [operation, "--"] + request.arguments
        )
    }

    private func canonicalExistingDirectory(_ raw: String) throws -> URL {
        let url = URL(fileURLWithPath: raw, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TogentError.invalidWorkspacePath
        }
        return url
    }

    private func ensureInsideProject(_ url: URL, allowEqual: Bool) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = projectRoot.path
        if allowEqual, canonical == root {
            return
        }
        guard TogentWorkspaceService.isDescendant(canonical, of: root) else {
            throw TogentError.workspaceOutsideBoundary
        }
    }

    private func send(_ response: TogentGitResponse, on connection: NWConnection) {
        var data = (try? JSONEncoder().encode(response)) ?? Data(
            #"{"ok":false,"error":"响应编码失败"}"#.utf8
        )
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.remove(connection)
        })
    }

    private func remove(_ connection: NWConnection) {
        _ = lock.withTogentLock {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.cancel()
    }

    private static func safeArgument(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.hasPrefix("+"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains(":") else {
            return false
        }
        return true
    }

    private static func safeRemote(_ value: String) -> Bool {
        guard !value.contains("\n"), !value.contains("\r"), !value.hasPrefix("-") else {
            return false
        }
        if let components = URLComponents(string: value),
           let scheme = components.scheme?.lowercased() {
            return ["https", "ssh"].contains(scheme)
                && components.password == nil
        }
        return value.contains("@") && value.contains(":") && !value.contains(" ")
    }

    private static func sanitize(_ raw: String) -> String {
        let pattern = #"(https?://)[^/@\s:]+(?::[^/@\s]*)?@"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let cleaned = expression?.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: "$1***@"
        ) ?? raw
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension NSLock {
    func withTogentLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
