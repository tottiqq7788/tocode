import Foundation

/// 布局对账泵：按批纠偏夹与书签，等待扩展 ack。
enum BookmarkReconcilePump {
    static let folderRemovalFailLimit = 5
    static let folderRemovalTimeoutPause = 8
    static let ensureTimeoutLimit = 12

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

    /// 发一批并等待回执/超时。返回 true 表示可结束泵。
    @MainActor
    static func sendOneBatch(
        bridge: BookmarkBridgeConnection,
        service: BookmarkSyncService,
        generation: UInt64,
        send: ( [String: Any], BookmarkBridgeConnection ) -> Void
    ) async -> Bool {
        if bridge.awaitingTreeReady {
            return false
        }
        let wanted = service.entriesForBrowser().sorted {
            if $0.folder.sortKey != $1.folder.sortKey {
                return $0.folder.sortKey < $1.folder.sortKey
            }
            return $0.siblingIndex < $1.siblingIndex
        }
        let divergent = wanted.filter { entry in
            if bridge.poisonedURLs.contains(entry.url) { return false }
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
        let removalCandidates = service.folderTombstonesForBrowser()
            .filter { stone in
                !bridge.confirmedFolderRemovals.contains(stone.pathKey)
                    && !bridge.failedFolderRemovals.contains(stone.pathKey)
                    && !bridge.folderRemovalPaused
            }
            .sorted { $0.path.segments.count > $1.path.segments.count }
        let target = bridge.browserKey ?? "未命名连接"

        if !bridge.didPurgeEmptyTitleFolders {
            let batch = UUID().uuidString
            bridge.pendingBatchID = batch
            bridge.pendingBatchRemaining = 1
            bridge.pendingPurgeBatch = true
            service.activityLog.append("布局对账 \(target)：清理空标题占位夹与分隔线。")
            send(["type": "purge_empty_folders", "batch": batch], bridge)
            let deadline = Date().addingTimeInterval(8)
            while bridge.pendingBatchRemaining > 0, Date() < deadline {
                if bridge.reconcileGeneration != generation { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let timedOut = bridge.pendingBatchRemaining > 0
            if bridge.pendingBatchID == batch {
                bridge.pendingBatchID = nil
                bridge.pendingBatchRemaining = 0
            }
            bridge.pendingPurgeBatch = false
            if bridge.didPurgeEmptyTitleFolders {
                return false
            }
            bridge.purgeEmptyAttempts += 1
            if timedOut {
                service.activityLog.append(
                    "布局对账 \(target)：清理占位未回执（\(bridge.purgeEmptyAttempts)/3）。"
                )
            }
            if bridge.purgeEmptyAttempts >= 3 {
                bridge.didPurgeEmptyTitleFolders = true
                bridge.purgeCredible = false
                service.activityLog.append(
                    "布局对账 \(target)：跳过占位清理（对齐不可信），请重新加载扩展。"
                )
            }
            return false
        }

        let poisonedCount = bridge.poisonedURLs.count
        if divergent.isEmpty && divergentFolders.isEmpty && removalCandidates.isEmpty {
            if !bridge.purgeCredible || poisonedCount > 0 || !bridge.failedFolderRemovals.isEmpty {
                service.activityLog.append(
                    "布局对账 \(target)：降级对齐（purge可信=\(bridge.purgeCredible) 毒化\(poisonedCount) 删夹失败\(bridge.failedFolderRemovals.count)）。"
                )
            } else {
                service.activityLog.append("布局对账 \(target)：已对齐。")
            }
            return true
        }

        if !removalCandidates.isEmpty {
            let removalBatch = Array(removalCandidates.prefix(10))
            let remainRemovals = removalCandidates.count - removalBatch.count
            service.activityLog.append(
                "布局对账 \(target)：删夹 \(removalCandidates.count)，本批删 \(removalBatch.count)\(remainRemovals > 0 ? "，剩余待下次" : "")。"
            )
            let batch = UUID().uuidString
            bridge.pendingBatchID = batch
            bridge.pendingBatchRemaining = removalBatch.count
            bridge.pendingFolderRemovalKeys = Set(removalBatch.map(\.pathKey))
            for stone in removalBatch {
                send(
                    [
                        "type": "remove_folder",
                        "batch": batch,
                        "folder": [
                            "kind": stone.path.kind.rawValue,
                            "segments": stone.path.segments
                        ],
                        "recursive": true
                    ],
                    bridge
                )
            }
            let deadline = Date().addingTimeInterval(12)
            while bridge.pendingBatchRemaining > 0, Date() < deadline {
                if bridge.reconcileGeneration != generation { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let timedOut = bridge.pendingBatchRemaining > 0
            let pendingKeys = bridge.pendingFolderRemovalKeys
            if bridge.pendingBatchID == batch {
                bridge.pendingBatchID = nil
                bridge.pendingBatchRemaining = 0
            }
            bridge.pendingFolderRemovalKeys.removeAll()
            if timedOut {
                bridge.folderRemovalTimeouts += 1
                for key in pendingKeys {
                    noteFolderRemovalFailure(bridge: bridge, pathKey: key, service: service, reason: "超时")
                }
                service.activityLog.append(
                    "布局对账 \(target)：删夹未回执 \(pendingKeys.count) 个（累计超时 \(bridge.folderRemovalTimeouts)），请确认扩展已重载且含 remove_folder。"
                )
                // 达阈值即暂停；勿要求 confirmed 为空（树缺席播种后 confirmed 常非空，否则永不熔断）。
                if bridge.folderRemovalTimeouts >= folderRemovalTimeoutPause {
                    bridge.folderRemovalPaused = true
                    service.activityLog.append(
                        "布局对账 \(target)：删夹已暂停（扩展可能未重载），待 tree 后恢复。"
                    )
                }
            }
            return false
        }

        if bridge.ensureTimeouts >= ensureTimeoutLimit {
            service.activityLog.append(
                "布局对账 \(target)：ensure/upsert 超时过多，降级结束（剩余书签 \(divergent.count)、夹 \(divergentFolders.count)）。"
            )
            return true
        }

        let folderBatch = Array(divergentFolders.prefix(10))
        let batchEntries = Array(divergent.prefix(30))
        let remain = (divergent.count - batchEntries.count)
            + (divergentFolders.count - folderBatch.count)
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
        if bridge.pendingBatchRemaining > 0 {
            bridge.ensureTimeouts += 1
            service.activityLog.append(
                "布局对账 \(target)：ensure/upsert 批超时（\(bridge.ensureTimeouts)/\(ensureTimeoutLimit)）。"
            )
        }
        if bridge.pendingBatchID == batch {
            bridge.pendingBatchID = nil
            bridge.pendingBatchRemaining = 0
        }
        return false
    }

    @MainActor
    static func noteFolderRemovalFailure(
        bridge: BookmarkBridgeConnection,
        pathKey: String,
        service: BookmarkSyncService,
        reason: String
    ) {
        let next = (bridge.folderRemovalFailCounts[pathKey] ?? 0) + 1
        bridge.folderRemovalFailCounts[pathKey] = next
        if next >= folderRemovalFailLimit {
            bridge.failedFolderRemovals.insert(pathKey)
            service.activityLog.append(
                "布局对账 \(bridge.browserKey ?? "?")：夹 \(pathKey) 删失败 \(next) 次（\(reason)），停止重试。"
            )
        }
    }

    static func fingerprint(folder: BookmarkFolderPath, index: Int, title: String) -> String {
        "\(folder.sortKey)|\(index)|\(title)"
    }

    /// 浏览器树里不存在的夹墓碑 pathKey：本端删除已满足，不必再发 remove_folder。
    /// 仍在 knownFolderLayout 中的路径不纳入（需继续下发删除）。
    static func pathKeysSatisfiedByTreeAbsence(
        tombstonePathKeys: [String],
        knownFolderLayout: [String: String]
    ) -> Set<String> {
        Set(tombstonePathKeys.filter { knownFolderLayout[$0] == nil })
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
