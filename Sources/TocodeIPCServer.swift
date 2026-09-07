import Foundation
import Network

/// 常驻进程内的 IPC server：监听本机 Unix domain socket，处理单行 JSON 请求。
final class TocodeIPCServer {
    private let path: String
    private let executor: TocodeCommandExecutor
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.tocode.ipc.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init(
        executor: TocodeCommandExecutor,
        path: String = TocodeIPCSocket.path(),
        fileManager: FileManager = .default
    ) {
        self.executor = executor
        self.path = path
        self.fileManager = fileManager
    }

    func start() throws {
        stop()

        let directory = (path as NSString).deletingLastPathComponent
        try fileManager.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        // 清理上一次退出遗留的陈旧 socket 文件。
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.applySocketPermissions()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let snapshot = lock.withLock { () -> [NWConnection] in
            let values = connections
            connections.removeAll()
            return values
        }
        for connection in snapshot {
            connection.cancel()
        }
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private func applySocketPermissions() {
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: path
        )
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.remove(connection)
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, receiveError in
            guard let self else { return }
            if receiveError != nil {
                self.remove(connection)
                return
            }
            if let data, !data.isEmpty {
                self.handle(data: data, on: connection)
            }
            if isComplete {
                self.remove(connection)
                return
            }
            self.receive(on: connection)
        }
    }

    private func handle(data: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(TocodeIPCRequest.self, from: data) else {
            send(
                TocodeIPCResponse(id: "", ok: false, data: nil, error: "无效请求"),
                on: connection
            )
            return
        }

        let parsed = TocodeCommandParser.parse([request.command] + request.args)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: TocodeCommandResult
            switch parsed {
            case .success(let command):
                result = self.executor.execute(command)
            case .failure(let parseError):
                result = .failure(parseError)
            }
            let response: TocodeIPCResponse
            switch result {
            case .success(let output):
                response = TocodeIPCResponse(id: request.id, ok: true, data: output.text, error: nil)
            case .failure(let commandError):
                response = TocodeIPCResponse(id: request.id, ok: false, data: nil, error: commandError.message)
            }
            self.send(response, on: connection)
        }
    }

    private func send(_ response: TocodeIPCResponse, on connection: NWConnection) {
        do {
            var payload = try JSONEncoder().encode(response)
            payload.append(TocodeIPCFraming.newline)
            connection.send(
                content: payload,
                completion: .contentProcessed { [weak self] _ in
                    _ = self
                }
            )
        } catch {
            remove(connection)
        }
    }

    private func remove(_ connection: NWConnection) {
        lock.withLock {
            connections.removeAll { $0 === connection }
        }
        connection.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
