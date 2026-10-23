import Foundation
import Network

/// 单路扩展连接上的对账状态（由 NativeBridge 持有）。
final class BookmarkBridgeConnection {
    let connection: NWConnection
    var buffer = Data()
    var browserKey: String?
    /// url → folder|index|title 指纹；仅在实测与账本意图一致时更新。
    var knownLayout: [String: String] = [:]
    /// pathKey → siblingIndex 字符串；缺失或与账本不符则再 ensure_folder。
    var knownFolderLayout: [String: String] = [:]
    /// 已确认浏览器侧删除的夹 pathKey（含本来就不存在）。
    var confirmedFolderRemovals: Set<String> = []
    /// 连续删夹失败达上限后不再重试的 pathKey。
    var failedFolderRemovals: Set<String> = []
    /// pathKey → 连续失败次数。
    var folderRemovalFailCounts: [String: Int] = [:]
    /// 本批已发出、等待 folder_removed 的 pathKey。
    var pendingFolderRemovalKeys: Set<String> = []
    /// 删夹批超时次数（可观测；不因此把墓碑当已删）。
    var folderRemovalTimeouts = 0
    /// 删夹超时达阈值后暂停删夹队列（待下次 tree 恢复）。
    var folderRemovalPaused = false
    /// ensure/upsert 批超时次数。
    var ensureTimeouts = 0
    /// Index out of bounds 等不可恢复 URL；不写入 known，避免假对齐。
    var poisonedURLs: Set<String> = []
    /// 每个 tree 周期在收到清理回执后才标完成。
    var didPurgeEmptyTitleFolders = false
    /// purge 是否可信（仅 empty_folders_purged）；跳过/失败则为 false。
    var purgeCredible = false
    var purgeEmptyAttempts = 0
    var awaitingTreeReady = false
    var pendingBeforeURLs: Set<String> = []
    var isReconciling = false
    var needsReconcileAgain = false
    var reconcileGeneration: UInt64 = 0
    var pendingBatchID: String?
    var pendingBatchRemaining = 0
    /// 当前批是否为 purge（失败回执不得当成 purge 成功）。
    var pendingPurgeBatch = false

    init(connection: NWConnection) {
        self.connection = connection
    }
}
