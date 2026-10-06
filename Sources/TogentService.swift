import Foundation

@MainActor
final class TogentService {
    typealias ReplyHandler = @MainActor (
        TogentJob,
        TogentRole?,
        TogentReply
    ) async throws -> Void

    private struct ScheduledBatchTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    static let defaultRoleName = "default"
    static let defaultRolePrompt = """
    你是 default，一个运行在 Tocode / Togent 中的虚构 AI 角色。你的人格设定是一名 20 岁的中国女大学生，中文名“林知夏”，就读计算机科学相关专业。你不是现实人物；不得声称拥有真实学校、联系方式、住址、社交账号或线下经历。

    - 默认使用简体中文，语气自然、友善、耐心、清晰，可以体现年轻大学生的亲和力，但不能为了角色扮演牺牲事实准确性和任务质量。
    - 在合法、安全、尊重隐私且当前权限允许的范围内，以完成用户任务为最高优先级。先理解目标、约束与交付物；信息确实不足时再提出精简问题。
    - 对可以直接执行的任务，应主动使用可用工具完成、检查并汇报结果，而不是只给步骤或泛泛建议。
    - 创建软件或独立工作时，遵循当前工作区 AGENTS.md，把内容分类到 `project/` 下相互隔离的目录，并维护必要的本地 Git 与项目说明。
    - 不确定时明确说明并先验证；不得编造已经执行、已经验证或现实世界中发生过的事情。
    - 用户要求与系统安全、授权范围或工作区治理冲突时，说明具体限制，并在允许范围内提供最接近目标的可行方案。
    """

    private let store: TogentStore
    private let workspace: TogentWorkspaceService
    private let runtime: TogentRuntimeExecuting
    private let availableModelOptions: () -> [TogentModelOption]
    private let relayFingerprint: () -> String
    private let now: () -> Date
    private let messageBatchDebounce: TimeInterval
    private let imageCaptionTimeout: TimeInterval
    private var observedRelayFingerprint: String?
    private var workerTask: Task<Void, Never>?
    private var scheduledBatchTasks: [String: ScheduledBatchTask] = [:]
    private var inboundLeaseRoles: [UUID: TogentRole] = [:]
    private(set) var startupError: Error?

    var replyHandler: ReplyHandler?
    var didChange: (() -> Void)?

    init(
        store: TogentStore = TogentStore(),
        workspace: TogentWorkspaceService = TogentWorkspaceService(),
        runtime: TogentRuntimeExecuting,
        availableModelOptions: @escaping () -> [TogentModelOption],
        relayFingerprint: @escaping () -> String = { "" },
        bootstrapDefaultRole: Bool = true,
        now: @escaping () -> Date = Date.init,
        messageBatchDebounce: TimeInterval = 2,
        imageCaptionTimeout: TimeInterval = 120
    ) {
        self.store = store
        self.workspace = workspace
        self.runtime = runtime
        self.availableModelOptions = availableModelOptions
        self.relayFingerprint = relayFingerprint
        self.now = now
        self.messageBatchDebounce = max(0, messageBatchDebounce)
        self.imageCaptionTimeout = max(0, imageCaptionTimeout)
        observedRelayFingerprint = nil
        do {
            try store.recoverInterruptedJobs()
            if bootstrapDefaultRole {
                try bootstrapRoleWorkspaces()
            }
        } catch {
            startupError = error
        }
    }

    var roles: [TogentRole] {
        (try? store.roles()) ?? []
    }

    var models: [TogentModelOption] {
        availableModelOptions()
    }

    func defaultWorkspacePath(forRoleName name: String) -> String {
        workspace.defaultWorkspacePath(forRoleName: name)
    }

    var isBusy: Bool {
        if workerTask != nil || !inboundLeaseRoles.isEmpty {
            return true
        }
        return (try? store.hasPendingWork()) ?? true
    }

    func newRoleDraft() -> TogentRoleDraft {
        let existing = roles
        let name = workspace.nextDefaultRoleName(
            registeredNames: existing.map(\.name),
            registeredPaths: existing.map(\.workspacePath)
        )
        let options = models
        return TogentRoleDraft(
            name: name,
            workspacePath: workspace.defaultWorkspacePath(forRoleName: name),
            publishedModelID: options.first?.publishedModelID ?? "",
            isActive: existing.isEmpty
        )
    }

