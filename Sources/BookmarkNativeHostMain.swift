import Foundation

/// Native Messaging 主机：浏览器 stdio ↔ Tocode Unix 套接字。
/// 单独编译为 `tocode-bookmark-host`，不进入主应用 @main。
@main
enum BookmarkNativeHostMain {
    static func main() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let socketPath = base.appendingPathComponent("com.tocode.app/bookmark-sync.sock").path
        let client = UnixClient(path: socketPath)
        guard client.connect() else {
            exit(1)
        }

        let stdoutHandle = FileHandle.standardOutput
        let stdinHandle = FileHandle.standardInput

        // 必须两路并行：stdin 阻塞读若与 socket→stdout 共用串行队列，下行永远不会跑，
        // 表现为扩展只上报 tree、永远收不到 tree_ok/upsert（无 apply_result）。
        let inbound = DispatchQueue(label: "com.tocode.bookmark.host.inbound")
        let outbound = DispatchQueue(label: "com.tocode.bookmark.host.outbound")
        let group = DispatchGroup()

        group.enter()
        inbound.async {
            while true {
                guard let message = readNativeMessage(from: stdinHandle) else { break }
                guard client.sendFramed(message) else { break }
            }
            group.leave()
        }

        group.enter()
        outbound.async {
            while true {
                guard let message = client.receiveFramed() else { break }
                guard writeNativeMessage(message, to: stdoutHandle) else { break }
            }
            group.leave()
        }

        group.wait()
        client.close()
    }
}

private func readNativeMessage(from handle: FileHandle) -> Data? {
    let lengthData = handle.readData(ofLength: 4)
    guard lengthData.count == 4 else { return nil }
    let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length > 0, length < 1_000_000 else { return nil }
    let payload = handle.readData(ofLength: Int(length))
    guard payload.count == Int(length) else { return nil }
    return payload
}

private func writeNativeMessage(_ payload: Data, to handle: FileHandle) -> Bool {
    var length = UInt32(payload.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    do {
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
        return true
    } catch {
        return false
    }
}

private final class UnixClient {
    private var fd: Int32 = -1
    private var buffer = Data()
    private let path: String

    init(path: String) {
        self.path = path
    }

    func connect() -> Bool {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close()
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = byte
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        if result != 0 {
            close()
            return false
        }
        return true
    }

    func sendFramed(_ payload: Data) -> Bool {
        var length = UInt32(payload.count).littleEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(payload)
        return packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < packet.count {
                let n = Darwin.send(fd, base.advanced(by: sent), packet.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func receiveFramed() -> Data? {
        while buffer.count < 4 {
            guard readMore() else { return nil }
        }
        let length = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let total = 4 + Int(length)
        while buffer.count < total {
            guard readMore() else { return nil }
        }
        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return payload
    }

    private func readMore() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { return false }
        buffer.append(contentsOf: chunk.prefix(n))
        return true
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
