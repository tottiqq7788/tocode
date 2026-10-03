import Foundation

@MainActor
final class TogentService {
    typealias ReplyHandler = @MainActor (TogentJob, String) async throws -> Void

    private let store: TogentStore
    private let workspace: TogentWorkspaceService
    private let runtime: TogentRuntimeExecuting
    private let availableModelOptions: () -> [TogentModelOption]
    private let relayFingerprint: () -> String
    private var observedRelayFingerprint: String
    private var workerTask: Task<Void, Never>?
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
        bootstrapDefaultRole: Bool = true
    ) {
        self.store = store
        self.workspace = workspace
        self.runtime = runtime
        self.availableModelOptions = availableModelOptions
        self.relayFingerprint = relayFingerprint
        observedRelayFingerprint = relayFingerprint()
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

    var isBusy: Bool {
        if workerTask != nil || !inboundLeaseRoles.isEmpty {
            return true
        }
        return (try? store.hasPendingWork()) ?? true
    }

    func newRoleDraft() -> TogentRoleDraft {
        let existing = roles
        let defaultPath = workspace.defaultWorkspacePath(
            registeredPaths: existing.map(\.workspacePath)
        )
        let options = models
        return TogentRoleDraft(
            workspacePath: defaultPath,
            publishedModelID: options.first?.publishedModelID ?? "",
            isActive: existing.isEmpty
        )
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

    func stageInbound(
        message: WeChatMessage,
        deduplicationKey: String,
        receivedAt: Date,
        lease: TogentInboundLease
    ) throws {
        try checkStartup()
        guard let leasedRole = inboundLeaseRoles[lease.id],
              leasedRole.id == lease.roleID else {
            throw TogentError.unavailable("微信入站角色租约已失效")
        }
        _ = try store.stageJob(
            deduplicationKey: deduplicationKey,
            roleID: leasedRole.id,
            fromUserID: message.fromUserID,
            contextToken: message.contextToken,
            messageText: Self.normalizedMessage(message),
            receivedAt: receivedAt
        )
    }

    func commitStagedInbound(deduplicationKey: String) throws {
        try store.queueStagedJob(deduplicationKey: deduplicationKey)
        startWorkerIfNeeded()
    }

    func discardStagedInbound(deduplicationKey: String) {
        try? store.discardStagedJob(deduplicationKey: deduplicationKey)
    }

    func recover(committedDeduplicationKeys: Set<String>) {
        do {
            try store.recoverInterruptedJobs()
            try store.reconcileStagedJobs(committedKeys: committedDeduplicationKeys)
            startWorkerIfNeeded()
        } catch {
            startupError = error
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
        Task { [runtime] in
            await runtime.stopAll()
        }
    }

    func stopAndWait() async {
        let worker = workerTask
        worker?.cancel()
        await runtime.stopAll()
        await worker?.value
        workerTask = nil
    }

    func relayDidChange() {
        let next = relayFingerprint()
        guard next != observedRelayFingerprint else { return }
        observedRelayFingerprint = next
        Task { [runtime] in
            await runtime.stopAll()
        }
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
        do {
            guard let roleID = job.roleID else {
                throw TogentError.noActiveRole
            }
            guard let role = try store.role(id: roleID) else {
                throw TogentError.roleNotFound
            }
            guard !role.publishedModelID.isEmpty else {
                throw TogentError.modelNotConfigured
            }
            guard models.contains(where: {
                $0.publishedModelID == role.publishedModelID
            }) else {
                throw TogentError.modelUnavailable
            }
            let answer = try await runtime.execute(
                role: role,
                prompt: Self.prompt(job: job, role: role)
            )
            try Task.checkCancellation()
            guard let replyHandler else {
                throw TogentError.unavailable("微信回复通道未就绪")
            }
            try await replyHandler(job, answer)
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
                    try await replyHandler(job, "❌ Togent：\(message)")
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
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw TogentError.invalidRoleName
        }
        let currentRoles = try store.roles()
        let foldedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if currentRoles.contains(where: {
            $0.id != roleID
                && $0.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
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
            name: "默认角色",
            workspacePath: try workspace.canonicalPath(
                workspace.defaultWorkspacePath(registeredPaths: [])
            ),
            prompt: "",
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

    private static func normalizedMessage(_ message: WeChatMessage) -> String {
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
        let normalized = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "（空消息，详情见微信归档）" : normalized
    }

    private static func prompt(job: TogentJob, role: TogentRole) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        这是从微信归档后进入 Togent 的单条用户任务。微信是唯一任务入口；不要将其与其他消息合并。

        收到时间：\(formatter.string(from: job.receivedAt))
        当前角色：\(role.name)
        当前工作区：\(role.workspacePath)
        项目分类根目录：\(role.workspacePath)/project

        用户消息：
        \(job.messageText)

        请遵循工作区 AGENTS.md。需要历史上下文时，仅按需只读查询微信归档；完成实际工作后给出适合直接回复微信的最终文本。
        """
    }
}
