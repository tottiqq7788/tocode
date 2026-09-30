import Foundation
import Security

final class MemoryModelRelayConfigStore: ModelRelayConfigStoring {
    var configuration: ModelRelayConfiguration
    var saveError: Error?
    var failOnSaveNumber: Int?
    var saveObserver: ((ModelRelayConfiguration) -> Void)?
    private(set) var saveCount = 0

    init(_ configuration: ModelRelayConfiguration = ModelRelayConfiguration()) {
        self.configuration = configuration
    }

    func load() throws -> ModelRelayConfiguration {
        configuration
    }

    func save(_ configuration: ModelRelayConfiguration) throws {
        saveCount += 1
        saveObserver?(configuration)
        if saveCount == failOnSaveNumber {
            throw ModelRelayError.configurationCorrupt
        }
        if let saveError { throw saveError }
        self.configuration = configuration
    }
}

final class CorruptModelRelayConfigStore: ModelRelayConfigStoring {
    private(set) var saveCount = 0

    func load() throws -> ModelRelayConfiguration {
        throw ModelRelayError.configurationCorrupt
    }

    func save(_ configuration: ModelRelayConfiguration) throws {
        saveCount += 1
        throw ModelRelayError.configurationCorrupt
    }
}

final class MemoryModelRelayKeyStore: ModelRelayUpstreamKeyStoring {
    private let lock = NSLock()
    private var values: [UUID: String]
    var saveError: Error?
    var deleteError: Error?
    var saveErrorIDs: Set<UUID> = []
    var deleteErrorIDs: Set<UUID> = []

    init(_ values: [UUID: String] = [:]) {
        self.values = values
    }

    func load(id: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }

    func save(_ secret: String, id: UUID) throws {
        lock.lock()
        if let saveError {
            lock.unlock()
            throw saveError
        }
        if saveErrorIDs.contains(id) {
            lock.unlock()
            throw ModelRelayError.keychain(errSecAuthFailed)
        }
        values[id] = secret
        lock.unlock()
    }

    func delete(id: UUID) throws {
        lock.lock()
        if let deleteError {
            lock.unlock()
            throw deleteError
        }
        if deleteErrorIDs.contains(id) {
            lock.unlock()
            throw ModelRelayError.keychain(errSecAuthFailed)
        }
        values.removeValue(forKey: id)
        lock.unlock()
    }

    var snapshot: [UUID: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class DeniedModelRelayKeyStore: ModelRelayUpstreamKeyStoring {
    func load(id: UUID) throws -> String? {
        throw ModelRelayError.keychain(errSecAuthFailed)
    }

    func save(_ secret: String, id: UUID) throws {
        throw ModelRelayError.keychain(errSecAuthFailed)
    }

    func delete(id: UUID) throws {
        throw ModelRelayError.keychain(errSecAuthFailed)
    }
}

final class MutableModelRelayClock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }
}

struct ModelRelayStubResponse {
    let status: Int
    var headers: [String: String] = ["Content-Type": "application/json"]
    var chunks: [Data] = []
    var errorAfterChunks: Error?
}

final class ModelRelayURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseHandler: ((URLRequest) throws -> ModelRelayStubResponse)?
    private static var capturedRequests: [URLRequest] = []

    static func reset(handler: @escaping (URLRequest) throws -> ModelRelayStubResponse) {
        lock.lock()
        responseHandler = handler
        capturedRequests = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let handler = Self.responseHandler
        Self.lock.unlock()
        do {
            guard let handler else {
                throw URLError(.badServerResponse)
            }
            let stub = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in stub.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if let error = stub.errorAfterChunks {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ModelRelayBlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var startedSignal = DispatchSemaphore(value: 0)
    private static var stoppedSignal = DispatchSemaphore(value: 0)

    static func reset() {
        lock.lock()
        startedSignal = DispatchSemaphore(value: 0)
        stoppedSignal = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    static func waitUntilStarted(timeout: TimeInterval) -> Bool {
        lock.lock()
        let signal = startedSignal
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }

    static func waitUntilStopped(timeout: TimeInterval) -> Bool {
        lock.lock()
        let signal = stoppedSignal
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: waiting\n\n".utf8))
        Self.lock.lock()
        let signal = Self.startedSignal
        Self.lock.unlock()
        signal.signal()
    }

    override func stopLoading() {
        Self.lock.lock()
        let signal = Self.stoppedSignal
        Self.lock.unlock()
        signal.signal()
    }
}

func modelRelayTestSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelRelayURLProtocol.self]
    return configuration
}

func modelRelayBlockingSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelRelayBlockingURLProtocol.self]
    return configuration
}

func waitForModelRelaySignal(
    _ signal: DispatchSemaphore,
    timeout: TimeInterval = 2
) -> Bool {
    signal.wait(timeout: .now() + timeout) == .success
}

func modelRelayURLRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        output.append(contentsOf: buffer.prefix(count))
    }
    return output
}

func modelRelayRequest(
    path: String = "/v1/chat/completions",
    model: String = "local-model",
    token: String = "local-secret"
) -> ModelRelayHTTPRequest {
    let body = try! JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": [["role": "user", "content": "ping"]]
    ])
    return ModelRelayHTTPRequest(
        method: "POST",
        target: path,
        version: "HTTP/1.1",
        headers: [
            "authorization": "Bearer \(token)",
            "content-type": "application/json"
        ],
        body: body
    )
}

func runModelRelayProxy(
    client: ModelRelayUpstreamClient,
    request: ModelRelayHTTPRequest,
    route: ModelRelayResolvedRoute,
    router: ModelRelayRouter
) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var output = Data()
        do {
            let operation = try client.makeProxyOperation(
                request: request,
                route: route,
                router: router,
                send: { chunk in
                    lock.lock()
                    output.append(chunk)
                    lock.unlock()
                },
                completion: {
                    lock.lock()
                    let result = output
                    lock.unlock()
                    continuation.resume(returning: result)
                }
            )
            operation.start()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

func startModelRelayTestServer(
    _ server: ModelRelayHTTPServer,
    port: UInt16
) async throws {
    try await withCheckedThrowingContinuation { continuation in
        do {
            try server.start(port: port) { result in
                continuation.resume(with: result)
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

func startModelRelayTestServerOnAvailablePort(
    _ server: ModelRelayHTTPServer
) async throws -> UInt16 {
    var lastError: Error = ModelRelayError.listener("没有可用测试端口")
    for _ in 0..<12 {
        let port = UInt16(Int.random(in: 31_000...59_000))
        do {
            try await startModelRelayTestServer(server, port: port)
            return port
        } catch {
            lastError = error
        }
    }
    throw lastError
}

func modelRelayLocalRequest(
    port: UInt16,
    path: String,
    method: String = "GET",
    token: String? = nil,
    object: [String: Any]? = nil
) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.setValue("close", forHTTPHeaderField: "Connection")
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let object {
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, response as! HTTPURLResponse)
}
