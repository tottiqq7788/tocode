import AppKit
import Darwin
import Foundation

enum CodexRestartError: LocalizedError, Equatable {
    case signalFailed(pid_t, Int32)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .signalFailed:
            return "无法强制退出 Codex"
        case .launchFailed:
            return "模型已切换，但 Codex 重新启动失败"
        }
    }
}

protocol CodexApplicationRestarting {
    func forceRestart(after delay: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void)
}

struct CodexSignalResult: Equatable {
    enum Status: Equatable {
        case sent
        case alreadyExited
        case failed(Int32)
    }
    let status: Status
}

final class CodexApplicationRestarter: CodexApplicationRestarting {
    typealias PIDProvider = () -> [pid_t]
    typealias SignalSender = (pid_t) -> CodexSignalResult
    typealias ProcessChecker = (pid_t) -> Bool
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    typealias Launcher = (@escaping (Result<Void, Error>) -> Void) -> Void

    private let pidProvider: PIDProvider
    private let signalSender: SignalSender
    private let processChecker: ProcessChecker
    private let scheduler: Scheduler
    private let launcher: Launcher

    init(
        pidProvider: @escaping PIDProvider = CodexApplicationRestarter.runningCodexPIDs,
        signalSender: @escaping SignalSender = CodexApplicationRestarter.sendKill,
        processChecker: @escaping ProcessChecker = CodexApplicationRestarter.processExists,
        scheduler: @escaping Scheduler = { delay, work in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + delay,
                execute: work
            )
        },
        launcher: @escaping Launcher = CodexApplicationRestarter.launchCodex
    ) {
        self.pidProvider = pidProvider
        self.signalSender = signalSender
        self.processChecker = processChecker
        self.scheduler = scheduler
        self.launcher = launcher
    }

    func forceRestart(after delay: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        if pidProvider().isEmpty {
            launcher(completion)
            return
        }

        scheduler(delay) { [pidProvider, signalSender, processChecker, launcher] in
            let pids = pidProvider()
            if pids.isEmpty {
                launcher(completion)
                return
            }

            for pid in pids {
                let result = signalSender(pid)
                if case .failed(let code) = result.status {
                    completion(.failure(CodexRestartError.signalFailed(pid, code)))
                    return
                }
            }

            while pids.contains(where: processChecker) {
                usleep(50_000)
            }
            launcher(completion)
        }
    }

    private static func runningCodexPIDs() -> [pid_t] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .map(\.processIdentifier)
    }

    private static func sendKill(_ pid: pid_t) -> CodexSignalResult {
        if Darwin.kill(pid, SIGKILL) == 0 {
            return CodexSignalResult(status: .sent)
        }
        if errno == ESRCH {
            return CodexSignalResult(status: .alreadyExited)
        }
        return CodexSignalResult(status: .failed(errno))
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return !application.isTerminated
            && application.bundleIdentifier == "com.openai.codex"
    }

    private static func launchCodex(completion: @escaping (Result<Void, Error>) -> Void) {
        let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    completion(.failure(CodexRestartError.launchFailed(error.localizedDescription)))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
}
