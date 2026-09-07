import Foundation

enum TocodeToggle: String, Equatable {
    case on
    case off
    case toggle
}

enum TocodeWheelAxis: String, Equatable {
    case vertical
    case horizontal
}

enum TocodeShortcutKind: String, Equatable {
    case finderMove = "finder-move"
    case doubleCmdQ = "double-cmdq"
    case finderCmdQ = "finder-cmdq"
}

enum TocodeRootCommand: Equatable {
    case get
    case set(String)
    case choose
    case reset
    case initFromFinder
}

enum TocodeCodexCommand: Equatable {
    case status
    case sync(TocodeToggle)
    case model
    case modelList
    case modelSet(String)
}

enum TocodeWechatCommand: Equatable {
    case status
    case bind
    case location
}

enum TocodeCommand: Equatable {
    case help
    case status
    case root(TocodeRootCommand)
    case codex(TocodeCodexCommand)
    case wechat(TocodeWechatCommand)
    case blackout
    case login(TocodeToggle)
    case wheel(TocodeWheelAxis, TocodeToggle)
    case hidden(TocodeToggle)
    case shortcut(TocodeShortcutKind, TocodeToggle)
    case quit
}

struct TocodeCommandOutput: Equatable, Codable {
    let lines: [String]

    init(_ text: String) {
        lines = [text]
    }

    init(lines: [String]) {
        self.lines = lines
    }

    var text: String { lines.joined(separator: "\n") }
}

enum TocodeCommandError: Error, Equatable, LocalizedError {
    case emptyCommand
    case unknownCommand(String)
    case invalidArguments(String)
    case invalidToggle(String)
    case invalidAxis(String)
    case invalidShortcut(String)
    case missingValue(String)
    case rootNotFound(String)
    case rootSelectionCancelled
    case finderSelectionFailed(String)
    case codexUnavailable(String)
    case codexModelSwitchFailed(String)
    case operationFailed(String)

    var message: String {
        switch self {
        case .emptyCommand:
            return "命令为空"
        case .unknownCommand(let command):
            return "未知命令：\(command)"
        case .invalidArguments(let command):
            return "参数错误：\(command)"
        case .invalidToggle(let value):
            return "无效开关值：\(value)（可用 on / off / toggle）"
        case .invalidAxis(let value):
            return "无效滚轮方向：\(value)（可用 vertical / horizontal）"
        case .invalidShortcut(let value):
            return "无效快捷键：\(value)"
        case .missingValue(let command):
            return "缺少参数：\(command)"
        case .rootNotFound(let path):
            return "不是有效目录：\(path)"
        case .rootSelectionCancelled:
            return "已取消选择目录"
        case .finderSelectionFailed(let message):
            return "访达初始化失败：\(message)"
        case .codexUnavailable(let message):
            return "Codex 不可用：\(message)"
        case .codexModelSwitchFailed(let message):
            return "Codex 模型切换失败：\(message)"
        case .operationFailed(let message):
            return message
        }
    }

    var errorDescription: String? { message }
}

typealias TocodeCommandResult = Result<TocodeCommandOutput, TocodeCommandError>

enum TocodeCommandParser {
    static let aliases: [String: String] = [
        "lshp": "blackout"
    ]

    static let helpText = """
    tocode 命令：

      帮助 / 状态
        help                                打印命令表
        status                              根目录、各开关、微信与 Codex 状态汇总

      根目录
        root get                            返回当前根目录
        root set <path>                     校验后设置根目录
        root choose                         弹出系统目录选择器
        root reset                          重置为默认目录
        root init-from-finder               以访达当前单选项初始化

      Codex
        codex status                        当前项目名 + 根目录
        codex sync on|off|toggle            同步项目夹开关
        codex model                         当前模型与一致性
        codex model list                    实时拉取 Anker 模型列表
        codex model set <id>                切换模型并强制重启 Codex

      微信
        wechat status                       是否已绑定
        wechat bind                         触发扫码绑定
        wechat location                     创建并在访达打开归档目录

      其他
        blackout（别名 .lshp）                mac → 临时黑屏
        login on|off|toggle                 开机自启
        wheel vertical on|off|toggle        对调垂直滚轮
        wheel horizontal on|off|toggle      对调横向滚轮
        hidden on|off|toggle                显示/隐藏隐藏文件
        shortcut finder-move on|off|toggle  x/v 移动文件
        shortcut double-cmdq on|off|toggle  双击 ⌘Q
        shortcut finder-cmdq on|off|toggle  ⌘Q 强关访达
        quit                                退出 Tocode
    """

    static func parse(_ input: String) -> Result<TocodeCommand, TocodeCommandError> {
        let tokens = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return parse(tokens)
    }

