import Foundation

enum TestWeChatError: Error {
    case forced
}

final class MockWeChatTransport: WeChatILinkTransporting, @unchecked Sendable {
    private let mediaLock = NSLock()
    var qrCode = WeChatQRCode(qrcode: "qr-test")
    var qrError: Error?
    var statuses: [Result<WeChatQRCodeStatus, Error>] = []
    var updates: [Result<WeChatUpdates, Error>] = []
    var mediaResult: Result<Data, Error> = .success(Data("media".utf8))
    var fetchedQRCodes = 0
    var statusQRCodes: [String] = []
    var updateCredentials: [WeChatCredential] = []
    var updateCursors: [String] = []
    var mediaDescriptors: [WeChatMediaDescriptor] = []

    func fetchQRCode() async throws -> WeChatQRCode {
        fetchedQRCodes += 1
        if let qrError { throw qrError }
        return qrCode
    }

    func fetchQRCodeStatus(qrcode: String) async throws -> WeChatQRCodeStatus {
        statusQRCodes.append(qrcode)
        guard !statuses.isEmpty else { throw CancellationError() }
        return try statuses.removeFirst().get()
    }

    func getUpdates(credential: WeChatCredential, cursor: String) async throws -> WeChatUpdates {
        updateCredentials.append(credential)
        updateCursors.append(cursor)
        guard !updates.isEmpty else { throw CancellationError() }
        return try updates.removeFirst().get()
    }

    func downloadMedia(_ descriptor: WeChatMediaDescriptor) async throws -> Data {
        record(descriptor)
        return try mediaResult.get()
    }

    private func record(_ descriptor: WeChatMediaDescriptor) {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        mediaDescriptors.append(descriptor)
    }
}

final class CancellationAwareWeChatTransport: WeChatILinkTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func fetchQRCode() async throws -> WeChatQRCode {
        throw TestWeChatError.forced
    }

    func fetchQRCodeStatus(qrcode: String) async throws -> WeChatQRCodeStatus {
        throw TestWeChatError.forced
    }

    func getUpdates(credential: WeChatCredential, cursor: String) async throws -> WeChatUpdates {
        try await withTaskCancellationHandler {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return WeChatUpdates()
        } onCancel: {
            self.recordCancellation()
        }
    }

    func downloadMedia(_ descriptor: WeChatMediaDescriptor) async throws -> Data {
        throw TestWeChatError.forced
    }

    private func recordCancellation() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

final class MemoryWeChatCredentialStore: WeChatCredentialStoring {
    var credential: WeChatCredential?
    var saveError: Error?
    var deleteError: Error?
    var saves: [WeChatCredential] = []
    var deleteCount = 0

    init(_ credential: WeChatCredential? = nil) {
        self.credential = credential
    }

    func load() -> WeChatCredential? { credential }

    func save(_ credential: WeChatCredential) throws {
        if let saveError { throw saveError }
        saves.append(credential)
        self.credential = credential
    }

    func delete() throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        credential = nil
    }
}

final class MemoryWeChatStateStore: WeChatReceiveStateStoring {
    var state: WeChatReceiveState
    var saveError: Error?
    var resetError: Error?
    var saves: [WeChatReceiveState] = []
    var resetCount = 0

    init(_ state: WeChatReceiveState = .empty) {
        self.state = state
    }

    func load() -> WeChatReceiveState { state }

    func save(_ state: WeChatReceiveState) throws {
        if let saveError { throw saveError }
        self.state = state
        saves.append(state)
    }

    func reset() throws {
        resetCount += 1
        if let resetError { throw resetError }
        state = .empty
    }
}

final class MockWeChatArchiver: WeChatArchiving {
    var messages: [WeChatMessage] = []
    var receivedDates: [Date] = []
    var error: Error?

    func archive(_ message: WeChatMessage, receivedAt: Date) async throws {
        if let error { throw error }
        messages.append(message)
        receivedDates.append(receivedAt)
    }
}

final class MockWeChatBindingPage: WeChatBindingPageWriting {
    var prepared: [WeChatQRCode] = []
    var statuses: [WeChatBindingPageStatus] = []
    var error: Error?
    let url = URL(fileURLWithPath: "/tmp/tocode-wechat-bind-test.html")

    func prepare(qrCode: WeChatQRCode) throws -> URL {
        if let error { throw error }
        prepared.append(qrCode)
        return url
    }

    func update(_ status: WeChatBindingPageStatus) throws {
        statuses.append(status)
    }
}

final class MockWeChatOpener: WeChatURLOpening {
    var shouldOpen = true
    var urls: [URL] = []

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return shouldOpen
    }
}

final class MockWeChatNotifier: WeChatNotifying {
    var notifications: [(String, String)] = []

    func notify(title: String, body: String) {
        notifications.append((title, body))
    }
}

final class MockWeChatSleeper: WeChatSleeping {
    var seconds: [TimeInterval] = []
    var error: Error?

    func sleep(seconds: TimeInterval) async throws {
        self.seconds.append(seconds)
        if let error { throw error }
        await Task.yield()
    }
}

final class FailingWeChatFileSystem: WeChatFileSystem {
    let base = SystemWeChatFileSystem()
    var failCreate = false
    var failAppend = false
    var failWrite = false
    var failMove = false

    func createDirectory(at url: URL) throws {
        if failCreate { throw TestWeChatError.forced }
        try base.createDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func append(_ data: Data, to url: URL) throws {
        if failAppend { throw TestWeChatError.forced }
        try base.append(data, to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        if failWrite { throw TestWeChatError.forced }
        try base.write(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        if failMove { throw TestWeChatError.forced }
        try base.moveItem(at: source, to: destination)
    }

    func removeItemIfPresent(at url: URL) {
        base.removeItemIfPresent(at: url)
    }
}

final class WeChatURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            captured.httpBodyStream = nil
            captured.httpBody = body
        }
        Self.requests.append(captured)
        do {
            guard let handler = Self.handler else { throw TestWeChatError.forced }
            let (status, data) = try handler(captured)
            let response = HTTPURLResponse(
                url: captured.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        requests = []
    }
}

func makeWeChatTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WeChatURLProtocol.self]
    return URLSession(configuration: configuration)
}

func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
