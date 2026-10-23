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
    private var connections: [ObjectIdentifier: BookmarkBridgeConnection] = [:]
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
        service.liveConnectedBrowserKeysProvider = { [weak self] in
            self?.liveConnectedBrowserKeys() ?? []
        }
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
        let bridge = BookmarkBridgeConnection(connection: connection)
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

    /// 当前已 hello 的活连接 browserKey（去重排序）。菜单勾选与 CLI status 以此为准。
    func liveConnectedBrowserKeys() -> [String] {
        lock.lock()
        let keys = connections.values.map(\.browserKey)
        lock.unlock()
        return BookmarkOnlinePresence.uniqueSortedKeys(from: keys)
    }

    private func remove(_ bridge: BookmarkBridgeConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(bridge))
        let remainingKeys = connections.values.compactMap(\.browserKey)
        lock.unlock()
        let key = bridge.browserKey
        // 同 key 仍有其它 bridge 时不得标离线（重载/双 host 误伤）。
        if let key,
           BookmarkOnlinePresence.shouldMarkOffline(removedKey: key, remainingKeys: remainingKeys) {
            Task { @MainActor in
                self.service?.markBrowserDisconnected(key)
            }
        }
        bridge.connection.cancel()
    }

    private func receive(on bridge: BookmarkBridgeConnection) {
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

    private func drain(_ bridge: BookmarkBridgeConnection) {
        while true {
            guard bridge.buffer.count >= 4 else { return }
            let length = bridge.buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard bridge.buffer.count >= 4 + Int(length) else { return }
            let payload = bridge.buffer.subdata(in: 4..<(4 + Int(length)))
            bridge.buffer.removeSubrange(0..<(4 + Int(length)))
            handle(payload: payload, from: bridge)
        }
    }

    private func handle(payload: Data, from bridge: BookmarkBridgeConnection) {
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
    private func dispatch(type: String, object: [String: Any], bridge: BookmarkBridgeConnection) async {
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
                // 取消旧对账泵，避免 tree 重入后旧批写回。
                bridge.reconcileGeneration &+= 1
                bridge.isReconciling = false
                bridge.needsReconcileAgain = false
                bridge.pendingBatchID = nil
                bridge.pendingBatchRemaining = 0
                bridge.pendingPurgeBatch = false
                bridge.pendingFolderRemovalKeys.removeAll()
                let nodes = (object["nodes"] as? [[String: Any]]) ?? []
                bridge.pendingBeforeURLs = Set(service.entriesForBrowser().map(\.url))
                try service.ingestBrowserTree(browserKey: key, nodes: nodes)
                let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
                // 浏览器可对同一 URL 留多份；指纹取 siblingIndex 较小的一份。
                var layoutMap: [String: String] = [:]
                for entry in layout.entries.sorted(by: { $0.siblingIndex < $1.siblingIndex }) {
                    if layoutMap[entry.url] == nil {
                        layoutMap[entry.url] = BookmarkReconcilePump.fingerprint(
                            folder: entry.folder,
                            index: entry.siblingIndex,
                            title: entry.title
                        )
                    }
                }
                bridge.knownLayout = layoutMap
                var folderLayout: [String: String] = [:]
                for folder in layout.folders {
                    folderLayout[folder.pathKey] = String(folder.siblingIndex)
                }
                bridge.knownFolderLayout = folderLayout
                // 树缺席 = 本端删夹意图已满足；勿在清空确认后对数百条历史墓碑重放 remove_folder。
                // 账本 folderTombstones 仍保留（跨端 LWW / 防复活）；此处只种确认集。
                let absentConfirmed = BookmarkReconcilePump.pathKeysSatisfiedByTreeAbsence(
                    tombstonePathKeys: service.folderTombstonesForBrowser().map(\.pathKey),
                    knownFolderLayout: folderLayout
                )
                bridge.confirmedFolderRemovals = absentConfirmed
                if !absentConfirmed.isEmpty {
                    service.activityLog.append(
                        "扩展树缺席确认删夹（\(key)）：\(absentConfirmed.count) 条墓碑无需下发"
                    )
                }
                bridge.failedFolderRemovals.removeAll()
                bridge.folderRemovalFailCounts.removeAll()
                bridge.folderRemovalPaused = false
                bridge.folderRemovalTimeouts = 0
                bridge.ensureTimeouts = 0
                bridge.poisonedURLs.removeAll()
                bridge.didPurgeEmptyTitleFolders = false
                bridge.purgeCredible = false
                bridge.purgeEmptyAttempts = 0
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
                // 越界：毒化 URL，禁止写入 known（假对齐）。
                if message.localizedCaseInsensitiveContains("Index out of bounds"),
                   let canonical = BookmarkURL.canonicalize(url) {
                    bridge.poisonedURLs.insert(canonical)
                    bridge.knownLayout.removeValue(forKey: canonical)
                }
                if op == "remove_folder" || op == "remove_folder_skipped",
                   let folderDict = object["folder"] as? [String: Any] {
                    let path = folder(from: folderDict)
                    bridge.pendingFolderRemovalKeys.remove(path.sortKey)
                    BookmarkReconcilePump.noteFolderRemovalFailure(
                        bridge: bridge,
                        pathKey: path.sortKey,
                        service: service,
                        reason: message
                    )
                }
                let folderHint: String
                if let folderDict = object["folder"] as? [String: Any] {
                    folderHint = " \(folder(from: folderDict).sortKey)"
                } else {
                    folderHint = ""
                }
                service.activityLog.append(
                    "扩展写回失败（\(bridge.browserKey ?? "?") \(op)）：\(url)\(folderHint) \(message)"
                )
            case "apply_result":
                let op = (object["op"] as? String) ?? "?"
                let url = (object["url"] as? String) ?? ""
                noteBatchAck(bridge: bridge, object: object)
                if op == "empty_folders_purged" {
                    // 仅可信 purge 回执才开门闩；失败/跳过不得宣称可对账。
                    bridge.didPurgeEmptyTitleFolders = true
                    bridge.purgeCredible = true
                    bridge.pendingPurgeBatch = false
                    // 空标题夹清掉后书签/账本夹下标需重排；不要清 confirmedFolderRemovals，
                    // 也不要依赖 known 才能继续下发墓碑删夹。
                    bridge.knownLayout.removeAll()
                    let tombstoneKeys = Set(service.folderTombstonesForBrowser().map(\.pathKey))
                    bridge.knownFolderLayout = bridge.knownFolderLayout.filter { key, _ in
                        tombstoneKeys.contains(key)
                    }
                } else if op == "folder_ensured",
                          let folderDict = object["folder"] as? [String: Any] {
                    let path = folder(from: folderDict)
                    let measuredIndex = object["index"] as? Int
                    let intentIndex = service.foldersForBrowser()
                        .first(where: { $0.pathKey == path.sortKey })?.siblingIndex
                    if let measuredIndex, let intentIndex, measuredIndex == intentIndex {
                        bridge.knownFolderLayout[path.sortKey] = String(measuredIndex)
                        bridge.confirmedFolderRemovals.remove(path.sortKey)
                    }
                    // 实测与意图不符：保持 divergent，下次再 ensure。
                } else if op == "folder_removed",
                          let folderDict = object["folder"] as? [String: Any] {
                    let path = folder(from: folderDict)
                    let removedCount = (object["removed"] as? Int) ?? 0
                    let missing = (object["missing"] as? Bool) ?? false
                    let evacuatedMoved = (object["evacuatedMoved"] as? Int) ?? 0
                    let evacuatedDeduped = (object["evacuatedDeduped"] as? Int) ?? 0
                    // 明确删掉或本就不存在才确认；避免无字段时误确认。
                    if removedCount > 0 || missing {
                        bridge.knownFolderLayout.removeValue(forKey: path.sortKey)
                        bridge.confirmedFolderRemovals.insert(path.sortKey)
                        bridge.pendingFolderRemovalKeys.remove(path.sortKey)
                        bridge.folderRemovalFailCounts.removeValue(forKey: path.sortKey)
                    } else {
                        BookmarkReconcilePump.noteFolderRemovalFailure(
                            bridge: bridge,
                            pathKey: path.sortKey,
                            service: service,
                            reason: "removed=0"
                        )
                    }
                    service.activityLog.append(
                        "扩展写回结果（\(bridge.browserKey ?? "?")）：folder_removed \(path.sortKey) removed=\(removedCount) missing=\(missing) moved=\(evacuatedMoved) deduped=\(evacuatedDeduped)"
                    )
                    break
                } else if let canonical = BookmarkURL.canonicalize(url),
                          op == "created" || op == "updated" || op == "exists",
                          let entry = service.entry(url: canonical),
                          !bridge.poisonedURLs.contains(canonical) {
                    let intent = BookmarkReconcilePump.fingerprint(
                        folder: entry.folder,
                        index: entry.siblingIndex,
                        title: entry.title
                    )
                    // 仅当扩展回传实测与账本意图一致时写入 known。
                    if let measuredFolderDict = object["folder"] as? [String: Any],
                       let measuredIndex = object["index"] as? Int {
                        let measuredTitle = (object["title"] as? String) ?? entry.title
                        let measured = BookmarkReconcilePump.fingerprint(
                            folder: folder(from: measuredFolderDict),
                            index: measuredIndex,
                            title: measuredTitle
                        )
                        if measured == intent {
                            bridge.knownLayout[canonical] = intent
                        }
                    }
                    // 无实测字段（旧扩展）：不 stamp，保持 divergent。
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
    private func finishTreeReady(bridge: BookmarkBridgeConnection, service: BookmarkSyncService) {
        // 其它连接靠各自串行对账对齐；不再广播 newlyJoined，避免对账风暴。
        bridge.pendingBeforeURLs = []
        requestReconcile(bridge: bridge, service: service)
    }

    /// 请求对账：已在跑则只标 dirty，由串行泵消化。
    @MainActor
    private func requestReconcile(bridge: BookmarkBridgeConnection, service: BookmarkSyncService) {
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
    private func runReconcilePump(bridge: BookmarkBridgeConnection, service: BookmarkSyncService, generation: UInt64) async {
        await BookmarkReconcilePump.run(
            bridge: bridge,
            service: service,
            generation: generation,
            send: { [weak self] object, target in
                self?.send(object, to: target)
            },
            requestAgain: { [weak self] in
                self?.requestReconcile(bridge: bridge, service: service)
            }
        )
    }

    @MainActor
    private func noteBatchAck(bridge: BookmarkBridgeConnection, object: [String: Any]) {
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
    private func broadcastUpsert(_ entry: BookmarkEntry, excluding excluded: BookmarkBridgeConnection? = nil) {
        guard let service else { return }
        lock.lock()
        let values = Array(connections.values)
        lock.unlock()
        let batch = UUID().uuidString
        let payload = BookmarkReconcilePump.entryPayload(entry)
        let fp = BookmarkReconcilePump.fingerprint(folder: entry.folder, index: entry.siblingIndex, title: entry.title)
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

    private func send(_ object: [String: Any], to bridge: BookmarkBridgeConnection) {
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