    static func parse(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        let normalized = tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstRaw = normalized.first else {
            return .failure(.emptyCommand)
        }
        var verb = firstRaw.lowercased()
        if verb.hasPrefix(".") {
            verb = String(verb.dropFirst())
        }
        verb = aliases[verb] ?? verb
        let rest = Array(normalized.dropFirst())

        switch verb {
        case "help":
            guard rest.isEmpty else { return .failure(.invalidArguments(firstRaw)) }
            return .success(.help)
        case "status":
            guard rest.isEmpty else { return .failure(.invalidArguments(firstRaw)) }
            return .success(.status)
        case "root":
            return parseRoot(rest)
        case "codex":
            return parseCodex(rest)
        case "wechat":
            return parseWechat(rest)
        case "blackout":
            guard rest.isEmpty else { return .failure(.invalidArguments(firstRaw)) }
            return .success(.blackout)
        case "login":
            guard let toggle = parseToggle(rest, verb: firstRaw) else {
                return .failure(.invalidToggle(rest.first ?? ""))
            }
            return .success(.login(toggle))
        case "wheel":
            return parseWheel(rest, verb: firstRaw)
        case "hidden":
            guard let toggle = parseToggle(rest, verb: firstRaw) else {
                return .failure(.invalidToggle(rest.first ?? ""))
            }
            return .success(.hidden(toggle))
        case "shortcut":
            return parseShortcut(rest, verb: firstRaw)
        case "quit":
            guard rest.isEmpty else { return .failure(.invalidArguments(firstRaw)) }
            return .success(.quit)
        default:
            return .failure(.unknownCommand(firstRaw))
        }
    }

    private static func parseRoot(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .success(.root(.get))
        }
        switch sub {
        case "get":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root \(tokens.joined(separator: " "))")) }
            return .success(.root(.get))
        case "set":
            guard tokens.count >= 2 else { return .failure(.missingValue("root set <path>")) }
            let path = tokens.dropFirst().joined(separator: " ")
            return .success(.root(.set(path)))
        case "choose":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root choose")) }
            return .success(.root(.choose))
        case "reset":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root reset")) }
            return .success(.root(.reset))
        case "init-from-finder":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root init-from-finder")) }
            return .success(.root(.initFromFinder))
        default:
            return .failure(.unknownCommand("root \(sub)"))
        }
    }

    private static func parseCodex(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .success(.codex(.status))
        }
        switch sub {
        case "status":
            guard tokens.count == 1 else { return .failure(.invalidArguments("codex status")) }
            return .success(.codex(.status))
        case "sync":
            guard let toggle = parseToggle(Array(tokens.dropFirst()), verb: "codex sync") else {
                return .failure(.invalidToggle(tokens.count > 1 ? tokens[1] : ""))
            }
            return .success(.codex(.sync(toggle)))
        case "model":
            return parseCodexModel(Array(tokens.dropFirst()))
        default:
            return .failure(.unknownCommand("codex \(sub)"))
        }
    }

    private static func parseCodexModel(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .success(.codex(.model))
        }
        switch sub {
        case "list":
            guard tokens.count == 1 else { return .failure(.invalidArguments("codex model list")) }
            return .success(.codex(.modelList))
        case "set":
            guard tokens.count == 2 else { return .failure(.missingValue("codex model set <id>")) }
            return .success(.codex(.modelSet(tokens[1])))
        default:
            return .failure(.unknownCommand("codex model \(sub)"))
        }
    }

    private static func parseWechat(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .success(.wechat(.status))
        }
        switch sub {
        case "status":
            guard tokens.count == 1 else { return .failure(.invalidArguments("wechat status")) }
            return .success(.wechat(.status))
        case "bind":
            guard tokens.count == 1 else { return .failure(.invalidArguments("wechat bind")) }
            return .success(.wechat(.bind))
        case "location":
            guard tokens.count == 1 else { return .failure(.invalidArguments("wechat location")) }
            return .success(.wechat(.location))
        default:
            return .failure(.unknownCommand("wechat \(sub)"))
        }
    }

    private static func parseWheel(_ tokens: [String], verb: String) -> Result<TocodeCommand, TocodeCommandError> {
        guard let axisRaw = tokens.first?.lowercased() else {
            return .failure(.missingValue("wheel vertical|horizontal on|off|toggle"))
        }
        guard let axis = TocodeWheelAxis(rawValue: axisRaw) else {
            return .failure(.invalidAxis(axisRaw))
        }
        guard let toggle = parseToggle(Array(tokens.dropFirst()), verb: verb) else {
            return .failure(.invalidToggle(tokens.count > 1 ? tokens[1] : ""))
        }
        return .success(.wheel(axis, toggle))
    }

    private static func parseShortcut(_ tokens: [String], verb: String) -> Result<TocodeCommand, TocodeCommandError> {
        guard let kindRaw = tokens.first?.lowercased() else {
            return .failure(.missingValue("shortcut finder-move|double-cmdq|finder-cmdq on|off|toggle"))
        }
        guard let kind = TocodeShortcutKind(rawValue: kindRaw) else {
            return .failure(.invalidShortcut(kindRaw))
        }
        guard let toggle = parseToggle(Array(tokens.dropFirst()), verb: verb) else {
            return .failure(.invalidToggle(tokens.count > 1 ? tokens[1] : ""))
        }
        return .success(.shortcut(kind, toggle))
    }

    private static func parseToggle(_ tokens: [String], verb: String) -> TocodeToggle? {
        guard tokens.count == 1 else { return nil }
        return TocodeToggle(rawValue: tokens[0].lowercased())
    }
}

/// 微信 `.` 前缀命令判定：首项为文本且 trim 后以 `.` 开头即视为命令。
enum TocodeWeChatCommandGate {
    static func commandBody(from message: WeChatMessage) -> String? {
        guard let first = message.items.first, first.type == 1,
              let raw = first.textItem?.text else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(".") else { return nil }
        return String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
