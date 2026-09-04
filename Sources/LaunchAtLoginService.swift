import Foundation
import ServiceManagement

enum LaunchAtLoginRegistration: Equatable {
    case notEnabled
    case enabled
    case needsApproval
}

enum LaunchAtLoginError: Error, Equatable {
    case registerFailed
    case unregisterFailed
    case needsApproval
}

protocol LaunchAtLoginBacking {
    var registration: LaunchAtLoginRegistration { get }
    func register() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError>
    func unregister() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError>
    func openLoginItemsSettings()
}

protocol LaunchAtLoginControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError>
}

/// 以系统登录项为唯一权威；不另存 UserDefaults 开关。
struct LaunchAtLoginService: LaunchAtLoginControlling {
    static let menuTitle = "开机自启"

    let backend: LaunchAtLoginBacking

    init(backend: LaunchAtLoginBacking = SMAppLaunchAtLoginBackend()) {
        self.backend = backend
    }

    var isEnabled: Bool { backend.registration == .enabled }

    func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError> {
        if enabled {
            if isEnabled {
                return .success(())
            }
            switch backend.register() {
            case .success(.enabled):
                return .success(())
            case .success(.needsApproval):
                backend.openLoginItemsSettings()
                return .failure(.needsApproval)
            case .success:
                return .failure(.registerFailed)
            case .failure(.needsApproval):
                backend.openLoginItemsSettings()
                return .failure(.needsApproval)
            case .failure(let error):
                return .failure(error)
            }
        }
        if backend.registration == .notEnabled {
            return .success(())
        }
        switch backend.unregister() {
        case .success(let status) where status != .enabled:
            return .success(())
        case .success:
            return .failure(.unregisterFailed)
        case .failure(let error):
            return .failure(error)
        }
    }
}

struct SMAppLaunchAtLoginBackend: LaunchAtLoginBacking {
    var registration: LaunchAtLoginRegistration { Self.map(SMAppService.mainApp.status) }

    func register() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError> {
        do {
            if SMAppService.mainApp.status == .enabled {
                return .success(.enabled)
            }
            try SMAppService.mainApp.register()
            let mapped = Self.map(SMAppService.mainApp.status)
            if mapped == .needsApproval {
                return .failure(.needsApproval)
            }
            if mapped != .enabled {
                return .failure(.registerFailed)
            }
            return .success(mapped)
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                return .failure(.needsApproval)
            }
            return .failure(.registerFailed)
        }
    }

    func unregister() -> Result<LaunchAtLoginRegistration, LaunchAtLoginError> {
        do {
            if SMAppService.mainApp.status == .notRegistered {
                return .success(.notEnabled)
            }
            try SMAppService.mainApp.unregister()
            let mapped = Self.map(SMAppService.mainApp.status)
            if mapped == .enabled {
                return .failure(.unregisterFailed)
            }
            return .success(mapped)
        } catch {
            return .failure(.unregisterFailed)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> LaunchAtLoginRegistration {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .needsApproval
        default:
            return .notEnabled
        }
    }
}
