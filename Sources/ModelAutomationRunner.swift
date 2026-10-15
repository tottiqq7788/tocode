import AppKit
import Foundation
import UserNotifications

/// 读取选中文字、调用模型、写入剪贴板并粘贴。同一时间只跑一个。
final class ModelAutomationRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private let lookup: (UUID) -> ModelAutomation?
    private let readSelection: () async -> String?
    private let complete: (String, String, String) async throws -> String
    private let copy: (String) -> Void
    private let paste: () -> Bool
    private let notify: (String, String) -> Void
    var onFinish: (() -> Void)?

    init(
        lookup: @escaping (UUID) -> ModelAutomation?,
        readSelection: @escaping () async -> String?,
        complete: @escaping (String, String, String) async throws -> String,
        copy: @escaping (String) -> Void,
        paste: @escaping () -> Bool,
        notify: @escaping (String, String) -> Void
    ) {
        self.lookup = lookup
        self.readSelection = readSelection
        self.complete = complete
        self.copy = copy
        self.paste = paste
        self.notify = notify
    }

    func run(id: UUID) {
        lock.lock()
        if running {
            lock.unlock()
            notify("自动化正在执行", "上一个自动化还在执行。")
            return
        }
        guard let automation = lookup(id) else {
            lock.unlock()
            notify("自动化不存在", "这条自动化已经删除。没有调用模型，也没有改剪贴板。")
            return
        }
        running = true
        lock.unlock()
        Task {
            defer {
                lock.lock()
                running = false
                lock.unlock()
                onFinish?()
            }
            await perform(automation)
        }
    }

    private func perform(_ automation: ModelAutomation) async {
        guard let selected = await readSelection() else {
            notify("没有读到选中的文字", "请先选中要处理的文字。")
            return
        }
        let userText = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else {
            notify("没有读到选中的文字", "请先选中要处理的文字。")
            return
        }
        let body: String
        do {
            body = try await complete(automation.modelAlias, automation.prompt, userText)
        } catch {
            notify("自动化执行失败", error.localizedDescription)
            return
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notify("自动化没有结果", "模型没有返回可粘贴的正文。")
            return
        }
        copy(trimmed)
        if !paste() {
            notify("自动化粘贴失败", "结果已在剪贴板，但没有粘贴到当前输入位置。")
        }
    }
}

final class SystemSelectedTextReader: @unchecked Sendable {
    private let pasteboard: AutomationPasteboardReading
    private let copySelection: () -> Void
    private let timeout: TimeInterval
    private let sleep: (UInt64) async -> Void

    init(
        pasteboard: AutomationPasteboardReading = SystemAutomationPasteboard(),
        copySelection: @escaping () -> Void = { KeyboardEventSynthesizer().postCommandC() },
        timeout: TimeInterval = 0.4,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.pasteboard = pasteboard
        self.copySelection = copySelection
        self.timeout = timeout
        self.sleep = sleep
    }

    func readSelectedText() async -> String? {
        let before = pasteboard.changeCount
        copySelection()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.string()
            }
            await sleep(20_000_000)
        }
        return nil
    }
}

protocol AutomationPasteboardReading: AnyObject {
    var changeCount: Int { get }
    func string() -> String?
}

final class SystemAutomationPasteboard: AutomationPasteboardReading {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }
}

enum ModelAutomationNotification {
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.model-automation.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

enum ModelRelayAutomationClient {
    static func complete(
        modelAlias: String,
        systemPrompt: String,
        userText: String,
        router: ModelRelayRouter,
        client: ModelRelayUpstreamClient,
        metrics: ModelRelayCallMetricsRecording
    ) async throws -> String {
        let started = Date()
        let route: ModelRelayResolvedRoute
        do {
            route = try router.resolve(alias: modelAlias)
        } catch {
            throw ModelAutomationError.modelUnavailable
        }
        let candidate = route.candidates[0]
        do {
            let text = try await client.completeChat(
                route: route,
                systemPrompt: systemPrompt,
                userText: userText
            )
            router.recordSuccess(keyID: candidate.keyID)
            metrics.record(
                ModelRelayCallEvent(
                    timestamp: Date(),
                    route: "chat/completions",
                    providerID: candidate.providerID,
                    providerName: candidate.providerName,
                    publishedModel: modelAlias,
                    upstreamModel: candidate.upstreamModelID,
                    status: 200,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    ok: true
                )
            )
            return text
        } catch let error as ModelRelayError {
            switch error {
            case .upstreamHTTP(let status):
                router.recordFailure(keyID: candidate.keyID, statusCode: status)
            case .upstream:
                router.recordFailure(keyID: candidate.keyID, statusCode: nil)
            default:
                break
            }
            throw error
        }
    }
}