    func roleCopyOptions() -> [TogentRoleCopyOption] {
        let existing = roles
        return existing.map { source in
            let name = workspace.nextCopyRoleName(
                sourceName: source.name,
                registeredNames: existing.map(\.name),
                registeredPaths: existing.map(\.workspacePath)
            )
            return TogentRoleCopyOption(
                sourceRoleID: source.id,
                sourceRoleName: source.name,
                draft: TogentRoleDraft(
                    name: name,
                    workspacePath: workspace.defaultWorkspacePath(forRoleName: name),
                    prompt: source.prompt,
                    publishedModelID: source.publishedModelID,
                    isActive: false
                )
            )
        }
    }

    @discardableResult
    func createRole(from draft: TogentRoleDraft) throws -> TogentRole {
        try checkStartup()
        if isBusy {
            throw TogentError.busy
        }
        let normalized = try normalizedDraft(
            draft,
            excluding: nil,
            allowUnconfiguredModel: false
        )
        let now = Date()
        let role = TogentRole(
            name: normalized.name,
            workspacePath: normalized.workspacePath,
            prompt: normalized.prompt,
            publishedModelID: normalized.publishedModelID,
            isActive: normalized.isActive,
            createdAt: now,
            updatedAt: now
        )
        let receipt = try workspace.provision(role: role)
        do {
            let inserted = try store.insertRole(role)
            didChange?()
            return inserted
        } catch {
            workspace.rollback(receipt)
            throw error
        }
    }

