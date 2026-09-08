import Foundation
import UserNotifications

@MainActor
protocol WeChatAssociationControlling: AnyObject {
    var isBound: Bool { get }
    func startBinding()
    func startBoundListener()
    func openArchiveLocation()
    func stop()
}

protocol WeChatSleeping {
    func sleep(seconds: TimeInterval) async throws
}

struct SystemWeChatSleeper: WeChatSleeping {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

protocol WeChatNotifying {
    func notify(title: String, body: String)
}

struct UserNotificationWeChatNotifier: WeChatNotifying {
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.wechat.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

@MainActor
final class WeChatAssociationService: WeChatAssociationControlling {
    private(set) var credential: WeChatCredential?
    var isBound: Bool { credential != nil }

    private let transport: WeChatILinkTransporting
    private let credentialStore: WeChatCredentialStoring
    private let stateStore: WeChatReceiveStateStoring
    private let archiver: WeChatArchiving
    private let pageWriter: WeChatBindingPageWriting
    private let opener: WeChatURLOpening
    private let notifier: WeChatNotifying
    var commandExecutor: TocodeCommandExecutor?
    private let sleeper: WeChatSleeping
    private let now: () -> Date
    private let archiveRoot: URL
    private let bindingPollInterval: TimeInterval
    private let bindingTimeout: TimeInterval

    private var listenerTask: Task<Void, Never>?
    private var bindingTask: Task<Void, Never>?

    init(
        transport: WeChatILinkTransporting,
        credentialStore: WeChatCredentialStoring,
        stateStore: WeChatReceiveStateStoring,
        archiver: WeChatArchiving,
        pageWriter: WeChatBindingPageWriting = WeChatBindingPageWriter(),
        opener: WeChatURLOpening = WorkspaceWeChatURLOpener(),
        notifier: WeChatNotifying = UserNotificationWeChatNotifier(),
        commandExecutor: TocodeCommandExecutor? = nil,
        sleeper: WeChatSleeping = SystemWeChatSleeper(),
        now: @escaping () -> Date = Date.init,
        archiveRoot: URL = WeChatArchiveService.defaultRoot,
        bindingPollInterval: TimeInterval = 2,
        bindingTimeout: TimeInterval = 300
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.stateStore = stateStore
        self.archiver = archiver
        self.pageWriter = pageWriter
        self.opener = opener
        self.notifier = notifier
        self.commandExecutor = commandExecutor
        self.sleeper = sleeper
        self.now = now
        self.archiveRoot = archiveRoot
        self.bindingPollInterval = bindingPollInterval
        self.bindingTimeout = bindingTimeout
        credential = credentialStore.load()
    }

    convenience init() {
        let transport = WeChatILinkClient()
        self.init(
            transport: transport,
            credentialStore: FileWeChatCredentialStore(),
            stateStore: FileWeChatReceiveStateStore(),
            archiver: WeChatArchiveService(transport: transport)
        )
    }

    func startBinding() {
        bindingTask?.cancel()
        bindingTask = Task { [weak self] in
            await self?.performBinding()
        }
    }

    func startBoundListener() {
        guard listenerTask == nil, let credential else { return }
        listenerTask = Task { [weak self] in
            await self?.listen(using: credential)
        }
    }

    func openArchiveLocation() {
        do {
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            guard opener.open(archiveRoot) else {
                notifier.notify(title: "无法打开微信文件位置", body: archiveRoot.path)
                return
            }
        } catch {
            notifier.notify(title: "无法创建微信归档目录", body: archiveRoot.path)
        }
    }

    func stop() {
        bindingTask?.cancel()
        listenerTask?.cancel()
        bindingTask = nil
        listenerTask = nil
    }

    func performBinding() async {
        do {
            let qrCode = try await transport.fetchQRCode()
            let pageURL = try pageWriter.prepare(qrCode: qrCode)
            guard opener.open(pageURL) else {
                throw WeChatBindingFailure.browserOpenFailed
            }

            let startedAt = now()
            while !Task.isCancelled && now().timeIntervalSince(startedAt) < bindingTimeout {
                let status: WeChatQRCodeStatus
                do {
                    status = try await transport.fetchQRCodeStatus(qrcode: qrCode.qrcode)
                } catch is CancellationError {
                    return
                } catch {
                    try? pageWriter.update(.waiting)
                    try await sleeper.sleep(seconds: bindingPollInterval)
                    continue
                }

                switch status.status.lowercased() {
                case "confirmed":
                    try await acceptBinding(status)
                    try? pageWriter.update(.success)
                    notifier.notify(title: "微信绑定成功", body: "新消息将归档到 \(archiveRoot.path)")
                    bindingTask = nil
                    return
                case "scanned":
                    try? pageWriter.update(.scanned)
                case "expired":
                    try? pageWriter.update(.expired)
                    bindingTask = nil
                    return
                case "waiting", "":
                    try? pageWriter.update(.waiting)
                default:
                    try? pageWriter.update(.failed("微信返回了无法识别的绑定状态，请重新绑定。"))
                    bindingTask = nil
                    return
                }
                try await sleeper.sleep(seconds: bindingPollInterval)
            }
            if !Task.isCancelled {
                try? pageWriter.update(.expired)
            }
        } catch is CancellationError {
            return
        } catch {
            try? pageWriter.update(.failed(bindingFailureMessage(error)))
            notifier.notify(title: "微信绑定失败", body: bindingFailureMessage(error))
        }
        bindingTask = nil
    }

