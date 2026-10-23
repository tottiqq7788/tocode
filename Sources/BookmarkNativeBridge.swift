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
        // 远程合并等整本变化时全量下发；单条增删改走 upsert/remove，避免大快照竞态漏写。
        service.onLedgerChanged = { [weak self] in
            Task { @MainActor in
                self?.broadcastLedger()
            }
        }
        service.onEntryUpserted = { [weak self] entry in
            Task { @MainActor in
                self?.broadcastUpsert(entry)
            }
        }
        service.onURLRemoved = { [weak self] url in
            Task { @MainActor in
                self?.broadcastRemove(url: url)
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
                // 不在 hello 时下发整本快照：等 tree_ok 后只补缺失，避免大包打断连接。
            case "tree":
                guard let key = bridge.browserKey else {
                    send(["type": "error", "message": "not_hello"], to: bridge)
                    return
                }
                let nodes = (object["nodes"] as? [[String: Any]]) ?? []
                bridge.pendingBeforeURLs = Set(service.entriesForBrowser().map(\.url))
                try service.ingestBrowserTree(browserKey: key, nodes: nodes)
                let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
                // 浏览器可对同一 URL 留多份；指纹取 siblingIndex 较小的一份。
                var layoutMap: [String: String] = [:]
                for entry in layout.entries.sorted(by: { $0.siblingIndex < $1.siblingIndex }) {
                    if layoutMap[entry.url] == nil {
                        layoutMap[entry.url] = Self.fingerprint(
                            folder: entry.folder,
                            index: entry.siblingIndex,
                            title: entry.title
                        )
                    }
                }
                bridge.knownLayout = layoutMap
                bridge.knownFolderKeys = Set(layout.folders.map(\.pathKey))
                bridge.awaitingTreeReady = true
                send(["type": "tree_ok"], to: bridge)
                // 等扩展回 tree_ready；旧版扩展不会回，2 秒后仍做布局对账。
                let readyBridge = bridge
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, readyBridge.awaitingTreeReady else { return }
                    readyBridge.awaitingTreeReady = false
                    service.activityLog.append(
                        "扩展未确认下行（\(readyBridge.browserKey ?? "?")）：仍尝试布局对账（请重新加载扩展以启用 tree_ready）"
                    )
                    self.finishTreeReady(bridge: readyBridge, service: service)
                }
            case "created":
                guard let key = bridge.browserKey,
                      let url = object["url"] as? String else { return }
                let title = (object["title"] as? String) ?? url
                let folder = folder(from: object["folder"])
                let siblingIndex = (object["index"] as? Int)
                    ?? (object["siblingIndex"] as? Int)
                    ?? 0
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserCreate(
                    browserKey: key,
                    url: url,
                    title: title,
                    folder: folder,
                    siblingIndex: siblingIndex,
                    updatedAt: updatedAt
                )
            case "updated":
                guard let url = object["url"] as? String else { return }
                let title = object["title"] as? String
                let folderValue = object["folder"] != nil ? folder(from: object["folder"]) : nil
                let siblingIndex = object["index"] as? Int ?? object["siblingIndex"] as? Int
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserUpdate(
                    url: url,
                    title: title,
                    folder: folderValue,
                    siblingIndex: siblingIndex,
                    updatedAt: updatedAt
                )
            case "changed_url":
                guard let oldURL = object["oldUrl"] as? String,
                      let newURL = object["newUrl"] as? String else { return }
                let title = object["title"] as? String
                let folderValue = object["folder"] != nil ? folder(from: object["folder"]) : nil
                let siblingIndex = object["index"] as? Int ?? object["siblingIndex"] as? Int
                let updatedAt = (object["updatedAt"] as? Double) ?? Date().timeIntervalSince1970
                try service.applyBrowserChangeURL(
                    from: oldURL,
                    to: newURL,
                    title: title,
                    folder: folderValue,
                    siblingIndex: siblingIndex,
                    updatedAt: updatedAt
                )
            case "deleted":
                guard let url = object["url"] as? String else { return }
                try service.applyBrowserDelete(url: url)
            case "tree_ready":
                guard bridge.awaitingTreeReady else { return }
                bridge.awaitingTreeReady = false
                service.activityLog.append("扩展下行就绪：\(bridge.browserKey ?? "?")")
                finishTreeReady(bridge: bridge, service: service)
            case "apply_error":
                let op = (object["op"] as? String) ?? "?"
                let url = (object["url"] as? String) ?? ""
                let message = (object["message"] as? String) ?? ""
                noteBatchAck(bridge: bridge, object: object)
                // 越界等不可恢复错误：按账本指纹记入已知，避免死循环重试同一非法 index。
                if message.localizedCaseInsensitiveContains("Index out of bounds"),
                   let canonical = BookmarkURL.canonicalize(url),
                   let entry = service.entry(url: canonical) {
                    bridge.knownLayout[canonical] = Self.fingerprint(
                        folder: entry.folder,
                        index: entry.siblingIndex,
                        title: entry.title
                    )
                }
                service.activityLog.append("扩展写回失败（\(bridge.browserKey ?? "?") \(op)）：\(url) \(message)")
            case "apply_result":
                let op = (object["op"] as? String) ?? "?"
                let url = (object["url"] as? String) ?? ""
                noteBatchAck(bridge: bridge, object: object)
                if op == "folder_ensured",
                   let folderDict = object["folder"] as? [String: Any] {
                    let path = folder(from: folderDict)
                    bridge.knownFolderKeys.insert(path.sortKey)
                } else if let canonical = BookmarkURL.canonicalize(url),
                          op == "created" || op == "updated" || op == "exists",
                          let entry = service.entry(url: canonical) {
                    bridge.knownLayout[canonical] = Self.fingerprint(
                        folder: entry.folder,
                        index: entry.siblingIndex,
                        title: entry.title
                    )
                }
                service.activityLog.append(
                    "扩展写回结果（\(bridge.browserKey ?? "?")）：\(op) \(url)"
                )
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
    private func finishTreeReady(bridge: BridgeConnection, service: BookmarkSyncService) {
        // 其它连接靠各自串行对账对齐；不再广播 newlyJoined，避免对账风暴。
        bridge.pendingBeforeURLs = []
        requestReconcile(bridge: bridge, service: service)
    }

    /// 请求对账：已在跑则只标 dirty，由串行泵消化。
    @MainActor
    private func requestReconcile(bridge: BridgeConnection, service: BookmarkSyncService) {
        if bridge.isReconciling {
            bridge.needsReconcileAgain = true
            return
        }
        bridge.isReconciling = true
        bridge.needsReconcileAgain = false
        bridge.reconcileGeneration &+= 1
        let generation = bridge.reconcileGeneration
        Task { @MainActor [weak self] in
            await self?.runReconcilePump(bridge: bridge, service: service, generation: generation)
        }
    }

    @MainActor
    private func runReconcilePump(bridge: BridgeConnection, service: BookmarkSyncService, generation: UInt64) async {
        defer {
            if bridge.reconcileGeneration == generation {
                bridge.isReconciling = false
                if bridge.needsReconcileAgain {
                    bridge.needsReconcileAgain = false
                    requestReconcile(bridge: bridge, service: service)
                }
            }
        }
        while bridge.reconcileGeneration == generation {
            let done = await sendOneReconcileBatch(bridge: bridge, service: service, generation: generation)
            if done { break }
            // 短歇再续，避免打满 native 通道。
            try? await Task.sleep(nanoseconds: 400_000_000)
            if bridge.reconcileGeneration != generation { break }
        }
    }

    /// 发一批并等待回执/超时。返回 true 表示已对齐、泵可结束。
    @MainActor
    private func sendOneReconcileBatch(
        bridge: BridgeConnection,
        service: BookmarkSyncService,
        generation: UInt64
    ) async -> Bool {
        let wanted = service.entriesForBrowser().sorted {
            if $0.folder.sortKey != $1.folder.sortKey {
                return $0.folder.sortKey < $1.folder.sortKey
            }
            return $0.siblingIndex < $1.siblingIndex
        }
        let divergent = wanted.filter { entry in
            let fp = Self.fingerprint(folder: entry.folder, index: entry.siblingIndex, title: entry.title)
            return bridge.knownLayout[entry.url] != fp
        }
        let missingFolders = service.foldersForBrowser().filter { !bridge.knownFolderKeys.contains($0.pathKey) }
        let target = bridge.browserKey ?? "未命名连接"
        if divergent.isEmpty && missingFolders.isEmpty {
            service.activityLog.append("布局对账 \(target)：已对齐。")
            return true
        }
        // 每批：最多 10 空夹 + 30 书签，避免空夹饥饿。
        let folderBatch = Array(missingFolders.prefix(10))
        let batchEntries = Array(divergent.prefix(30))
        let remain = (divergent.count - batchEntries.count) + (missingFolders.count - folderBatch.count)
        service.activityLog.append(
            "布局对账 \(target)：纠偏 \(divergent.count) 条、空夹 \(missingFolders.count) 个，本批书签 \(batchEntries.count)、空夹 \(folderBatch.count)\(remain > 0 ? "，剩余待下次" : "")。"
        )
        let batch = UUID().uuidString
        let expect = folderBatch.count + batchEntries.count
        bridge.pendingBatchID = batch
        bridge.pendingBatchRemaining = expect
        for folder in folderBatch {
            send(
                [
                    "type": "ensure_folder",
                    "batch": batch,
                    "folder": [
                        "kind": folder.path.kind.rawValue,
                        "segments": folder.path.segments
                    ],
                    "index": folder.siblingIndex
                ],
                to: bridge
            )
        }
        for entry in batchEntries {
            send(["type": "upsert", "batch": batch, "entry": Self.entryPayload(entry)], to: bridge)
        }
        if expect == 0 { return remain == 0 }
        let deadline = Date().addingTimeInterval(8)
        while bridge.pendingBatchRemaining > 0, Date() < deadline {
            if bridge.reconcileGeneration != generation { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if bridge.pendingBatchID == batch {
            bridge.pendingBatchID = nil
            bridge.pendingBatchRemaining = 0
        }
        return false
    }

    @MainActor
    private func noteBatchAck(bridge: BridgeConnection, object: [String: Any]) {
        guard let batch = object["batch"] as? String,
              batch == bridge.pendingBatchID,
              bridge.pendingBatchRemaining > 0 else { return }
        bridge.pendingBatchRemaining -= 1
    }

    @MainActor
    private func broadcastLedger() {
        guard let service else { return }
        lock.lock()
        let values = Array(connections.values)
        lock.unlock()
        for bridge in values where !bridge.awaitingTreeReady {
            // 不扫荡 knownLayout；只请求串行再对账。
            requestReconcile(bridge: bridge, service: service)
        }
    }

    @MainActor
    private func broadcastUpsert(_ entry: BookmarkEntry, excluding excluded: BridgeConnection? = nil) {
        guard let service else { return }
        lock.lock()
        let values = Array(connections.values)
        lock.unlock()
        let batch = UUID().uuidString
        let payload = Self.entryPayload(entry)
        let fp = Self.fingerprint(folder: entry.folder, index: entry.siblingIndex, title: entry.title)
        for bridge in values where bridge !== excluded {
            let target = bridge.browserKey ?? "未命名连接"
            if bridge.knownLayout[entry.url] == fp { continue }
            service.activityLog.append(
                "增量写回 → \(target)：\(entry.title)（\(entry.folder.kind.rawValue) #\(entry.siblingIndex)）"
            )
            send(["type": "upsert", "batch": batch, "entry": payload], to: bridge)
        }
    }

    @MainActor
    private func broadcastRemove(url: String) {
        guard let service else { return }
        lock.lock()
        let values = Array(connections.values)
        lock.unlock()
        let batch = UUID().uuidString
        let canonical = BookmarkURL.canonicalize(url) ?? url
        for bridge in values {
            let target = bridge.browserKey ?? "未命名连接"
            service.activityLog.append("增量删除 → \(target)：\(url)")
            send(["type": "remove", "batch": batch, "url": url], to: bridge)
            bridge.knownLayout.removeValue(forKey: canonical)
        }
    }

    private static func fingerprint(folder: BookmarkFolderPath, index: Int, title: String) -> String {
        "\(folder.sortKey)|\(index)|\(title)"
    }

    private static func entryPayload(_ entry: BookmarkEntry) -> [String: Any] {
        [
            "id": entry.id,
            "url": entry.url,
            "title": entry.title,
            "folder": [
                "kind": entry.folder.kind.rawValue,
                "segments": entry.folder.segments
            ],
            "siblingIndex": entry.siblingIndex,
            "index": entry.siblingIndex,
            "updatedAt": entry.updatedAt
        ]
    }

    private func send(_ object: [String: Any], to bridge: BridgeConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        bridge.connection.send(content: packet, completion: .contentProcessed { [weak self, weak bridge] error in
            guard let self, let bridge else { return }
            if error != nil {
                self.remove(bridge)
            }
        })
    }
}

private final class BridgeConnection {
    let connection: NWConnection
    var buffer = Data()
    var browserKey: String?
    /// url → folder|index|title 指纹；仅在 apply_result 成功后更新。
    var knownLayout: [String: String] = [:]
    var knownFolderKeys: Set<String> = []
    var awaitingTreeReady = false
    var pendingBeforeURLs: Set<String> = []
    var isReconciling = false
    var needsReconcileAgain = false
    var reconcileGeneration: UInt64 = 0
    var pendingBatchID: String?
    var pendingBatchRemaining = 0

    init(connection: NWConnection) {
        self.connection = connection
    }
}