    @discardableResult
    func updateRole(id: UUID, from draft: TogentRoleDraft) throws -> TogentRole {
        try checkStartup()
        guard let existing = try store.role(id: id) else {
            throw TogentError.roleNotFound
        }
        let normalized = try normalizedDraft(
            draft,
            excluding: id,
            allowUnconfiguredModel: existing.publishedModelID.isEmpty
        )
        let changesRuntimeBoundary =
            existing.name != normalized.name
            || existing.workspacePath != normalized.workspacePath
            || existing.publishedModelID != normalized.publishedModelID
            || existing.isActive != normalized.isActive
        if changesRuntimeBoundary, isBusy {
            throw TogentError.busy
        }

        let updated = TogentRole(
            id: existing.id,
            name: normalized.name,
            workspacePath: normalized.workspacePath,
            prompt: normalized.prompt,
            publishedModelID: normalized.publishedModelID,
            isActive: normalized.isActive,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        let receipt = try workspace.provision(role: updated)
        do {
            let saved = try store.updateRole(updated)
            if changesRuntimeBoundary {
                Task { [runtime] in
                    await runtime.stopAll()
                }
            }
            didChange?()
            return saved
        } catch {
            workspace.rollback(receipt)
            throw error
        }
    }

    func beginInbound() throws -> TogentInboundLease? {
        try checkStartup()
        guard let role = try store.activeRole() else {
            return nil
        }
        let archiveRoot = try workspace.archiveDirectory(for: role)
        let lease = TogentInboundLease(
            id: UUID(),
            roleID: role.id,
            archiveRoot: archiveRoot
        )
        inboundLeaseRoles[lease.id] = role
        return lease
    }

    func endInbound(_ lease: TogentInboundLease) {
        inboundLeaseRoles.removeValue(forKey: lease.id)
    }

    func beginBatchIntake(batchKey: String) {
        scheduledBatchTasks.removeValue(forKey: batchKey)?.task.cancel()
    }

    func resumeBatchAfterFailedIntake(batchKey: String) {
        do {
            if let status = try store.stagedBatchStatus(batchKey: batchKey) {
                scheduleBatch(status)
            }
        } catch {
            startupError = error
        }
    }

    func stageInbound(
        message: WeChatMessage,
        deduplicationKey: String,
        receivedAt: Date,
        lease: TogentInboundLease,
        archiveReceipt: WeChatArchiveReceipt = .empty,
        batchKey: String = "",
        waitsForText: Bool = false
    ) throws {
        try checkStartup()
        guard let leasedRole = inboundLeaseRoles[lease.id],
              leasedRole.id == lease.roleID else {
            throw TogentError.unavailable("微信入站角色租约已失效")
        }
        let attachmentPaths = try validatedAttachmentPaths(
            archiveReceipt,
            role: leasedRole,
            lease: lease
        )
        _ = try store.stageJob(
            deduplicationKey: deduplicationKey,
            roleID: leasedRole.id,
            fromUserID: message.fromUserID,
            contextToken: message.contextToken,
            messageText: Self.normalizedMessage(
                message,
                attachmentPaths: attachmentPaths
            ),
            receivedAt: receivedAt,
            batchKey: batchKey,
            waitsForText: waitsForText
        )
    }

    func commitStagedInbound(
        deduplicationKey: String,
        deferForBatching: Bool = false
    ) throws {
        guard deferForBatching else {
            try store.queueStagedJob(deduplicationKey: deduplicationKey)
            startWorkerIfNeeded()
            return
        }
        guard let status = try store.stagedBatchStatus(
            deduplicationKey: deduplicationKey
        ) else {
            throw TogentError.database("待提交的微信消息批次不存在")
        }
        scheduleBatch(status)
    }

    func discardStagedInbound(deduplicationKey: String) {
        try? store.discardStagedJob(deduplicationKey: deduplicationKey)
    }

    func recover(committedDeduplicationKeys: Set<String>) {
        do {
            try store.recoverInterruptedJobs()
            let pending = try store.reconcileStagedJobs(
                committedKeys: committedDeduplicationKeys
            )
            for status in pending {
                scheduleBatch(status)
            }
            startWorkerIfNeeded()
        } catch {
            startupError = error
        }
    }

    func stop() {
        let batches = Array(scheduledBatchTasks.values)
        scheduledBatchTasks.removeAll()
        batches.forEach { $0.task.cancel() }
        workerTask?.cancel()
        workerTask = nil
        Task { [runtime] in
            await runtime.stopAll()
        }
    }

    func stopAndWait() async {
        let batches = Array(scheduledBatchTasks.values)
        scheduledBatchTasks.removeAll()
        batches.forEach { $0.task.cancel() }
        let worker = workerTask
        worker?.cancel()
        await runtime.stopAll()
        for batch in batches {
            await batch.task.value
        }
        await worker?.value
        workerTask = nil
    }

    func relayDidChange() {
        let next = relayFingerprint()
        guard let observedRelayFingerprint else {
            self.observedRelayFingerprint = next
            return
        }
        guard next != observedRelayFingerprint else { return }
        self.observedRelayFingerprint = next
        Task { [runtime] in
            await runtime.stopAll()
        }
    }

    private func scheduleBatch(_ status: TogentStagedBatchStatus) {
        scheduledBatchTasks.removeValue(forKey: status.batchKey)?.task.cancel()
        let id = UUID()
        let delay: TimeInterval
        if status.waitsForText {
            let age = max(0, now().timeIntervalSince(status.oldestReceivedAt))
            delay = max(0, imageCaptionTimeout - age)
        } else {
            delay = messageBatchDebounce
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: delay)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishScheduledBatch(batchKey: status.batchKey, id: id)
        }
        scheduledBatchTasks[status.batchKey] = ScheduledBatchTask(
            id: id,
            task: task
        )
    }

