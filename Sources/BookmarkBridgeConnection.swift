import Foundation
import Network

/// 单路扩展连接上的对账状态（由 NativeBridge 持有）。
final class BookmarkBridgeConnection {
    let connection: NWConnection
    var buffer = Data()
    var browserKey: String?
    /// url → folder|index|title 指纹；仅在 apply_result 成功后更新。
    var knownLayout: [String: String] = [:]
    /// pathKey → siblingIndex 字符串；缺失或与账本不符则再 ensure_folder。
    var knownFolderLayout: [String: String] = [:]
    /// 已确认浏览器侧删除的夹 pathKey（含本来就不存在）。
    var confirmedFolderRemovals: Set<String> = []
    /// 每个 tree 周期在收到清理回执后才标完成。
    var didPurgeEmptyTitleFolders = false
    var purgeEmptyAttempts = 0
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
