import Foundation
import Network

/// 客户端：连接常驻进程的 Unix domain socket，发送单行 JSON，同步等待响应。
final class TocodeSocketTransport: TocodeIPCTransport {
    private let path: String
    private let timeout: TimeInterval

    init(path: String = TocodeIPCSocket.path(), timeout: TimeInterval = 10) {
        self.path = path
        self.timeout = timeout
    }

    func send(_ request: TocodeIPCRequest) -> Result<TocodeIPCResponse, TocodeIPCError> {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.notRunning)
        }

        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return .failure(.transport("无法创建 socket"))
        }
        defer { close(socket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() where index < buffer.count {
                buffer[index] = byte
            }
        }
        let addrLength = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        addr.sun_len = addrLength

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socket, sockaddrPointer, socklen_t(addrLength))
            }
        }
        guard connectResult == 0 else {
            return .failure(.notRunning)
        }

        guard let payload = try? TocodeIPCFraming.encodeRequest(request) else {
            return .failure(.transport("无法编码请求"))
        }

        var sent = 0
        while sent < payload.count {
            let count = payload.withUnsafeBytes { buffer in
                write(socket, buffer.baseAddress!.advanced(by: sent), payload.count - sent)
            }
            guard count > 0 else {
                return .failure(.transport("发送请求失败"))
            }
            sent += count
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()
        while accumulated.count < 65536 {
            let count = read(socket, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            accumulated.append(contentsOf: buffer.prefix(count))
            if accumulated.last == 0x0A {
                break
            }
        }
        guard let response = TocodeIPCFraming.decodeResponse(accumulated) else {
            return .failure(.invalidResponse)
        }
        return .success(response)
    }
}

private func receiveResponse(
    _ connection: NWConnection,
    finish: @escaping (Result<TocodeIPCResponse, TocodeIPCError>) -> Void
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, receiveError in
        if let receiveError {
            finish(.failure(.transport(receiveError.localizedDescription)))
            return
        }
        guard let data, let response = TocodeIPCFraming.decodeResponse(data) else {
            finish(.failure(.invalidResponse))
            return
        }
        finish(.success(response))
    }
}