    private func finishScheduledBatch(batchKey: String, id: UUID) {
        guard scheduledBatchTasks[batchKey]?.id == id else { return }
        scheduledBatchTasks.removeValue(forKey: batchKey)
        do {
            guard let current = try store.stagedBatchStatus(batchKey: batchKey) else {
                return
            }
            if current.waitsForText {
                let age = max(0, now().timeIntervalSince(current.oldestReceivedAt))
                if age < imageCaptionTimeout {
                    scheduleBatch(current)
                    return
                }
                try store.expireStagedBatch(batchKey: batchKey)
            } else {
                try store.queueStagedBatch(batchKey: batchKey)
                startWorkerIfNeeded()
            }
            didChange?()
        } catch {
            startupError = error
            didChange?()
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite else { return UInt64.max }
        return UInt64(min(
            seconds * 1_000_000_000,
            Double(UInt64.max)
        ))
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer {
            workerTask = nil
            didChange?()
        }
        while !Task.isCancelled {
            let job: TogentJob
            do {
                guard let next = try store.nextQueuedJob() else { return }
                job = next
                try store.markRunning(id: job.id)
            } catch {
                startupError = error
                return
            }
            await process(job)
        }
    }

    private func process(_ job: TogentJob) async {
        var replyRole: TogentRole?
        do {
            guard let roleID = job.roleID else {
                throw TogentError.noActiveRole
            }
            guard let role = try store.role(id: roleID) else {
                throw TogentError.roleNotFound
            }
            replyRole = role
            guard !role.publishedModelID.isEmpty else {
                throw TogentError.modelNotConfigured
            }
            guard models.contains(where: {
                $0.publishedModelID == role.publishedModelID
            }) else {
                throw TogentError.modelUnavailable
            }
            if observedRelayFingerprint == nil {
                observedRelayFingerprint = relayFingerprint()
            }
            let answer = try await runtime.execute(
                role: role,
                prompt: Self.prompt(job: job, role: role)
            )
            try Task.checkCancellation()
            guard let replyHandler else {
                throw TogentError.unavailable("微信回复通道未就绪")
            }
            let reply = try TogentReply.parse(answer)
            try await replyHandler(job, role, reply)
            try store.markCompleted(id: job.id)
        } catch {
            if Task.isCancelled {
                // 保持 running，由下次启动的 recoverInterruptedJobs 恢复排队。
                return
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            do {
                if let replyHandler {
                    try await replyHandler(
                        job,
                        replyRole,
                        TogentReply(text: "❌ Togent：\(message)")
                    )
                }
            } catch {
                let combined = "\(message)；微信错误回复发送失败：\(error.localizedDescription)"
                try? store.markFailed(id: job.id, error: combined)
                return
            }
            try? store.markFailed(id: job.id, error: message)
        }
    }

    private func normalizedDraft(
        _ draft: TogentRoleDraft,
        excluding roleID: UUID?,
        allowUnconfiguredModel: Bool
    ) throws -> TogentRoleDraft {
        let name = draft.name
        guard TogentRoleName.isValid(name) else {
            throw TogentError.invalidRoleName
        }
        let currentRoles = try store.roles()
        let foldedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if currentRoles.contains(where: {
            $0.id != roleID
                && $0.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) == foldedName
        }) {
            throw TogentError.duplicateRoleName
        }
        let canonical = try workspace.canonicalPath(draft.workspacePath)
        try workspace.validateIsolation(
            candidatePath: canonical,
            existingRoles: currentRoles,
            excluding: roleID
        )
        if draft.publishedModelID.isEmpty {
            guard allowUnconfiguredModel else {
                throw TogentError.modelNotConfigured
            }
        } else {
            guard models.contains(where: {
                $0.publishedModelID == draft.publishedModelID
            }) else {
                throw TogentError.modelUnavailable
            }
        }
        return TogentRoleDraft(
            name: name,
            workspacePath: canonical,
            prompt: draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedModelID: draft.publishedModelID,
            isActive: draft.isActive
        )
    }

    private func bootstrapRoleWorkspaces() throws {
        let existingRoles = try store.roles()
        if !existingRoles.isEmpty {
            for role in existingRoles {
                _ = try workspace.provision(role: role)
            }
            return
        }

        let now = Date()
        let role = TogentRole(
            name: Self.defaultRoleName,
            workspacePath: try workspace.canonicalPath(
                workspace.defaultWorkspacePath(forRoleName: Self.defaultRoleName)
            ),
            prompt: Self.defaultRolePrompt,
            publishedModelID: "",
            isActive: true,
            createdAt: now,
            updatedAt: now
        )
        let receipt = try workspace.provision(role: role)
        do {
            _ = try store.insertRole(role)
        } catch {
            workspace.rollback(receipt)
            throw error
        }
    }

    private func checkStartup() throws {
        if let startupError {
            throw TogentError.unavailable(startupError.localizedDescription)
        }
    }

    private func validatedAttachmentPaths(
        _ receipt: WeChatArchiveReceipt,
        role: TogentRole,
        lease: TogentInboundLease
    ) throws -> [String] {
        let workspaceRoot = URL(
            fileURLWithPath: role.workspacePath,
            isDirectory: true
        ).standardizedFileURL
        let expectedArchiveRoot = workspaceRoot
            .appendingPathComponent("wechat", isDirectory: true)
            .standardizedFileURL
        guard lease.archiveRoot.standardizedFileURL == expectedArchiveRoot else {
            throw TogentError.workspaceOutsideBoundary
        }
        let resolvedArchiveRoot = expectedArchiveRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let archivePrefix = expectedArchiveRoot.path + "/"
        let resolvedPrefix = resolvedArchiveRoot.path + "/"

        return try receipt.attachmentRelativePaths.map { relative in
            let components = relative.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !relative.hasPrefix("/"),
                  components.count >= 3,
                  components.first == "wechat",
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  }) else {
                throw TogentError.workspaceOutsideBoundary
            }
            let file = workspaceRoot
                .appendingPathComponent(relative, isDirectory: false)
                .standardizedFileURL
            guard file.path.hasPrefix(archivePrefix) else {
                throw TogentError.workspaceOutsideBoundary
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path
            )
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  resolvedFile.path.hasPrefix(resolvedPrefix) else {
                throw TogentError.workspaceOutsideBoundary
            }
            return relative
        }
    }

    private static func normalizedMessage(
        _ message: WeChatMessage,
        attachmentPaths: [String]
    ) -> String {
        var parts: [String] = []
        for item in message.items {
            if let text = item.textItem?.text.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                parts.append(text)
            } else if let voice = item.voiceItem {
                let text = voice.transcription
                parts.append(text.isEmpty ? "（语音消息，详情见微信归档）" : text)
            } else if let file = item.fileItem {
                parts.append("（文件：\(file.fileName.isEmpty ? "未命名" : file.fileName)，详情见微信归档）")
            } else if item.imageItem != nil {
                parts.append("（图片消息，详情见微信归档）")
            } else if let video = item.videoItem {
                parts.append("（视频：\(video.fileName.isEmpty ? "未命名" : video.fileName)，详情见微信归档）")
            } else {
                parts.append("（非文本消息，详情见微信归档）")
            }
        }
        if !attachmentPaths.isEmpty {
            parts.append("归档附件（当前角色工作区相对路径，只读）：")
            parts.append(contentsOf: attachmentPaths.map { "- \($0)" })
            parts.append("如需查看图片，必须调用 read 工具读取上述准确路径；不要猜测文件名，也不要改写归档。")
        }
        let normalized = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "（空消息，详情见微信归档）" : normalized
    }

    private static func prompt(job: TogentJob, role: TogentRole) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        这是微信消息完成角色归档后进入 Togent 的一个用户任务。微信是唯一任务入口；用户在短时间内连续发送的多条消息可能已按顺序合并在本任务中，不要再与本任务之外的消息合并。

        批次首条收到时间：\(formatter.string(from: job.receivedAt))
        当前角色：\(role.name)
        当前工作区：\(role.workspacePath)
        项目分类根目录：\(role.workspacePath)/project

        用户消息：
        \(job.messageText)

        请遵循工作区 AGENTS.md。需要历史上下文时，仅按需只读查询微信归档。

        完成实际工作后给出适合直接回复微信的最终文本。如果用户明确要求把当前角色工作区里的一个或多个文件发送到微信，必须在最终回复末尾追加且只追加一个以下控制块，`files` 只能填写当前工作区相对路径，按发送顺序最多五个；不要使用绝对路径、目录、symlink 或工作区外路径，也不要加 Markdown 代码围栏：
        <tocode_wechat_files>
        {"files":["AGENTS.md"]}
        </tocode_wechat_files>

        控制块由 Tocode 宿主处理，不会作为文字发给用户。只需文字回复时不要输出控制块。
        """
    }
}
