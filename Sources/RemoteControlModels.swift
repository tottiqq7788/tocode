import Foundation

enum RemoteControlAction: String, CaseIterable, Codable {
    case status
    case blackout
    case hidden
    case finderFollow = "finder-follow"
    case codexFollow = "codex-follow"
    case wheelVertical = "wheel-vertical"
    case wheelHorizontal = "wheel-horizontal"
    case finderMove = "finder-move"
    case finderCmdQ = "finder-cmdq"
    case doubleCmdQ = "double-cmdq"
    case login

    var commandBody: String {
        switch self {
        case .status: return "status"
        case .blackout: return "blackout"
        case .hidden: return "hidden toggle"
        case .finderFollow: return "root finder-follow toggle"
        case .codexFollow: return "codex sync toggle"
        case .wheelVertical: return "wheel vertical toggle"
        case .wheelHorizontal: return "wheel horizontal toggle"
        case .finderMove: return "shortcut finder-move toggle"
        case .finderCmdQ: return "shortcut finder-cmdq toggle"
        case .doubleCmdQ: return "shortcut double-cmdq toggle"
        case .login: return "login toggle"
        }
    }

    var title: String {
        switch self {
        case .status: return "设备状态"
        case .blackout: return "临时黑屏"
        case .hidden: return "隐藏文件"
        case .finderFollow: return "访达跟随"
        case .codexFollow: return "Codex 跟随"
        case .wheelVertical: return "垂直滚轮"
        case .wheelHorizontal: return "横向滚轮"
        case .finderMove: return "访达 X/V 移动"
        case .finderCmdQ: return "访达强退快捷键"
        case .doubleCmdQ: return "双击 Cmd-Q"
        case .login: return "开机自启"
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
