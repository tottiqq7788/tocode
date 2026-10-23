import Foundation

/// 扩展在线判定：以 Native 活连接为准，同 key 多连接断开不误伤。
enum BookmarkOnlinePresence {
    /// 去掉 nil 后去重排序。
    static func uniqueSortedKeys(from keys: [String?]) -> [String] {
        Array(Set(keys.compactMap { $0 })).sorted()
    }

    /// 移除持有 `removedKey` 的一条连接后，是否应标该 key 离线。
    static func shouldMarkOffline(removedKey: String?, remainingKeys: [String]) -> Bool {
        guard let removedKey else { return false }
        return !remainingKeys.contains(removedKey)
    }

    /// 拓展安装菜单：该浏览器是否有任一 profile 在线。
    static func isBrowserConnected(browserRaw: String, onlineKeys: [String]) -> Bool {
        let prefix = "\(browserRaw):"
        return onlineKeys.contains { $0.hasPrefix(prefix) }
    }
}
