import Foundation

struct TocodeIPCRequest: Codable, Equatable {
    let id: String
    let command: String
    let args: [String]
}

struct TocodeIPCResponse: Codable, Equatable {
    let id: String
    let ok: Bool
    let data: String?
    let error: String?
}

enum TocodeIPCError: Error, Equatable, LocalizedError {
    case notRunning
    case invalidResponse
    case timedOut
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Tocode 未运行或无法连接（请先启动 Tocode）"
        case .invalidResponse:
            return "Tocode 返回了无法识别的响应"
        case .timedOut:
            return "等待 Tocode 响应超时"
        case .transport(let message):
            return message
        }
    }
}

enum TocodeIPCFraming {
    static let newline = Data([0x0A])

    static func encodeRequest(_ request: TocodeIPCRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(newline)
        return data
    }

    static func decodeResponse(_ data: Data) -> TocodeIPCResponse? {
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(TocodeIPCResponse.self, from: Data(trimmed.utf8))
    }
}

/// IPC 传输边界：真实实现用本机 Unix domain socket，测试用内存 transport。
protocol TocodeIPCTransport {
    /// 同步发送单行 JSON 请求并返回单行 JSON 响应。
    func send(_ request: TocodeIPCRequest) -> Result<TocodeIPCResponse, TocodeIPCError>
}

enum TocodeIPCSocket {
    static func path(fileManager: FileManager = .default) -> String {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("com.tocode.app", isDirectory: true)
            .appendingPathComponent("tocode.sock", isDirectory: false)
            .path
    }
}
