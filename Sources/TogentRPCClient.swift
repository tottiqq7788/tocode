import Foundation

struct TogentJSONLFramer {
    private(set) var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var records: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if record.last == 0x0D {
                record.removeLast()
            }
            if !record.isEmpty {
                records.append(record)
            }
        }
        return records
    }
}

final class TogentRPCClient: @unchecked Sendable {
    private final class PendingResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var record: [String: Any]?
        var error: Error?
    }

    private final class Settlement {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
    }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let commandTimeout: TimeInterval
    private let promptTimeout: TimeInterval
    private let executionQueue = DispatchQueue(label: "com.tocode.togent.rpc.execution")
    private let outputQueue = DispatchQueue(label: "com.tocode.togent.rpc.output")
    private let lock = NSLock()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutFramer = TogentJSONLFramer()
    private var pendingResponses: [String: PendingResponse] = [:]
    private var activeSettlement: Settlement?
    private var stderrTail = Data()
    private var terminalError: Error?
    private var stopping = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        commandTimeout: TimeInterval = 15,
        promptTimeout: TimeInterval = 15 * 60
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.commandTimeout = commandTimeout
        self.promptTimeout = promptTimeout
    }

    func start() throws {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return
        }
        process = nil
        stdinHandle = nil
        stdoutFramer = TogentJSONLFramer()
        pendingResponses.removeAll()
        activeSettlement = nil
        stderrTail.removeAll()
        terminalError = nil
        stopping = false
        lock.unlock()

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.handleTermination(process)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.outputQueue.async {
                self?.consumeStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw TogentError.runtimeLaunch(error.localizedDescription)
        }
        lock.lock()
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        do {
            _ = try sendCommand(type: "get_state", fields: [:])
        } catch {
            stop()
            throw error
        }
    }

    func promptAndWait(_ prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            executionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TogentError.runtimeExited("RPC 客户端已释放"))
                    return
                }
                do {
                    continuation.resume(returning: try self.performPrompt(prompt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let process = self.process
        let stdin = stdinHandle
        stdinHandle = nil
        lock.unlock()

        try? stdin?.close()
        guard let process, process.isRunning else { return }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private func performPrompt(_ prompt: String) throws -> String {
        let settlement = Settlement()
        lock.lock()
        if activeSettlement != nil {
            lock.unlock()
            throw TogentError.rpcProtocol("同一 RPC 进程收到并发 prompt")
        }
        activeSettlement = settlement
        lock.unlock()
        defer {
            lock.lock()
            if activeSettlement === settlement {
                activeSettlement = nil
            }
            lock.unlock()
        }

        let response = try sendCommand(
            type: "prompt",
            fields: ["message": prompt]
        )
        let disposition = (response["data"] as? [String: Any])?["disposition"] as? String
        if disposition != "handled" {
            let wait = settlement.semaphore.wait(
                timeout: .now() + promptTimeout
            )
            guard wait == .success else {
                stop()
                throw TogentError.rpcTimeout
            }
            if let error = settlement.error {
                throw error
            }
        }

        let final = try sendCommand(type: "get_last_assistant_text", fields: [:])
        let text = ((final["data"] as? [String: Any])?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            throw TogentError.emptyReply
        }
        return text
    }

    private func sendCommand(
        type: String,
        fields: [String: Any]
    ) throws -> [String: Any] {
        let id = UUID().uuidString
        var command = fields
        command["id"] = id
        command["type"] = type
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: command)
        } catch {
            throw TogentError.rpcProtocol("命令无法编码")
        }
        var framed = data
        framed.append(0x0A)

        let pending = PendingResponse()
        lock.lock()
        if let terminalError {
            lock.unlock()
            throw terminalError
        }
        guard let stdinHandle, process?.isRunning == true else {
            lock.unlock()
            throw TogentError.runtimeExited(stderrDescription())
        }
        pendingResponses[id] = pending
        lock.unlock()

        do {
            try stdinHandle.write(contentsOf: framed)
        } catch {
            lock.lock()
            pendingResponses.removeValue(forKey: id)
            lock.unlock()
            throw TogentError.runtimeExited(error.localizedDescription)
        }

        let wait = pending.semaphore.wait(timeout: .now() + commandTimeout)
        lock.lock()
        pendingResponses.removeValue(forKey: id)
        lock.unlock()
        guard wait == .success else {
            throw TogentError.rpcTimeout
        }
        if let error = pending.error {
            throw error
        }
        guard let record = pending.record else {
            throw TogentError.rpcProtocol("RPC 响应为空")
        }
        if record["success"] as? Bool != true {
            let message = record["error"] as? String ?? "未知 RPC 错误"
            throw TogentError.rpcProtocol(message)
        }
        return record
    }

    private func consumeStdout(_ data: Data) {
        lock.lock()
        let records = stdoutFramer.append(data)
        lock.unlock()
        for data in records {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let type = record["type"] as? String else {
                fail(TogentError.rpcProtocol("收到非 JSONL 协议输出"))
                continue
            }
            if type == "response", let id = record["id"] as? String {
                lock.lock()
                let pending = pendingResponses[id]
                pending?.record = record
                lock.unlock()
                pending?.semaphore.signal()
            } else if type == "agent_settled" {
                lock.lock()
                let settlement = activeSettlement
                lock.unlock()
                settlement?.semaphore.signal()
            }
        }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 32 * 1_024 {
            stderrTail.removeFirst(stderrTail.count - 32 * 1_024)
        }
        lock.unlock()
    }

    private func handleTermination(_ process: Process) {
        lock.lock()
        let wasStopping = stopping
        let message = stderrDescriptionLocked()
        let error: Error = wasStopping
            ? TogentError.runtimeExited("运行时已停止")
            : TogentError.runtimeExited(
                message.isEmpty
                    ? "退出码 \(process.terminationStatus)"
                    : message
            )
        terminalError = error
        let pending = Array(pendingResponses.values)
        let settlement = activeSettlement
        self.process = nil
        stdinHandle = nil
        lock.unlock()

        for response in pending {
            response.error = error
            response.semaphore.signal()
        }
        settlement?.error = error
        settlement?.semaphore.signal()
    }

    private func fail(_ error: Error) {
        lock.lock()
        terminalError = error
        let pending = Array(pendingResponses.values)
        let settlement = activeSettlement
        lock.unlock()
        for response in pending {
            response.error = error
            response.semaphore.signal()
        }
        settlement?.error = error
        settlement?.semaphore.signal()
    }

    private func stderrDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrDescriptionLocked()
    }

    private func stderrDescriptionLocked() -> String {
        String(data: stderrTail, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
