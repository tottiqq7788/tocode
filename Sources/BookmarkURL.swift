import Foundation

enum BookmarkURL {
    /// 规范化书签网址：协议与主机小写，去掉默认端口与路径末尾斜杠。
    /// 查询与片段按 URLComponents 解码形态参与身份（`%2F` 与 `/` 同一条），与扩展 canonicalize 对齐。
    static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        if let user = components.user { normalized.user = user }
        if let password = components.password { normalized.password = password }

        if let port = components.port {
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            if !isDefault {
                normalized.port = port
            }
        }

        var path = components.path
        if path.hasSuffix("/") {
            if path.count > 1 {
                path.removeLast()
            } else {
                path = ""
            }
        }
        normalized.path = path
        normalized.query = components.query
        normalized.fragment = components.fragment
        return normalized.string
    }
}
