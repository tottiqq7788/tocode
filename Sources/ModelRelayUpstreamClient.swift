import Foundation

protocol ModelRelayCatalogFetching {
    func fetchModels(baseURL: String, secret: String) async throws -> [String]
}

final class ModelRelayUpstreamClient: ModelRelayCatalogFetching {
    private let sessionConfiguration: URLSessionConfiguration

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let configuration = sessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.sessionConfiguration = configuration
    }

    func fetchModels(baseURL: String, secret: String) async throws -> [String] {
        let url = try ModelRelayValidation.endpoint(baseURL: baseURL, route: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let redirect = ModelRelayRedirectDelegate(origin: url, secret: secret)
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirect,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelRelayError.upstream(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelRelayError.upstream("没有 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelRelayError.upstreamHTTP(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            throw ModelRelayError.upstream("/v1/models 响应格式无效")
        }
        let models = entries.compactMap { $0["id"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(models)).sorted()
        guard !unique.isEmpty else {
            throw ModelRelayError.noModels
        }
        return unique
    }

    func makeProxyOperation(
        request: ModelRelayHTTPRequest,
        route: ModelRelayResolvedRoute,
        router: ModelRelayRouter,
        metrics: ModelRelayCallMetricsRecording?,
        send: @escaping (Data) -> Void,
        completion: @escaping () -> Void
    ) throws -> ModelRelayProxyOperation {
        let endpoint: String
        switch request.target.split(separator: "?", maxSplits: 1).first.map(String.init) {
        case "/v1/chat/completions":
            endpoint = "chat/completions"
        case "/v1/responses":
            endpoint = "responses"
        default:
            throw ModelRelayError.modelNotFound
        }
        guard var json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw ModelRelayHTTPParseError.malformedRequest
        }
        json["model"] = route.candidates[0].upstreamModelID
        let body = try JSONSerialization.data(withJSONObject: json)
        return ModelRelayProxyOperation(
            candidates: route.candidates,
            endpoint: endpoint,
            publishedModel: route.alias,
            body: body,
            inboundHeaders: request.headers,
            router: router,
            metrics: metrics,
            configuration: sessionConfiguration,
            send: send,
            completion: completion
        )
    }
}

final class ModelRelayProxyOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let candidates: [ModelRelayUpstreamCandidate]
    private let endpoint: String
    private let publishedModel: String
    private let body: Data
    private let inboundHeaders: [String: String]
    private let router: ModelRelayRouter
    private weak var metrics: ModelRelayCallMetricsRecording?
    private let configuration: URLSessionConfiguration
    private let send: (Data) -> Void
    private let completion: () -> Void
    private let startedAt: Date
    private let lock = NSLock()
    private var candidateIndex = 0
    private var currentCandidate: ModelRelayUpstreamCandidate?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseStarted = false
    private var finished = false
    private var originURL: URL?
    private var finalStatus: Int?
    private var finalOK = false

    init(
        candidates: [ModelRelayUpstreamCandidate],
        endpoint: String,
        publishedModel: String,
        body: Data,
        inboundHeaders: [String: String],
        router: ModelRelayRouter,
        metrics: ModelRelayCallMetricsRecording?,
        configuration: URLSessionConfiguration,
        send: @escaping (Data) -> Void,
        completion: @escaping () -> Void,
        startedAt: Date = Date()
    ) {
        self.candidates = Array(candidates.prefix(1))
        self.endpoint = endpoint
        self.publishedModel = publishedModel
        self.body = body
        self.inboundHeaders = inboundHeaders
        self.router = router
        self.metrics = metrics
        self.configuration = configuration
        self.send = send
        self.completion = completion
        self.startedAt = startedAt
    }

    func start() {
        attemptNext(lastMessage: "没有可用上游")
    }

    func cancel() {
        finishOnce(status: finalStatus, ok: false) {
            let activeTask = self.task
            let activeSession = self.session
            activeTask?.cancel()
            activeSession?.invalidateAndCancel()
        }
    }

    private func attemptNext(lastMessage: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        guard candidateIndex < candidates.count else {
            lock.unlock()
            send(ModelRelayHTTPResponse.error(
                status: 502,
                reason: "Bad Gateway",
                message: lastMessage
            ))
            finishOnce(status: 502, ok: false)
            return
        }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        currentCandidate = candidate
        responseStarted = false
        lock.unlock()

        do {
            let url = try ModelRelayValidation.endpoint(
                baseURL: candidate.baseURL,
                route: endpoint
            )
            originURL = url
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            let forbidden = Set([
                "authorization", "host", "content-length", "transfer-encoding", "connection",
                "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "upgrade",
                "accept-encoding"
            ])
            for (name, value) in inboundHeaders where !forbidden.contains(name.lowercased()) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("Bearer \(candidate.secret)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            let task = session.dataTask(with: request)
            lock.lock()
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        } catch {
            router.recordFailure(keyID: candidate.keyID, statusCode: nil)
            attemptNext(lastMessage: error.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let isActive = self.task === dataTask && !finished
        let candidate = currentCandidate
        lock.unlock()
        guard isActive, let http = response as? HTTPURLResponse, let candidate else {
            completionHandler(.cancel)
            if isActive {
                retryAfterCurrentAttempt(message: "上游没有返回 HTTP 响应", statusCode: nil)
            }
            return
        }
        let status = http.statusCode
        if status == 401 || status == 403 || status == 429 || (500...599).contains(status) {
            completionHandler(.cancel)
            retryAfterCurrentAttempt(message: "上游 HTTP \(status)", statusCode: status)
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        responseStarted = true
        finalStatus = status
        finalOK = (200...299).contains(status)
        lock.unlock()
        router.recordSuccess(keyID: candidate.keyID)
        send(ModelRelayHTTPResponse.chunkedHeader(
            status: status,
            reason: Self.reason(status),
            headers: http.allHeaderFields
        ))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let maySend = self.task === dataTask && responseStarted && !finished
        lock.unlock()
        if maySend {
            send(ModelRelayHTTPResponse.chunk(data))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        if finished || self.task !== task {
            lock.unlock()
            return
        }
        let started = responseStarted
        let candidate = currentCandidate
        let status = finalStatus
        let ok = finalOK
        lock.unlock()

        if started {
            if error == nil {
                send(ModelRelayHTTPResponse.finalChunk)
            }
            session.finishTasksAndInvalidate()
            finishOnce(status: status, ok: ok && error == nil)
            return
        }
        if let candidate {
            router.recordFailure(keyID: candidate.keyID, statusCode: nil)
        }
        session.invalidateAndCancel()
        attemptNext(lastMessage: error?.localizedDescription ?? "上游连接提前结束")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let isActive = self.task === task && !finished
        let activeOrigin = originURL
        let candidate = currentCandidate
        lock.unlock()
        guard isActive,
              response.statusCode == 307 || response.statusCode == 308,
              let activeOrigin,
              let target = newRequest.url,
              Self.sameOrigin(activeOrigin, target) else {
            completionHandler(nil)
            return
        }
        var request = newRequest
        if let candidate {
            request.setValue("Bearer \(candidate.secret)", forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }

    private func retryAfterCurrentAttempt(message: String, statusCode: Int?) {
        guard let candidate = currentCandidate else { return }
        router.recordFailure(keyID: candidate.keyID, statusCode: statusCode)
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let oldSession = session
        lock.unlock()
        oldSession?.invalidateAndCancel()
        attemptNext(lastMessage: message)
    }

    private func finishOnce(status: Int?, ok: Bool, beforeCompletion: (() -> Void)? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let candidate = currentCandidate ?? candidates.first
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        lock.unlock()
        beforeCompletion?()
        metrics?.record(ModelRelayCallEvent(
            timestamp: Date(),
            route: endpoint,
            providerID: candidate?.providerID,
            providerName: candidate?.providerName,
            publishedModel: publishedModel,
            upstreamModel: candidate?.upstreamModelID,
            status: status,
            durationMs: duration,
            ok: ok
        ))
        completion()
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "HTTP"
        }
    }
}

private final class ModelRelayRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let origin: URL
    private let secret: String

    init(origin: URL, secret: String) {
        self.origin = origin
        self.secret = secret
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard response.statusCode == 307 || response.statusCode == 308,
              let target = newRequest.url,
              origin.scheme?.lowercased() == target.scheme?.lowercased(),
              origin.host?.lowercased() == target.host?.lowercased(),
              origin.port == target.port else {
            completionHandler(nil)
            return
        }
        var request = newRequest
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        completionHandler(request)
    }
}
