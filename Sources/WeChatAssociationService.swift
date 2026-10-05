import Foundation
import UserNotifications
import Darwin

@MainActor
protocol WeChatAssociationControlling: AnyObject {
    var isBound: Bool { get }
    func startBinding()
    func startBoundListener()
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
    var quickInput: WeChatQuickInputPerforming
    private let sleeper: WeChatSleeping
    private let now: () -> Date
    private let bindingPollInterval: TimeInterval
    private let bindingTimeout: TimeInterval

    private var listenerTask: Task<Void, Never>?
    private var bindingTask: Task<Void, Never>?
    private weak var togent: TogentService?

    init(
        transport: WeChatILinkTransporting,
        credentialStore: WeChatCredentialStoring,
        stateStore: WeChatReceiveStateStoring,
        archiver: WeChatArchiving,
        pageWriter: WeChatBindingPageWriting = WeChatBindingPageWriter(),
        opener: WeChatURLOpening = WorkspaceWeChatURLOpener(),
        notifier: WeChatNotifying = UserNotificationWeChatNotifier(),
        commandExecutor: TocodeCommandExecutor? = nil,
        quickInput: WeChatQuickInputPerforming = WeChatQuickInputService(),
        sleeper: WeChatSleeping = SystemWeChatSleeper(),
        now: @escaping () -> Date = Date.init,
        bindingPollInterval: TimeInterval = 2,
        bindingTimeout: TimeInterval = 300,
        togent: TogentService? = nil
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.stateStore = stateStore
        self.archiver = archiver
        self.pageWriter = pageWriter
        self.opener = opener
        self.notifier = notifier
        self.commandExecutor = commandExecutor
        self.quickInput = quickInput
        self.sleeper = sleeper
        self.now = now
        self.bindingPollInterval = bindingPollInterval
        self.bindingTimeout = bindingTimeout
        self.togent = togent
        credential = credentialStore.load()
        if let togent {
            attachTogent(togent)
        }
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

    func attachTogent(_ service: TogentService) {
        togent = service
        service.replyHandler = { [weak self] job, role, reply in
            guard let self else {
                throw TogentError.unavailable("微信服务已停止")
            }
            try await self.sendTogentReply(job: job, role: role, reply: reply)
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
                    notifier.notify(
                        title: "微信绑定成功",
                        body: "普通消息将归档到收到时角色的工作区。"
                    )
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
        togent?.recover(committedDeduplicationKeys: known)

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

                    if let routed = TocodeWeChatCommandGate.routedInput(from: message) {
                        try await consumeRouted(
                            message: message,
                            key: key,
                            routed: routed,
                            cursor: updates.cursor,
                            state: &state,
                            known: &known
                        )
                        continue
                    }

                    try await consumeOrdinary(
                        message: message,
                        key: key,
                        state: &state,
                        known: &known
                    )
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

    /// 普通消息严格执行“归档 → staged job → 微信去重状态 → queued job”。
    /// 点号命令和快捷输入不会调用本方法。
    private func consumeOrdinary(
        message: WeChatMessage,
        key: String,
        state: inout WeChatReceiveState,
        known: inout Set<String>
    ) async throws {
        let receivedAt = now()
        guard let togent else {
            try await consumeWithoutRoleArchive(
                message: message,
                key: key,
                error: TogentError.unavailable("Agent 服务未就绪"),
                state: &state,
                known: &known
            )
            return
        }

        let lease: TogentInboundLease
        do {
            guard let activeLease = try togent.beginInbound() else {
                try await consumeWithoutRoleArchive(
                    message: message,
                    key: key,
                    error: TogentError.noActiveRole,
                    state: &state,
                    known: &known
                )
                return
            }
            lease = activeLease
        } catch {
            try await consumeWithoutRoleArchive(
                message: message,
                key: key,
                error: error,
                state: &state,
                known: &known
            )
            return
        }
        defer { togent.endInbound(lease) }

        let batchKey = WeChatDeduplication.batchKey(
            for: message,
            roleID: lease.roleID
        )
        let waitsForText = Self.isPureImageMessage(message)
        togent.beginBatchIntake(batchKey: batchKey)
        var batchWasRescheduled = false
        defer {
            if !batchWasRescheduled {
                togent.resumeBatchAfterFailedIntake(batchKey: batchKey)
            }
        }

        let archiveReceipt = try await archiver.archive(
            message,
            receivedAt: receivedAt,
            root: lease.archiveRoot
        )
        try Task.checkCancellation()

        var stagingError: Error?
        do {
            try togent.stageInbound(
                message: message,
                deduplicationKey: key,
                receivedAt: receivedAt,
                lease: lease,
                archiveReceipt: archiveReceipt,
                batchKey: batchKey,
                waitsForText: waitsForText
            )
        } catch {
            stagingError = error
        }

        var committed = state
        committed.recentKeys.append(key)
        committed.recentKeys = Array(
            committed.recentKeys.suffix(WeChatDeduplication.maximumKeys)
        )
        committed.rememberInbound(message)
        do {
            try stateStore.save(committed)
        } catch {
            togent.discardStagedInbound(deduplicationKey: key)
            throw error
        }
        state = committed
        known.insert(key)

        if let stagingError {
            await sendImmediateTogentError(stagingError, for: message)
            return
        }
        do {
            try togent.commitStagedInbound(
                deduplicationKey: key,
                deferForBatching: true
            )
            batchWasRescheduled = true
        } catch {
            togent.discardStagedInbound(deduplicationKey: key)
            await sendImmediateTogentError(error, for: message)
        }
    }

    private static func isPureImageMessage(_ message: WeChatMessage) -> Bool {
        !message.items.isEmpty && message.items.allSatisfy {
            let directIsImageOnly = $0.imageItem != nil
                && $0.textItem == nil
                && $0.voiceItem == nil
                && $0.fileItem == nil
                && $0.videoItem == nil
            guard directIsImageOnly,
                  let quoted = $0.reference?.messageItem else {
                return directIsImageOnly
            }
            return quoted.imageItem != nil
                && quoted.textItem == nil
                && quoted.voiceItem == nil
                && quoted.fileItem == nil
                && quoted.videoItem == nil
        }
    }

    private func consumeWithoutRoleArchive(
        message: WeChatMessage,
        key: String,
        error: Error,
        state: inout WeChatReceiveState,
        known: inout Set<String>
    ) async throws {
        var committed = state
        committed.recentKeys.append(key)
        committed.recentKeys = Array(
            committed.recentKeys.suffix(WeChatDeduplication.maximumKeys)
        )
        committed.rememberInbound(message)
        try stateStore.save(committed)
        state = committed
        known.insert(key)
        await sendImmediateTogentError(error, for: message)
    }

    /// 点号命令与快捷输入共用消费语义：执行前先写入去重 key 并推进游标；不归档、不保存附件。
    /// 执行结果通过 sendmessage 回复到原会话，且该回复不入正式归档。
    private func consumeRouted(
        message: WeChatMessage,
        key: String,
        routed: TocodeWeChatRoutedInput,
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
        committed.rememberInbound(message)
        try stateStore.save(committed)
        state = committed
        known.insert(key)

        let result: TocodeCommandResult
        var helpBody: String?
        switch routed {
        case .command(let body):
            helpBody = body
            if let executor = commandExecutor {
                result = await executor.executeAsync(body)
            } else {
                result = .failure(.operationFailed("命令执行器未就绪"))
            }
        case .quickInput(let segments):
            result = quickInput.perform(segments)
        }

        let rawReply: String
        switch result {
        case .success(let output):
            if let helpBody, TocodeCommandParser.isHelpCommand(helpBody) {
                rawReply = TocodeCommandParser.weChatHelpText
            } else {
                rawReply = "✅ \(output.text)"
            }
        case .failure(let error):
            rawReply = "❌ \(error.message)"
        }
        let reply = rawReply

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

    private func sendTogentReply(
        job: TogentJob,
        role: TogentRole?,
        reply: TogentReply
    ) async throws {
        guard let credential else {
            throw TogentError.unavailable("微信绑定已失效")
        }
        guard !reply.relativeFilePaths.isEmpty || !reply.text.isEmpty else {
            throw TogentError.emptyReply
        }
        if !reply.relativeFilePaths.isEmpty, role == nil {
            throw TogentError.replyFileRejected("任务角色不可用")
        }
        if let role {
            for relativePath in reply.relativeFilePaths {
                let file = try Self.readTogentReplyFile(
                    relativePath,
                    workspacePath: role.workspacePath
                )
                let uploaded = try await transport.uploadMedia(
                    credential: credential,
                    toUserID: job.fromUserID,
                    fileName: file.name,
                    data: file.data,
                    kind: file.kind
                )
                let item: WeChatOutboundMessageItem
                switch file.kind {
                case .image:
                    item = .image(uploaded)
                case .file:
                    item = .file(name: file.name, media: uploaded)
                }
                try await transport.sendItems(
                    credential: credential,
                    toUserID: job.fromUserID,
                    contextToken: job.contextToken,
                    items: [item]
                )
            }
        }
        let chunks = TogentReplyChunker.chunks(reply.text)
        for chunk in chunks {
            try await transport.sendText(
                credential: credential,
                toUserID: job.fromUserID,
                contextToken: job.contextToken,
                text: chunk
            )
        }
    }

    private struct TogentReplyFile {
        let name: String
        let data: Data
        let kind: WeChatOutboundMediaKind
    }

    private static func readTogentReplyFile(
        _ relativePath: String,
        workspacePath: String
    ) throws -> TogentReplyFile {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw TogentError.replyFileRejected("文件路径无效")
        }

        var directoryDescriptor = workspacePath.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else {
            throw TogentError.replyFileRejected("角色工作区不可安全打开")
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw TogentError.replyFileRejected("角色工作区不是安全目录")
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw TogentError.replyFileRejected("文件路径包含不可访问目录")
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let name = components.last!
        let fileDescriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw TogentError.replyFileRejected("找不到安全的普通文件：\(relativePath)")
        }
        defer { Darwin.close(fileDescriptor) }

        var metadata = stat()
        let maximumBytes = TocodeWechatSendPayload.maximumFileBytes
        guard Darwin.fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw TogentError.replyFileRejected("只允许发送普通文件")
        }
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            throw TogentError.replyFileRejected("文件超过 20MB：\(name)")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else {
                    throw TogentError.replyFileRejected("文件超过 20MB：\(name)")
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw TogentError.replyFileRejected("读取文件失败：\(name)")
        }
        return TogentReplyFile(
            name: name,
            data: data,
            kind: WeChatOutboundMediaKind.classify(path: name)
        )
    }

    private func sendImmediateTogentError(_ error: Error, for message: WeChatMessage) async {
        guard let credential else { return }
        let detail = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        do {
            try await transport.sendText(
                credential: credential,
                toUserID: message.fromUserID,
                contextToken: message.contextToken,
                text: "❌ Togent：\(detail)"
            )
        } catch {
            notifier.notify(title: "Togent 错误回复发送失败", body: detail)
        }
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
