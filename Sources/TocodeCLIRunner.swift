import Foundation

/// CLI 可注入逻辑：测试用内存 transport，真实 main 用 socket transport。
struct TocodeCLIRunner {
    typealias Output = (exitCode: Int32, stdout: String, stderr: String)

    static func run(
        arguments: [String],
        transport: TocodeIPCTransport,
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        let arguments = TocodeCLIArgumentPrep.prepared(arguments)
        guard let first = arguments.first else {
            stdout(TocodeCommandParser.helpText)
            return 2
        }

        // help/commands 属于命令表查询，本地即可返回，不依赖常驻进程。
        if first.lowercased() == "help" || first.lowercased() == "commands" {
            stdout(TocodeCommandParser.helpText)
            return 0
        }

        let request = TocodeIPCRequest(
            id: UUID().uuidString,
            command: first,
            args: Array(arguments.dropFirst())
        )

        switch transport.send(request) {
        case .success(let response):
            if response.ok {
                if let data = response.data, !data.isEmpty {
                    stdout(data)
                }
                return 0
            } else {
                stderr(response.error ?? "命令执行失败")
                return 1
            }
        case .failure(let error):
            stderr(error.localizedDescription)
            return 1
        }
    }
}

enum TocodeCLIArgumentPrep {
    static let sendTimeout: TimeInterval = 60
    static let defaultTimeout: TimeInterval = 10

    static func prepared(_ arguments: [String]) -> [String] {
        guard arguments.first?.lowercased() == "wechat",
              arguments.dropFirst().first?.lowercased() == "send" else {
            return arguments
        }
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--to" || token == "--text" {
                result.append(token)
                if index + 1 < arguments.count {
                    result.append(arguments[index + 1])
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if index >= 2 && !token.hasPrefix("--") {
                result.append(absolutize(token))
            } else {
                result.append(token)
            }
            index += 1
        }
        return result
    }

    static func timeout(for arguments: [String]) -> TimeInterval {
        if arguments.first?.lowercased() == "wechat",
           arguments.dropFirst().first?.lowercased() == "send" {
            return sendTimeout
        }
        return defaultTimeout
    }

    private static func absolutize(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
