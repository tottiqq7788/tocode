import Foundation
import Network

/// 浏览器 Native Messaging 主机连入的本机 Unix 套接字桥。
final class BookmarkNativeBridge {
    static let socketFileName = "bookmark-sync.sock"
    static let hostName = "com.tocode.app.bookmark_sync"

    private let path: String
    private let queue = DispatchQueue(label: "com.tocode.bookmark.bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private weak var service: BookmarkSyncService?

    init(path: String = BookmarkNativeBridge.defaultSocketPath()) {
        self.path = path
    }

    static func defaultSocketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.tocode.app/\(socketFileName)").path
    }

    @MainActor
    func attach(service: BookmarkSyncService) {
        self.service = service
        service.onLedgerChanged = { [weak self] in
            Task { @MainActor in
                self?.broadcastLedger()
            }
        }
    }

    func start() throws {
        stop()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: self?.path ?? ""
                )
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let values = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        values.forEach { $0.connection.cancel() }
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func accept(_ connection: NWConnection) {
        let bridge = BridgeConnection(connection: connection)
        lock.lock()
        connections[ObjectIdentifier(bridge)] = bridge
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak bridge] state in
            guard let self, let bridge else { return }
            if case .failed = state {
                self.remove(bridge)
            }
            if case .cancelled = state {
                self.remove(bridge)
            }
        }
        connection.start(queue: queue)
        receive(on: bridge)
    }

    private func remove(_ bridge: BridgeConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(bridge))
        lock.unlock()
        if let key = bridge.browserKey {
            Task { @MainActor in
                self.service?.markBrowserDisconnected(key)
            }
        }
        bridge.connection.cancel()
    }

    private func receive(on bridge: BridgeConnection) {
        bridge.connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.remove(bridge)
                return
            }
            if let data, !data.isEmpty {
                bridge.buffer.append(data)
                self.drain(bridge)
            }
            if isComplete {
                self.remove(bridge)
                return
            }
            self.receive(on: bridge)
        }
    }

    private func drain(_ bridge: BridgeConnection) {
        while true {
            guard bridge.buffer.count >= 4 else { return }
            let length = bridge.buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard bridge.buffer.count >= 4 + Int(length) else { return }
            let payload = bridge.buffer.subdata(in: 4..<(4 + Int(length)))
            bridge.buffer.removeSubrange(0..<(4 + Int(length)))
            handle(payload: payload, from: bridge)
        }
    }

    private func handle(payload: Data, from bridge: BridgeConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = object["type"] as? String else {
            send(["type": "error", "message": "bad_json"], to: bridge)
            return
        }
        Task { @MainActor in
            await self.dispatch(type: type, object: object, bridge: bridge)
        }
    }

    @MainActor
    private func dispatch(type: String, object: [String: Any], bridge: BridgeConnection) async {
        guard let service else {
            send(["type": "error", "message": "service_unavailable"], to: bridge)
            return
        }
        do {
            switch type {
            case "hello":
                let browser = (object["browser"] as? String) ?? "unknown"
                let profile = (object["profile"] as? String) ?? "Default"
                let key = "\(browser):\(profile)"
                bridge.browserKey = key
                service.markBrowserConnected(key)
                send(["type": "hello_ok", "browserKey": key], to: bridge)
                sendLedger(to: bridge, service: service)
            case "tree":
                guard let key = bridge.browserKey else {
                    send(["type": "error", "message": "not_hello"], to: bridge)
                    return
                }
                let nodes = (object["nodes"] as? [[String: Any]]) ?? []
                try service.ingestBrowserTree(browserKey: key, nodes: nodes)
                send(["type": "tree_ok"], to: bridge)
                broadcastLedger()
            case "created":
                guard let key = bridge.browserKey,
                      let url = object["url"] as? String else { return }
                let title = (object["title"] as? String) ?? url
                let folder = folder(from: object["folder"])
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserCreate(
                    browserKey: key,
                    url: url,
                    title: title,
                    folder: folder,
                    updatedAt: updatedAt
                )
                broadcastLedger()
            case "updated":
                guard let url = object["url"] as? String else { return }
                let title = object["title"] as? String
                let folderValue = object["folder"] != nil ? folder(from: object["folder"]) : nil
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserUpdate(
                    url: url,
                    title: title,
                    folder: folderValue,
                    updatedAt: updatedAt
                )
                broadcastLedger()
            case "changed_url":
                guard let oldURL = object["oldUrl"] as? String,
                      let newURL = object["newUrl"] as? String else { return }
                let title = object["title"] as? String
                let folderValue = object["folder"] != nil ? folder(from: object["folder"]) : nil
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserChangeURL(
                    from: oldURL,
                    to: newURL,
                    title: title,
                    folder: folderValue,
                    updatedAt: updatedAt
                )
                broadcastLedger()
            case "deleted":
                guard let url = object["url"] as? String else { return }
                try service.applyBrowserDelete(url: url)
                broadcastLedger()
            case "ping":
                send(["type": "pong"], to: bridge)
            default:
                send(["type": "error", "message": "unknown_type"], to: bridge)
            }
        } catch {
            send(["type": "error", "message": error.localizedDescription], to: bridge)
        }
    }

    private func folder(from raw: Any?) -> BookmarkFolderPath {
        guard let dict = raw as? [String: Any],
              let kindRaw = dict["kind"] as? String,
              let kind = BookmarkFolderKind(rawValue: kindRaw) else {
            return BookmarkFolderPath(kind: .other, segments: [])
        }
        let segments = (dict["segments"] as? [String]) ?? []
        return BookmarkFolderPath(kind: kind, segments: segments)
    }

    @MainActor
    private func sendLedger(to bridge: BridgeConnection, service: BookmarkSyncService) {
        let entries = service.entriesForBrowser().map { entry -> [String: Any] in
            [
                "id": entry.id,
                "url": entry.url,
                "title": entry.title,
                "folder": [
                    "kind": entry.folder.kind.rawValue,
                    "segments": entry.folder.segments
                ],
                "updatedAt": entry.updatedAt
            ]
        }
        send(["type": "ledger", "batch": UUID().uuidString, "entries": entries], to: bridge)
    }

    @MainActor
    private func broadcastLedger() {
        guard let service else { return }
        lock.lock()
        let values = Array(connections.values)
        lock.unlock()
        for bridge in values {
            sendLedger(to: bridge, service: service)
        }
    }

    private func send(_ object: [String: Any], to bridge: BridgeConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        bridge.connection.send(content: packet, completion: .contentProcessed { _ in })
    }
}

private final class BridgeConnection {
    let connection: NWConnection
    var buffer = Data()
    var browserKey: String?

    init(connection: NWConnection) {
        self.connection = connection
    }
}
