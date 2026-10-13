import Foundation
import UserNotifications

@MainActor
protocol WeChatAssociationControlling: AnyObject {
    var isBound: Bool { get }
    func startBinding()
    func startBoundListener()
    func openArchiveLocation()
    func stop()
    func sendOutbound(_ payload: TocodeWechatSendPayload) async -> TocodeCommandResult
}

extension WeChatAssociationControlling {
    func sendOutbound(_ payload: TocodeWechatSendPayload) async -> TocodeCommandResult {
        _ = payload
        return .failure(.operationFailed("微信未绑定"))
    }
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

    private enum BindingStatusKind {
        case waiting
        case scanned
        case confirmed
        case expired
        case unknown
    }

    /// iLink 扫码状态值在不同版本中出现过 `wait`、`scan`、`success` 等拼写，
    /// 这里做归一化；未知值保守地继续轮询，避免误判导致扫码后页面立即失败。
    private static func bindingStatusKind(_ raw: String) -> BindingStatusKind {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "wait", "waiting", "pending":
            return .waiting
        case "scan", "scaned", "scaning", "scanning", "scanned", "login", "logined":
            return .scanned
        case "confirm", "confirmed", "success", "succeed", "ok":
            return .confirmed
        case "expire", "expired", "timeout", "fail", "failed":
            return .expired
        default:
            return .unknown
        }
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

                switch Self.bindingStatusKind(status.status) {
                case .confirmed:
                    try await acceptBinding(status)
                    try? pageWriter.update(.success)
                    notifier.notify(title: "微信绑定成功", body: "新消息将归档到 \(archiveRoot.path)")
                    bindingTask = nil
                    return
                case .scanned:
                    try? pageWriter.update(.scanned)
                case .expired:
                    try? pageWriter.update(.expired)
                    bindingTask = nil
                    return
                case .waiting, .unknown:
                    try? pageWriter.update(.waiting)
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

                    try await archiver.archive(message, receivedAt: now())
                    try Task.checkCancellation()
                    var committed = state
                    committed.recentKeys.append(key)
                    committed.recentKeys = Array(
                        committed.recentKeys.suffix(WeChatDeduplication.maximumKeys)
                    )
                    committed.rememberInbound(message)
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

    func sendOutbound(_ payload: TocodeWechatSendPayload) async -> TocodeCommandResult {
        guard let credential else {
            return .failure(.operationFailed("微信未绑定"))
        }
        let state = stateStore.load()
        guard let target = state.replyTarget(userID: payload.toUserID) else {
            if let to = payload.toUserID, !to.isEmpty {
                return .failure(.operationFailed("没有该用户的会话记录，请先收到对方消息"))
            }
            return .failure(.operationFailed("还没有可回复的会话，请先收到一条微信消息"))
        }

        var sent = 0
        if let text = payload.text {
            do {
                try await transport.sendItems(
                    credential: credential,
                    toUserID: target.userID,
                    contextToken: target.contextToken,
                    items: [.text(text)]
                )
                sent += 1
            } catch {
                return .failure(.operationFailed(sendFailureMessage(error, sent: sent)))
            }
        }

        for path in payload.files {
            switch await sendFile(path, credential: credential, target: target) {
            case .failure(let error):
                return .failure(.operationFailed(sendFailureMessage(error, sent: sent)))
            case .success:
                sent += 1
            }
        }
        return .success(TocodeCommandOutput(sent == 1 ? "已发送" : "已发送 \(sent) 条消息"))
    }

    private func sendFile(
        _ path: String,
        credential: WeChatCredential,
        target: WeChatReplyTarget
    ) async -> Result<Void, Error> {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(TocodeCommandError.operationFailed("找不到文件：\(path)"))
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= TocodeWechatSendPayload.maximumFileBytes else {
                return .failure(
                    TocodeCommandError.operationFailed("文件超过 20MB：\(url.lastPathComponent)")
                )
            }
            let data = try Data(contentsOf: url)
            let kind = WeChatOutboundMediaKind.classify(path: url.path)
            let uploaded = try await transport.uploadMedia(
                credential: credential,
                toUserID: target.userID,
                fileName: url.lastPathComponent,
                data: data,
                kind: kind
            )
            let item: WeChatOutboundMessageItem
            switch kind {
            case .image:
                item = .image(uploaded)
            case .file:
                item = .file(name: url.lastPathComponent, media: uploaded)
            }
            try await transport.sendItems(
                credential: credential,
                toUserID: target.userID,
                contextToken: target.contextToken,
                items: [item]
            )
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func sendFailureMessage(_ error: Error, sent: Int) -> String {
        let reason: String
        if let command = error as? TocodeCommandError {
            reason = command.message
        } else if let transport = error as? WeChatTransportError {
            switch transport {
            case .unauthorized:
                reason = "微信授权已失效"
            case .untrustedURL:
                reason = "微信服务地址不受信任"
            case .emptyUploadParam, .missingEncryptedParam, .invalidResponse:
                reason = "微信上传协议不匹配"
            case .apiFailure(let ret):
                reason = "微信接口返回 \(ret)"
            case .serverFailure(let status):
                reason = "微信服务暂时故障（\(status)）"
            default:
                reason = "发送失败"
            }
        } else {
            reason = "发送失败"
        }
        if sent == 0 {
            return reason
        }
        return "已发送 \(sent) 条后失败：\(reason)"
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
