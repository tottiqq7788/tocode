import Foundation
import Network

final class ModelRelayHTTPServer {
    private let router: ModelRelayRouter
    private let upstream: ModelRelayUpstreamClient
    private let queue = DispatchQueue(label: "com.tocode.model-relay.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var handlers: [UUID: ModelRelayHTTPConnection] = [:]
    var stateDidChange: ((ModelRelayRunState) -> Void)?

    init(router: ModelRelayRouter, upstream: ModelRelayUpstreamClient) {
        self.router = router
        self.upstream = upstream
    }

    func start(
        port: UInt16,
        readiness: ((Result<Void, Error>) -> Void)? = nil
    ) throws {
        guard (1024...UInt16.max).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ModelRelayError.invalidPort
        }
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: nwPort
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ModelRelayError.listener(error.localizedDescription)
        }
        let readinessState = ModelRelayListenerReadiness(readiness)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .setup:
                self.stateDidChange?(.starting)
            case .waiting(let error):
                let relayError = ModelRelayError.listener(error.localizedDescription)
                self.listener = nil
                self.stateDidChange?(.failed(error.localizedDescription))
                readinessState.resolve(.failure(relayError))
                listener.cancel()
            case .ready:
                self.stateDidChange?(.running(port: port))
                readinessState.resolve(.success(()))
            case .failed(let error):
                self.listener = nil
                self.stateDidChange?(.failed(error.localizedDescription))
                readinessState.resolve(.failure(ModelRelayError.listener(error.localizedDescription)))
                listener.cancel()
            case .cancelled:
                self.stateDidChange?(.stopped)
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        stateDidChange?(.starting)
        listener.start(queue: queue)
    }

    func stop() {
        let listener = self.listener
        self.listener = nil
        listener?.cancel()
        lock.lock()
        let current = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
        if listener != nil {
            stateDidChange?(.stopped)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let handler = ModelRelayHTTPConnection(
            connection: connection,
            router: router,
            upstream: upstream
        ) { [weak self] in
            self?.lock.lock()
            self?.handlers.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        handler.start(queue: queue)
    }
}

private final class ModelRelayListenerReadiness {
    private let lock = NSLock()
    private var completion: ((Result<Void, Error>) -> Void)?

    init(_ completion: ((Result<Void, Error>) -> Void)?) {
        self.completion = completion
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }
}

private final class ModelRelayHTTPConnection {
    private struct PendingWrite {
        let data: Data
        let completion: ModelRelayWriteCompletion?
    }

    private let connection: NWConnection
    private let router: ModelRelayRouter
    private let upstream: ModelRelayUpstreamClient
    private let onFinish: () -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var handled = false
    private var finished = false
    private var sendQueue: [PendingWrite] = []
    private var activeWriteCompletion: ModelRelayWriteCompletion?
    private var sending = false
    private var finishAfterSending = false
    private var operation: ModelRelayProxyOperation?

    init(
        connection: NWConnection,
        router: ModelRelayRouter,
        upstream: ModelRelayUpstreamClient,
        onFinish: @escaping () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.upstream = upstream
        self.onFinish = onFinish
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.finish(cancelOperation: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        finish(cancelOperation: true)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.tryHandle()
            }
            if error != nil || isComplete {
                self.finish(cancelOperation: true)
                return
            }
            self.lock.lock()
            let shouldContinue = !self.handled && !self.finished
            self.lock.unlock()
            if shouldContinue {
                self.receive()
            }
        }
    }

    private func tryHandle() {
        lock.lock()
        guard !handled, !finished else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            guard let parsed = try ModelRelayHTTPParser.parse(buffer) else { return }
            lock.lock()
            handled = true
            lock.unlock()
            handle(parsed.request)
            monitorDisconnect()
        } catch let error as ModelRelayHTTPParseError {
            let response: Data
            switch error {
            case .headersTooLarge:
                response = ModelRelayHTTPResponse.error(
                    status: 431,
                    reason: "Request Header Fields Too Large",
                    message: "请求头超过 64 KiB"
                )
            case .bodyTooLarge:
                response = ModelRelayHTTPResponse.error(
                    status: 413,
                    reason: "Payload Too Large",
                    message: "请求正文超过 64 MiB"
                )
            default:
                response = ModelRelayHTTPResponse.error(
                    status: 400,
                    reason: "Bad Request",
                    message: "HTTP 请求格式无效"
                )
            }
            sendAndFinish(response)
        } catch {
            sendAndFinish(ModelRelayHTTPResponse.error(
                status: 400,
                reason: "Bad Request",
                message: "无法解析请求"
            ))
        }
    }

    private func monitorDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.finish(cancelOperation: true)
                return
            }
            self.lock.lock()
            let shouldContinue = !self.finished
            self.lock.unlock()
            if shouldContinue {
                self.monitorDisconnect()
            }
        }
    }

    private func handle(_ request: ModelRelayHTTPRequest) {
        guard let token = request.bearerToken, router.authenticate(token) else {
            sendAndFinish(ModelRelayHTTPResponse.error(
                status: 401,
                reason: "Unauthorized",
                message: "本地 API Key 无效"
            ))
            return
        }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        if request.method == "GET", path == "/v1/models" {
            let aliases = router.availableAliases()
            let created = Int(Date().timeIntervalSince1970)
            let entries: [[String: Any]] = aliases.map {
                ["id": $0, "object": "model", "created": created, "owned_by": "tocode"]
            }
            sendAndFinish(ModelRelayHTTPResponse.json(
                status: 200,
                reason: "OK",
                object: ["object": "list", "data": entries]
            ))
            return
        }
        guard request.method == "POST",
              path == "/v1/chat/completions" || path == "/v1/responses" else {
            sendAndFinish(ModelRelayHTTPResponse.error(
                status: 404,
                reason: "Not Found",
                message: "不支持的中转路径"
            ))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let alias = json["model"] as? String,
              !alias.isEmpty else {
            sendAndFinish(ModelRelayHTTPResponse.error(
                status: 400,
                reason: "Bad Request",
                message: "请求缺少 model"
            ))
            return
        }
        do {
            let route = try router.resolve(alias: alias)
            let operation = try upstream.makeProxyOperation(
                request: request,
                route: route,
                router: router,
                send: { [weak self] data in self?.sendUpstreamChunkWithBackpressure(data) },
                completion: { [weak self] in self?.requestFinishAfterSending() }
            )
            lock.lock()
            self.operation = operation
            lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                operation.start()
            }
        } catch {
            let status = (error as? ModelRelayError) == .modelNotFound ? 404 : 503
            sendAndFinish(ModelRelayHTTPResponse.error(
                status: status,
                reason: status == 404 ? "Not Found" : "Service Unavailable",
                message: error.localizedDescription
            ))
        }
    }

    private func sendAndFinish(_ data: Data) {
        enqueue(data)
        requestFinishAfterSending()
    }

    private func enqueue(_ data: Data, completion: ModelRelayWriteCompletion? = nil) {
        guard !data.isEmpty else {
            completion?.resolve()
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            completion?.resolve()
            return
        }
        sendQueue.append(PendingWrite(data: data, completion: completion))
        let shouldStart = !sending
        if shouldStart { sending = true }
        lock.unlock()
        if shouldStart {
            sendNext()
        }
    }

    private func sendNext() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        guard !sendQueue.isEmpty else {
            sending = false
            let shouldFinish = finishAfterSending
            lock.unlock()
            if shouldFinish {
                finish(cancelOperation: false)
            }
            return
        }
        let pending = sendQueue.removeFirst()
        activeWriteCompletion = pending.completion
        lock.unlock()
        connection.send(content: pending.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            pending.completion?.resolve()
            self.lock.lock()
            self.activeWriteCompletion = nil
            self.lock.unlock()
            if error != nil {
                self.finish(cancelOperation: true)
            } else {
                self.sendNext()
            }
        })
    }

    private func sendUpstreamChunkWithBackpressure(_ data: Data) {
        let completion = ModelRelayWriteCompletion()
        enqueue(data, completion: completion)
        completion.wait()
    }

    private func requestFinishAfterSending() {
        lock.lock()
        finishAfterSending = true
        let shouldFinish = !sending && sendQueue.isEmpty
        lock.unlock()
        if shouldFinish {
            finish(cancelOperation: false)
        }
    }

    private func finish(cancelOperation: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let activeOperation = operation
        operation = nil
        let queuedCompletions = sendQueue.compactMap(\.completion)
        sendQueue.removeAll()
        let activeCompletion = activeWriteCompletion
        activeWriteCompletion = nil
        lock.unlock()
        activeCompletion?.resolve()
        queuedCompletions.forEach { $0.resolve() }
        if cancelOperation {
            activeOperation?.cancel()
        }
        connection.cancel()
        onFinish()
    }
}

private final class ModelRelayWriteCompletion {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var resolved = false

    func resolve() {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }
}
