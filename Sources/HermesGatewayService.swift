import AppKit
import Foundation

enum HermesGatewayPhase: Equatable {
    case off
    case starting
    case running
    case failed
}

@MainActor
protocol HermesGatewayProcess: AnyObject {
    var isRunning: Bool { get }
    var onExit: ((Int32) -> Void)? { get set }
    func terminate()
    func waitUntilExit(seconds: TimeInterval) -> Bool
}

@MainActor
protocol HermesGatewayLaunching: AnyObject {
    func launch(arguments: [String]) -> HermesGatewayProcess
    /// 只停止 Hermes 网关。不得改去结束桌面端的 hermes serve。
    func stopManagedGateways()
}

protocol HermesGatewayCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol HermesGatewayScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> HermesGatewayCancellable
}

@MainActor
protocol HermesGatewayChecking: AnyObject {
    func isHealthy() -> Bool
}

@MainActor
protocol HermesGatewayControlling: AnyObject {
    var isInstalled: Bool { get }
    var phase: HermesGatewayPhase { get }
    func toggle()
}

/// 跟随 Tocode 启动和退出 Hermes 网关。偏好为开时，意外退出会再试，连续失败后停住。
@MainActor
final class HermesGatewayService: HermesGatewayControlling {
    static let preferenceKey = "tocode.hermesGatewayEnabled"
    static let maxFailures = 3
    static let restartDelay: TimeInterval = 5
    static let pollDelay: TimeInterval = 1
    static let stopWait: TimeInterval = 3

    private let defaults: UserDefaults
    private let launcher: HermesGatewayLaunching
    private let scheduler: HermesGatewayScheduling
    private let health: HermesGatewayChecking
    private let ensureEnv: () throws -> Void
    private let binary: () -> String?
    private let installed: () -> Bool
    private var process: HermesGatewayProcess?
    private var restartTask: HermesGatewayCancellable?
    private var pollTask: HermesGatewayCancellable?
    private var failureCount = 0
    private var generation = 0

    private(set) var phase: HermesGatewayPhase = .off
    var onChange: (() -> Void)?

    var isInstalled: Bool { installed() }

    var preferenceEnabled: Bool {
        get { defaults.bool(forKey: Self.preferenceKey) }
        set { defaults.set(newValue, forKey: Self.preferenceKey) }
    }

    init(
        defaults: UserDefaults = TocodePreferences.shared,
        launcher: HermesGatewayLaunching,
        scheduler: HermesGatewayScheduling,
        health: HermesGatewayChecking,
        ensureEnv: @escaping () throws -> Void,
        binary: @escaping () -> String?,
        installed: @escaping () -> Bool
    ) {
        self.defaults = defaults
        self.launcher = launcher
        self.scheduler = scheduler
        self.health = health
        self.ensureEnv = ensureEnv
        self.binary = binary
        self.installed = installed
    }

    convenience init() {
        let envURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env")
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/logs/gateway.log")
        self.init(
            launcher: LiveHermesGatewayLauncher(logURL: logURL),
            scheduler: MainHermesGatewayScheduler(),
            health: LiveHermesGatewayHealth(envText: {
                (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
            }),
            ensureEnv: { try HermesGatewayEnv.ensure(at: envURL) },
            binary: {
                HermesGatewayBinary.resolve(home: NSHomeDirectory()) { FileManager.default.isExecutableFile(atPath: $0) }
            },
            installed: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nousresearch.hermes") != nil
            }
        )
    }

    func applySavedPreference() {
        if preferenceEnabled {
            start()
        } else {
            phase = .off
        }
    }

    func toggle() {
        if preferenceEnabled {
            turnOff()
        } else {
            turnOn()
        }
    }

    func turnOn() {
        preferenceEnabled = true
        failureCount = 0
        start()
    }

    func turnOff() {
        preferenceEnabled = false
        stopProcesses()
        phase = .off
        changed()
    }

    /// 退出 Tocode 时停掉网关，但保留偏好，下次启动还会打开。
    func shutdown() {
        stopProcesses()
        phase = .off
        changed()
    }

