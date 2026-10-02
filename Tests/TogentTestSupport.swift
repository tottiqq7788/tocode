import Foundation

final class StubTogentRuntime: TogentRuntimeExecuting, @unchecked Sendable {
    private let lock = NSLock()
    var result: Result<String, Error> = .success("完成")
    var delayNanoseconds: UInt64 = 0
    var onExecute: (() -> Void)?
    private(set) var executions: [(TogentRole, String)] = []
    private(set) var stoppedRoleIDs: [UUID] = []
    private var storedStopAllCount = 0

    var stopAllCount: Int {
        lock.withStubLock { storedStopAllCount }
    }

    func execute(role: TogentRole, prompt: String) async throws -> String {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let (value, callback) = lock.withStubLock { () -> (Result<String, Error>, (() -> Void)?) in
            executions.append((role, prompt))
            return (result, onExecute)
        }
        callback?()
        return try value.get()
    }

    func stop(roleID: UUID) async {
        lock.withStubLock {
            stoppedRoleIDs.append(roleID)
        }
    }

    func stopAll() async {
        lock.withStubLock {
            storedStopAllCount += 1
        }
    }
}

func makeTogentTemporaryDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tocode-togent-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeTogentRole(
    name: String = "角色",
    workspace: URL,
    modelID: String = "model-a",
    active: Bool = true
) -> TogentRole {
    TogentRole(
        name: name,
        workspacePath: workspace.path,
        prompt: "认真完成任务",
        publishedModelID: modelID,
        isActive: active
    )
}

@MainActor
func waitForTogentCondition(
    timeout: TimeInterval = 3,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private extension NSLock {
    func withStubLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
