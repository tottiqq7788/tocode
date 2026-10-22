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
    /// SHA-256 hex digest of the Mac binding key; plaintext lives in Keychain.
    var bindingKeyDigest: String?

    static let empty = RemoteControlRecord(
        relayURL: "https://totti.xin",
        deviceID: "",
        deviceToken: "",
        links: [],
        bindingKeyDigest: nil
    )

    var hasBindingKey: Bool {
        guard let bindingKeyDigest else { return false }
        return bindingKeyDigest.count == 64
    }

    enum CodingKeys: String, CodingKey {
        case relayURL, deviceID, deviceToken, links, bindingKeyDigest
    }

    init(
        relayURL: String,
        deviceID: String,
        deviceToken: String,
        links: [RemoteControlLink],
        bindingKeyDigest: String? = nil
    ) {
        self.relayURL = relayURL
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.links = links
        self.bindingKeyDigest = bindingKeyDigest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relayURL = try values.decode(String.self, forKey: .relayURL)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        deviceToken = try values.decode(String.self, forKey: .deviceToken)
        links = try values.decodeIfPresent([RemoteControlLink].self, forKey: .links) ?? []
        bindingKeyDigest = try values.decodeIfPresent(String.self, forKey: .bindingKeyDigest)
    }
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