    private func acceptBinding(_ status: WeChatQRCodeStatus) async throws {
        let token = status.botToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw WeChatBindingFailure.emptyToken
        }

        let baseURL: URL
        if let raw = status.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard let parsed = URL(string: raw) else {
                throw WeChatBindingFailure.untrustedBaseURL
            }
            baseURL = parsed
        } else {
            baseURL = WeChatILinkClient.officialBaseURL
        }
        guard WeChatTrustPolicy.isTrustedAPIURL(baseURL) else {
            throw WeChatBindingFailure.untrustedBaseURL
        }

        let previousCredential = credential
        let replacement = WeChatCredential(token: token, baseURL: baseURL)
        try credentialStore.save(replacement)

        listenerTask?.cancel()
        listenerTask = nil
        credential = replacement
        do {
            try stateStore.reset()
        } catch {
            if let previousCredential {
                try? credentialStore.save(previousCredential)
                credential = previousCredential
                startBoundListener()
            } else {
                try? credentialStore.delete()
                credential = nil
            }
            throw WeChatBindingFailure.stateResetFailed
        }
        startBoundListener()
    }

    private func listen(using listenerCredential: WeChatCredential) async {
        var state = stateStore.load()
        var known = Set(state.recentKeys)
        var backoff: TimeInterval = 5

        while !Task.isCancelled {
            do {
                let updates = try await transport.getUpdates(
                    credential: listenerCredential,
                    cursor: state.cursor
                )
                for message in updates.messages where message.messageType == 1 {
                    try Task.checkCancellation()
                    let key = WeChatDeduplication.key(for: message)
                    if known.contains(key) {
                        continue
                    }

                    if let body = TocodeWeChatCommandGate.commandBody(from: message) {
                        try await consumeCommand(
                            message: message,
                            key: key,
                            body: body,
                            cursor: updates.cursor,
                            state: &state,
                            known: &known
                        )
                        continue
                    }

                    try await archiver.archive(message, receivedAt: now())
                    try Task.checkCancellation()
                    var committed = state
                    committed.recentKeys.append(key)
                    committed.recentKeys = Array(
                        committed.recentKeys.suffix(WeChatDeduplication.maximumKeys)
                    )
                    try stateStore.save(committed)
                    state = committed
                    known.insert(key)
                }

                var committed = state
                if !updates.cursor.isEmpty {
                    committed.cursor = updates.cursor
                }
                try stateStore.save(committed)
                state = committed
                known = Set(state.recentKeys)
                backoff = 5
            } catch is CancellationError {
                return
            } catch WeChatTransportError.unauthorized {
                await clearRejectedBinding()
                return
            } catch {
                do {
                    try await sleeper.sleep(seconds: backoff)
                } catch {
                    return
                }
                backoff = min(backoff * 2, 120)
            }
        }
    }

    /// 命令消息消费语义：执行前先写入去重 key 并推进游标；不归档、不保存附件。
    /// 执行结果通过 sendmessage 回复到原会话，且该回复不入正式归档（由上游发消息时判定为命令）。
    private func consumeCommand(
        message: WeChatMessage,
        key: String,
        body: String,
        cursor: String,
        state: inout WeChatReceiveState,
        known: inout Set<String>
    ) async throws {
        var committed = state
        committed.recentKeys.append(key)
        committed.recentKeys = Array(
            committed.recentKeys.suffix(WeChatDeduplication.maximumKeys)
        )
        if !cursor.isEmpty {
            committed.cursor = cursor
        }
        try stateStore.save(committed)
        state = committed
        known.insert(key)

        let result: TocodeCommandResult
        if let executor = commandExecutor {
            result = executor.execute(body)
        } else {
            result = .failure(.operationFailed("命令执行器未就绪"))
        }

        let reply: String
        switch result {
        case .success(let output):
            reply = "✅ \(output.text)"
        case .failure(let error):
            reply = "❌ \(error.message)"
        }

        guard let credential else { return }
        do {
            try await transport.sendText(
                credential: credential,
                toUserID: message.fromUserID,
                contextToken: message.contextToken,
                text: reply
            )
        } catch {
            notifier.notify(title: "命令结果发送失败", body: reply)
        }
    }

    private func clearRejectedBinding() async {
        do {
            try credentialStore.delete()
        } catch {
            notifier.notify(
                title: "微信授权已失效",
                body: "凭据清理失败，请重新绑定；若仍显示已绑定，请重新启动 Tocode。"
            )
        }
        credential = nil
        listenerTask = nil
        notifier.notify(title: "微信授权已失效", body: "请在 Tocode 中重新绑定微信。")
    }

    private func bindingFailureMessage(_ error: Error) -> String {
        switch error {
        case WeChatBindingFailure.emptyToken:
            return "微信确认响应没有有效凭据，请重新绑定。"
        case WeChatBindingFailure.untrustedBaseURL:
            return "微信返回了不受信任的服务地址，绑定已拒绝。"
        case WeChatBindingFailure.browserOpenFailed:
            return "无法打开默认浏览器。"
        case WeChatBindingFailure.stateResetFailed:
            return "无法重置本地接收状态，新绑定未启用。"
        default:
            return "暂时无法完成绑定，请稍后重试。"
        }
    }
}

private enum WeChatBindingFailure: Error {
    case emptyToken
    case untrustedBaseURL
    case browserOpenFailed
    case stateResetFailed
}
