import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

protocol ModelRelayCatalogFetching {
    func fetchModels(baseURL: String, secret: String) async throws -> [String]
}

struct ModelRelayCatalogEntry: Equatable, Sendable {
    let id: String
    let explicitlyTextOnly: Bool
}

struct ModelRelayModelDiscovery: Equatable, Sendable {
    let modelIDs: [String]
    let capabilities: [String: ModelRelayModelCapability]
}

struct ModelRelayImageProbeChallenge: Equatable, Sendable {
    let expectedDigits: String
    let dataURL: String
}

private final class ModelRelayProbeLimiter: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private let lock = NSLock()
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if active < limit {
                    active += 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if waiters.isEmpty {
            active = max(0, active - 1)
            continuation = nil
        } else {
            continuation = waiters.removeFirst().continuation
        }
        lock.unlock()
        continuation?.resume()
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            continuation = waiters.remove(at: index).continuation
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

final class ModelRelayUpstreamClient: ModelRelayCatalogFetching {
    private let sessionConfiguration: URLSessionConfiguration
    private let challengeFactory: () throws -> ModelRelayImageProbeChallenge
    private let now: () -> Date
    private let maximumConcurrentProbes: Int
    private let probeLimiter: ModelRelayProbeLimiter

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maximumConcurrentProbes: Int = 3,
        challengeFactory: @escaping () throws -> ModelRelayImageProbeChallenge = {
            try ModelRelayImageProbeGenerator.makeChallenge()
        },
        now: @escaping () -> Date = Date.init
    ) {
        let configuration = sessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.sessionConfiguration = configuration
        let probeLimit = min(3, max(1, maximumConcurrentProbes))
        self.maximumConcurrentProbes = probeLimit
        self.probeLimiter = ModelRelayProbeLimiter(limit: probeLimit)
        self.challengeFactory = challengeFactory
        self.now = now
    }

    func fetchModels(baseURL: String, secret: String) async throws -> [String] {
        try await fetchModelCatalog(baseURL: baseURL, secret: secret).map(\.id)
    }

    func discoverModels(
        baseURL: String,
        secret: String,
        cachedCapabilities: [String: ModelRelayModelCapability],
        probeCapabilities: Bool
    ) async throws -> ModelRelayModelDiscovery {
        let catalog = try await fetchModelCatalog(baseURL: baseURL, secret: secret)
        guard probeCapabilities else {
            return ModelRelayModelDiscovery(
                modelIDs: catalog.map(\.id),
                capabilities: [:]
            )
        }
        let capabilities = try await detectCapabilities(
            catalog: catalog,
            baseURL: baseURL,
            secret: secret,
            cachedCapabilities: cachedCapabilities
        )
        return ModelRelayModelDiscovery(
            modelIDs: catalog.map(\.id),
            capabilities: capabilities
        )
    }

    func fetchModelCatalog(
        baseURL: String,
        secret: String
    ) async throws -> [ModelRelayCatalogEntry] {
        let url = try ModelRelayValidation.endpoint(baseURL: baseURL, route: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await perform(
            request,
            origin: url,
            secret: secret
        )
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
        var unique: [String: ModelRelayCatalogEntry] = [:]
        for entry in entries {
            guard let rawID = entry["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let textOnly = Self.catalogExplicitlyTextOnly(entry)
            if let previous = unique[id] {
                unique[id] = ModelRelayCatalogEntry(
                    id: id,
                    explicitlyTextOnly: previous.explicitlyTextOnly || textOnly
                )
            } else {
                unique[id] = ModelRelayCatalogEntry(
                    id: id,
                    explicitlyTextOnly: textOnly
                )
            }
        }
        let catalog = unique.values.sorted { $0.id < $1.id }
        guard !catalog.isEmpty else {
            throw ModelRelayError.noModels
        }
        return catalog
    }

    private func detectCapabilities(
        catalog: [ModelRelayCatalogEntry],
        baseURL: String,
        secret: String,
        cachedCapabilities: [String: ModelRelayModelCapability]
    ) async throws -> [String: ModelRelayModelCapability] {
        try Task.checkCancellation()
        var result: [String: ModelRelayModelCapability] = [:]
        var pending: [ModelRelayCatalogEntry] = []
        let checkedAt = now()

        for entry in catalog {
            if let cached = cachedCapabilities[entry.id],
               cached.isCurrentAndConclusive {
                result[entry.id] = cached
            } else if entry.explicitlyTextOnly {
                result[entry.id] = ModelRelayModelCapability(
                    imageInput: .textOnly,
                    evidence: .catalogMetadata,
                    checkedAt: checkedAt,
                    probeVersion: ModelRelayModelCapability.currentProbeVersion
                )
            } else {
                pending.append(entry)
            }
        }

        let probed = try await withThrowingTaskGroup(
            of: (String, ModelRelayModelCapability).self,
            returning: [String: ModelRelayModelCapability].self
        ) { group in
            var detected: [String: ModelRelayModelCapability] = [:]
            var nextIndex = 0
            let initialCount = min(maximumConcurrentProbes, pending.count)
            for _ in 0..<initialCount {
                let entry = pending[nextIndex]
                nextIndex += 1
                group.addTask { [self] in
                    (
                        entry.id,
                        try await probeImageCapability(
                            modelID: entry.id,
                            baseURL: baseURL,
                            secret: secret
                        )
                    )
                }
            }
            while let capability = try await group.next() {
                detected[capability.0] = capability.1
                if nextIndex < pending.count {
                    let entry = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        (
                            entry.id,
                            try await probeImageCapability(
                                modelID: entry.id,
                                baseURL: baseURL,
                                secret: secret
                            )
                        )
                    }
                }
            }
            return detected
        }
        result.merge(probed) { _, latest in latest }
        return result
    }

    func probeImageCapability(
        modelID: String,
        baseURL: String,
        secret: String
    ) async throws -> ModelRelayModelCapability {
        try await probeLimiter.acquire()
        defer { probeLimiter.release() }
        try Task.checkCancellation()
        let checkedAt = now()
        let challenge: ModelRelayImageProbeChallenge
        do {
            challenge = try challengeFactory()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return unknownCapability(checkedAt: checkedAt)
        }
        try Task.checkCancellation()
        let url = try ModelRelayValidation.endpoint(
            baseURL: baseURL,
            route: "chat/completions"
        )
        let object: [String: Any] = [
            "model": modelID,
            "stream": false,
            "temperature": 0,
            "max_tokens": 16,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": "Read the six digits in this image. Reply with exactly those digits and nothing else."
                    ],
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": challenge.dataURL,
                            "detail": "low"
                        ]
                    ]
                ]
            ]]
        ]
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(
                request,
                origin: url,
                secret: secret
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return unknownCapability(checkedAt: checkedAt)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            return unknownCapability(checkedAt: checkedAt)
        }
        guard (200...299).contains(http.statusCode) else {
            if Self.isExplicitImageRejection(status: http.statusCode, data: data) {
                return ModelRelayModelCapability(
                    imageInput: .textOnly,
                    evidence: .explicitImageRejection,
                    checkedAt: checkedAt,
                    probeVersion: ModelRelayModelCapability.currentProbeVersion
                )
            }
            return unknownCapability(checkedAt: checkedAt)
        }
        guard let responseText = Self.assistantText(from: data) else {
            return unknownCapability(checkedAt: checkedAt)
        }
        let returnedDigits = String(responseText.filter {
            $0.asciiValue.map { (48...57).contains($0) } ?? false
        })
        guard returnedDigits == challenge.expectedDigits else {
            return unknownCapability(checkedAt: checkedAt)
        }
        return ModelRelayModelCapability(
            imageInput: .multimodal,
            evidence: .imageProbe,
            checkedAt: checkedAt,
            probeVersion: ModelRelayModelCapability.currentProbeVersion
        )
    }

    private func unknownCapability(checkedAt: Date) -> ModelRelayModelCapability {
        ModelRelayModelCapability(
            imageInput: .unknown,
            checkedAt: checkedAt,
            probeVersion: ModelRelayModelCapability.currentProbeVersion
        )
    }

    private func perform(
        _ request: URLRequest,
        origin: URL,
        secret: String
    ) async throws -> (Data, URLResponse) {
        let redirect = ModelRelayRedirectDelegate(origin: origin, secret: secret)
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirect,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await session.data(for: request)
        } catch {
            if error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ModelRelayError.upstream(error.localizedDescription)
        }
    }

    private static func catalogExplicitlyTextOnly(_ entry: [String: Any]) -> Bool {
        let dictionaries = [entry, entry["architecture"], entry["capabilities"]]
            .compactMap { $0 as? [String: Any] }
        let modalityKeys = [
            "input_modalities", "inputModalities", "modalities",
            "supported_modalities", "supportedModalities"
        ]
        for dictionary in dictionaries {
            for key in modalityKeys {
                guard let raw = dictionary[key] else { continue }
                let values: [String]
                if let array = raw as? [String] {
                    values = array
                } else if let value = raw as? String {
                    values = value
                        .split(whereSeparator: { $0 == "," || $0 == " " })
                        .map(String.init)
                } else {
                    continue
                }
                let normalized = values.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                let hasImage = normalized.contains {
                    $0 == "image" || $0 == "vision" || $0 == "image_url"
                }
                if !hasImage && normalized.contains("text") {
                    return true
                }
            }
            for key in [
                "supports_image_input", "supportsImageInput",
                "supports_vision", "supportsVision", "vision"
            ] where dictionary[key] as? Bool == false {
                return true
            }
        }
        return false
    }

    private static func assistantText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func isExplicitImageRejection(status: Int, data: Data) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let message = upstreamErrorMessage(from: data).lowercased()
        let patterns = [
            #"(?:does not|doesn't|doesnt|do not) support (?:the )?(?:image input|image_url|vision input|vision|multimodal input|multimodal)(?![._])"#,
            #"(?:does not|doesn't|doesnt|do not) support (?:the )?images?\s*[.!]?$"#,
            #"(?:image input|image_url|vision input|multimodal input)(?![._])(?: is| are)? (?:not supported|unsupported)"#,
            #"unsupported (?:image input|image_url|vision input|multimodal input)(?![._])"#,
            #"(?:only supports?|supports only) text(?: input)?\b"#,
            #"\btext[- ]only(?: model)?\b"#
        ]
        return patterns.contains {
            message.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func upstreamErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let error = object["error"] as? String {
                return error
            }
            if let message = object["message"] as? String {
                return message
            }
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
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

private enum ModelRelayImageProbeGenerator {
    private static let digitSegments: [Character: Set<Character>] = [
        "0": Set("abcdef"),
        "1": Set("bc"),
        "2": Set("abdeg"),
        "3": Set("abcdg"),
        "4": Set("bcfg"),
        "5": Set("acdfg"),
        "6": Set("acdefg"),
        "7": Set("abc"),
        "8": Set("abcdefg"),
        "9": Set("abcdfg")
    ]

    static func makeChallenge() throws -> ModelRelayImageProbeChallenge {
        let digits = String((0..<6).map { _ in Character(String(Int.random(in: 0...9))) })
        let width = 252
        let height = 84
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ModelRelayError.upstream("无法生成图片能力探针")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        for (index, digit) in digits.enumerated() {
            draw(
                digit: digit,
                originX: CGFloat(12 + index * 40),
                in: context
            )
        }
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))

        guard let image = context.makeImage() else {
            throw ModelRelayError.upstream("无法生成图片能力探针")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ModelRelayError.upstream("无法编码图片能力探针")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ModelRelayError.upstream("无法编码图片能力探针")
        }
        return ModelRelayImageProbeChallenge(
            expectedDigits: digits,
            dataURL: "data:image/png;base64,\((data as Data).base64EncodedString())"
        )
    }

    private static func draw(
        digit: Character,
        originX: CGFloat,
        in context: CGContext
    ) {
        guard let segments = digitSegments[digit] else { return }
        let thickness: CGFloat = 5
        let horizontalWidth: CGFloat = 24
        let verticalHeight: CGFloat = 25
        let x = originX
        let lowY: CGFloat = 9
        let middleY: CGFloat = 39
        let highY: CGFloat = 69
        let rectangles: [Character: CGRect] = [
            "a": CGRect(x: x + thickness, y: highY, width: horizontalWidth, height: thickness),
            "b": CGRect(x: x + horizontalWidth + thickness, y: middleY + thickness, width: thickness, height: verticalHeight),
            "c": CGRect(x: x + horizontalWidth + thickness, y: lowY + thickness, width: thickness, height: verticalHeight),
            "d": CGRect(x: x + thickness, y: lowY, width: horizontalWidth, height: thickness),
            "e": CGRect(x: x, y: lowY + thickness, width: thickness, height: verticalHeight),
            "f": CGRect(x: x, y: middleY + thickness, width: thickness, height: verticalHeight),
            "g": CGRect(x: x + thickness, y: middleY, width: horizontalWidth, height: thickness)
        ]
        for segment in segments {
            if let rectangle = rectangles[segment] {
                context.fill(rectangle)
            }
        }
    }
}
