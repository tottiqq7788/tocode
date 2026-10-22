import Foundation
import LocalAuthentication

enum DeviceOwnerAuthError: Error, LocalizedError {
    case unavailable
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "本机无法使用 Touch ID 或设备密码验证。"
        case .failed:
            return "设备验证未通过。"
        }
    }
}

enum DeviceOwnerAuth {
    @MainActor
    static func evaluate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw DeviceOwnerAuthError.unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { throw DeviceOwnerAuthError.failed }
        } catch is DeviceOwnerAuthError {
            throw DeviceOwnerAuthError.failed
        } catch {
            throw DeviceOwnerAuthError.failed
        }
    }
}
