import Foundation

/// 布局对账泵：按批纠偏夹与书签，等待扩展 ack。
enum BookmarkReconcilePump {
    @MainActor
    static func run(
        bridge: BookmarkBridgeConnection,
        service: BookmarkSyncService,
        generation: UInt64,
        send: ( [String: Any], BookmarkBridgeConnection ) -> Void,
        requestAgain: () -> Void
    ) async {
        defer {
            if bridge.reconcileGeneration == generation {
                bridge.isReconciling = false
                if bridge.needsReconcileAgain {
                    bridge.needsReconcileAgain = false
                    requestAgain()
                }
            }
        }
        while bridge.reconcileGeneration == generation {
            let done = await sendOneBatch(
                bridge: bridge,
                service: service,
                generation: generation,
                send: send
            )
            if done { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if bridge.reconcileGeneration != generation { break }
        }
    }

    /// 发一批并等待回执/超时。返回 true 表示已对齐、泵可结束。
    @MainActor
    static func sendOneBatch(
        bridge: BookmarkBridgeConnection,
        service: BookmarkSyncService,
        generation: UInt64,
        send: ( [String: Any], BookmarkBridgeConnection ) -> Void
    ) async -> Bool {
        let wanted = service.entriesForBrowser().sorted {
            if $0.folder.sortKey != $1.folder.sortKey {
                return $0.folder.sortKey < $1.folder.sortKey
            }
            return $0.siblingIndex < $1.siblingIndex
        }
        let divergent = wanted.filter { entry in
            let fp = fingerprint(folder: entry.folder, index: entry.siblingIndex, title: entry.title)
            return bridge.knownLayout[entry.url] != fp
        }
        let divergentFolders = service.foldersForBrowser()
            .filter { folder in
                bridge.knownFolderLayout[folder.pathKey] != String(folder.siblingIndex)
            }
            .sorted {
                if $0.path.segments.count != $1.path.segments.count {
                    return $0.path.segments.count < $1.path.segments.count
                }
                if $0.siblingIndex != $1.siblingIndex {
                    return $0.siblingIndex < $1.siblingIndex
                }
                return $0.pathKey < $1.pathKey
            }
        let target = bridge.browserKey ?? "未命名连接"
        if !bridge.didPurgeEmptyTitleFolders {
            let batch = UUID().uuidString
            bridge.pendingBatchID = batch
            bridge.pendingBatchRemaining = 1
            service.activityLog.append("布局对账 \(target)：清理空标题占位夹与分隔线。")
            send(["type": "purge_empty_folders", "batch": batch], bridge)
            let deadline = Date().addingTimeInterval(8)
            while bridge.pendingBatchRemaining > 0, Date() < deadline {
                if bridge.reconcileGeneration != generation { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let acked = bridge.pendingBatchRemaining == 0
            if bridge.pendingBatchID == batch {
                bridge.pendingBatchID = nil
                bridge.pendingBatchRemaining = 0
            }
            if acked {
                bridge.didPurgeEmptyTitleFolders = true
            } else {
                bridge.purgeEmptyAttempts += 1
                service.activityLog.append(
                    "布局对账 \(target)：清理占位未回执（\(bridge.purgeEmptyAttempts)/3），请重新加载扩展。"
                )
                if bridge.purgeEmptyAttempts >= 3 {
                    bridge.didPurgeEmptyTitleFolders = true
                }
            }
            return false
        }
        if divergent.isEmpty && divergentFolders.isEmpty {
            service.activityLog.append("布局对账 \(target)：已对齐。")
            return true
        }
        let folderBatch = Array(divergentFolders.prefix(10))
        let batchEntries = Array(divergent.prefix(30))
        let remain = (divergent.count - batchEntries.count) + (divergentFolders.count - folderBatch.count)
        service.activityLog.append(
            "布局对账 \(target)：纠偏 \(divergent.count) 条、夹 \(divergentFolders.count) 个，本批书签 \(batchEntries.count)、夹 \(folderBatch.count)\(remain > 0 ? "，剩余待下次" : "")。"
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
                bridge
            )
        }
        for entry in batchEntries {
            send(["type": "upsert", "batch": batch, "entry": entryPayload(entry)], bridge)
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

    static func fingerprint(folder: BookmarkFolderPath, index: Int, title: String) -> String {
        "\(folder.sortKey)|\(index)|\(title)"
    }

    static func entryPayload(_ entry: BookmarkEntry) -> [String: Any] {
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
}
