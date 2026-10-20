import Foundation
import Security

/// 只补 ~/.hermes/.env 里缺失的 API Server 配置。已有非空值保持原样。
enum HermesGatewayEnv {
    static let enabledName = "API_SERVER_ENABLED"
    static let keyName = "API_SERVER_KEY"

    static func completed(envText: String, newKey: String) -> (text: String, changed: Bool) {
        var rows = rows(of: envText)
        var changed = false
        changed = fill(&rows, name: enabledName, value: "true") || changed
        changed = fill(&rows, name: keyName, value: newKey) || changed
        let text = rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
        return (text, changed)
    }

    static func ensure(
        at url: URL,
        fileManager: FileManager = .default,
        makeKey: () -> String = randomKey
    ) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let result = completed(envText: existing, newKey: makeKey())
        guard result.changed else { return }
        try write(result.text, to: url, fileManager: fileManager)
    }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func rows(of envText: String) -> [String] {
        guard !envText.isEmpty else { return [] }
        var rows = envText.components(separatedBy: "\n")
        if envText.hasSuffix("\n") { rows.removeLast() }
        return rows
    }

    private static func fill(_ rows: inout [String], name: String, value: String) -> Bool {
        if let index = rows.firstIndex(where: { isAssignment($0, name: name) }) {
            guard PhoneHermesEnvironment.value(named: name, in: rows[index]).isEmpty else { return false }
            rows[index] = "\(name)=\(value)"
            return true
        }
        rows.append("\(name)=\(value)")
        return true
    }

    private static func isAssignment(_ line: String, name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("#") && trimmed.hasPrefix(name + "=")
    }

    private static func write(_ text: String, to url: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tocode-\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum HermesGatewayBinary {
    static func resolve(home: String, exists: (String) -> Bool) -> String? {
        let candidates = [
            (home as NSString).appendingPathComponent(".local/bin/hermes"),
            (home as NSString).appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes"),
        ]
        return candidates.first(where: exists)
    }
}

enum HermesGatewayMenu {
    static let title = "网关链接"

    static func symbolName(phase: HermesGatewayPhase) -> String {
        switch phase {
        case .running: return "checkmark.circle.fill"
        case .starting: return "arrow.clockwise.circle"
        case .failed: return "exclamationmark.circle"
        case .off: return "circle"
        }
    }

    static func toolTip(phase: HermesGatewayPhase, installed: Bool) -> String {
        guard installed else { return "这台电脑没有 Hermes" }
        switch phase {
        case .running: return "网关已连接，退出 Tocode 时会关闭"
        case .starting: return "正在启动 Hermes 网关"
        case .failed: return "网关没能保持运行，再点一次可关闭"
        case .off: return "打开后随 Tocode 启动 Hermes 网关"
        }
    }
}
