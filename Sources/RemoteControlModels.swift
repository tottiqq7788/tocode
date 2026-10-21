import Foundation

enum RemoteControlAction: String, CaseIterable, Codable {
    case desktops
    case desktopSwitch = "desktop-switch"
    case remoteButtons = "remote-buttons"
    case remotePress = "remote-press"
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