    private func start() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        let token = generation
        let previous = process
        process = nil
        previous?.onExit = nil
        if previous?.isRunning == true {
            previous?.terminate()
        }
        guard installed(), let binary = binary() else {
            failWithoutRetry()
            return
        }
        do {
            try ensureEnv()
        } catch {
            NSLog("Tocode 补齐 Hermes API Server 配置失败")
            failWithoutRetry()
            return
        }
        let launched = launcher.launch(arguments: [binary, "gateway", "run", "--replace"])
        process = launched
        phase = .starting
        changed()
        launched.onExit = { [weak self] _ in
            self?.handleExit(token: token)
        }
        if !launched.isRunning {
            handleExit(token: token)
            return
        }
        schedulePoll(token: token)
    }

    private func handleExit(token: Int) {
        guard token == generation else { return }
        process = nil
        pollTask?.cancel()
        pollTask = nil
        guard preferenceEnabled else {
            phase = .off
            changed()
            return
        }
        failureCount += 1
        if failureCount >= Self.maxFailures {
            phase = .failed
            changed()
            return
        }
        phase = .starting
        changed()
        restartTask = scheduler.schedule(after: Self.restartDelay) { [weak self] in
            guard let self, self.generation == token, self.preferenceEnabled else { return }
            self.start()
        }
    }

    private func schedulePoll(token: Int) {
        pollTask?.cancel()
        pollTask = scheduler.schedule(after: Self.pollDelay) { [weak self] in
            self?.poll(token: token)
        }
    }

    private func poll(token: Int) {
        guard token == generation, preferenceEnabled, process?.isRunning == true else { return }
        if health.isHealthy() {
            if phase != .running {
                failureCount = 0
                phase = .running
                changed()
            }
        } else if phase == .running {
            phase = .starting
            changed()
        }
        schedulePoll(token: token)
    }

    private func failWithoutRetry() {
        phase = .failed
        changed()
    }

    private func stopProcesses() {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        pollTask?.cancel()
        pollTask = nil
        failureCount = 0
        let current = process
        process = nil
        current?.onExit = nil
        if current?.isRunning == true {
            current?.terminate()
            _ = current?.waitUntilExit(seconds: Self.stopWait)
        }
        launcher.stopManagedGateways()
    }

    private func changed() {
        onChange?()
    }
}

enum HermesGatewayLaunchScript {
    /// 父进程消失或收到停止信号时，结束网关。二进制路径只作为参数，不拼进脚本。
    static let source = """
    parent=$PPID
    child=
    trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child"; fi; exit 0' TERM INT HUP
    "$1" gateway run --replace &
    child=$!
    while kill -0 "$parent" 2>/dev/null; do
      if ! kill -0 "$child" 2>/dev/null; then
        wait "$child"
        exit $?
      fi
      sleep 0.3
    done
    kill -TERM "$child" 2>/dev/null
    "$1" gateway stop >/dev/null 2>&1
    wait "$child" 2>/dev/null
    """
}

@MainActor
private final class LiveHermesGatewayLauncher: HermesGatewayLaunching {
    private let logURL: URL

    init(logURL: URL) {
        self.logURL = logURL
    }

    func launch(arguments: [String]) -> HermesGatewayProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HermesGatewayLaunchScript.source, "hermes-gateway", arguments[0]]
        if let handle = logHandle() {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            NSLog("Tocode 启动 Hermes 网关失败")
            return LiveHermesGatewayProcess(process: nil)
        }
        return LiveHermesGatewayProcess(process: process)
    }

    func stopManagedGateways() {
        guard let binary = HermesGatewayBinary.resolve(home: NSHomeDirectory(), exists: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["gateway", "stop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Tocode 停止 Hermes 网关失败")
        }
    }

    private func logHandle() -> FileHandle? {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}

@MainActor
private final class LiveHermesGatewayProcess: HermesGatewayProcess {
    private let process: Process?
    var onExit: ((Int32) -> Void)?

    init(process: Process?) {
        self.process = process
        process?.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onExit?(code)
                }
            }
        }
    }

    var isRunning: Bool { process?.isRunning == true }

    func terminate() {
        if isRunning { process?.terminate() }
    }

    func waitUntilExit(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }
}

@MainActor
private final class MainHermesGatewayScheduler: HermesGatewayScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> HermesGatewayCancellable {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in work() }
        RunLoop.main.add(timer, forMode: .common)
        return HermesGatewayTimer(timer)
    }
}

private final class HermesGatewayTimer: HermesGatewayCancellable {
    private var timer: Timer?

    init(_ timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
private final class LiveHermesGatewayHealth: HermesGatewayChecking {
    private let envText: () -> String
    private let session: URLSession
    private var healthy = false
    private var inflight = false

    init(envText: @escaping () -> String, session: URLSession = .shared) {
        self.envText = envText
        self.session = session
    }

    func isHealthy() -> Bool {
        begin()
        return healthy
    }

    private func begin() {
        guard !inflight else { return }
        let port = PhoneHermesEnvironment.port(from: envText())
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            healthy = false
            return
        }
        inflight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        session.dataTask(with: request) { [weak self] data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && json?["status"] as? String == "ok"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.healthy = ok
                    self?.inflight = false
                }
            }
        }.resume()
    }
}
