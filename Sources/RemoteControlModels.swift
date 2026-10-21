import Foundation

enum RemoteControlAction: String, CaseIterable, Codable {
    case status
    case blackout
    case blackoutDismiss = "blackout-dismiss"
    case lock
    case desktops
    case desktopSwitch = "desktop-switch"

    var commandBody: String {
        switch self {
        case .status: return "status"
        case .blackout: return "blackout"
        case .blackoutDismiss, .lock, .desktops, .desktopSwitch: return ""
        }
    }

    var title: String {
        switch self {
        case .status: return "设备状态"
        case .blackout: return "临时黑屏"
        case .blackoutDismiss: return "取消黑屏"
        case .lock: return "锁定屏幕"
        case .desktops: return "桌面与窗口"
        case .desktopSwitch: return "切换桌面"
        }
    }
}

struct RemoteControlLink: Codable, Equatable {
    var linkID: String
    var androidID: String
    var androidName: String
}

struct RemoteControlRecord: Codable, Equatable {
    var relayURL: String
    var deviceID: String
    var deviceToken: String
    var links: [RemoteControlLink]

    static let empty = RemoteControlRecord(relayURL: "https://totti.xin", deviceID: "", deviceToken: "", links: [])
}

enum RemoteControlPayload {
    static func qr(relay: String, code: String) -> String {
        var parts = URLComponents()
        parts.scheme = "tocode-app"
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "relay", value: relay),
            URLQueryItem(name: "code", value: code)
        ]
        return parts.string ?? "tocode-app://pair?relay=\(relay)&code=\(code)"
    }
}
