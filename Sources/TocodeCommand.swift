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
    case finderFollow(TocodeToggle)
    case clipboard
    case open
}

enum TocodeFinderCommand: Equatable {
    case copy
}

enum TocodeCodexCommand: Equatable {
    case status
    case sync(TocodeToggle)
    case model
    case modelList
    case modelSet(String)
}

struct TocodeWechatSendPayload: Equatable {
    var toUserID: String?
    var text: String?
    var files: [String]

    static let maximumFileBytes = 20 * 1024 * 1024
}

enum TocodeWechatCommand: Equatable {
    case status
    case bind
    case send(TocodeWechatSendPayload)
}

struct TocodeTogentRoleOptions: Equatable {
    var name: String?
    var workspacePath: String?
    var publishedModelID: String?
    var isActive: Bool?
    var prompt: String?
}

enum TocodeTogentCommand: Equatable {
    case list
    case show(String)
    case models
    case create(TocodeTogentRoleOptions)
    case copy(sourceName: String, options: TocodeTogentRoleOptions)
    case update(name: String, options: TocodeTogentRoleOptions)
    case open(String)
}

enum TocodeModelCommand: Equatable {
    case status
    case portGet
    case portSet(Int)
    case models
    case log
}

enum TocodeCommand: Equatable {
    case help
    case status
    case root(TocodeRootCommand)
    case finder(TocodeFinderCommand)
    case codex(TocodeCodexCommand)
    case wechat(TocodeWechatCommand)
    case togent(TocodeTogentCommand)
    case model(TocodeModelCommand)
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
        "lshp": "blackout",
        "commands": "help"
    ]

    static let helpText = """
    tocode 命令：

      帮助 / 状态
        help                                打印命令表
        status                              根目录、各开关、微信、Togent、模型中转与 Codex 状态汇总

      根目录
        root get                            返回当前根目录
        root set <path>                     校验后设置根目录
        root choose                         弹出系统目录选择器
        root reset                          重置为默认目录
        root finder-follow on|off|toggle    访达跟随开关
        root clipboard                      剪贴板为现有目录时设为根
        root open                           在访达打开固定根目录

      访达
        finder copy                         复制访达选中项绝对路径

      Codex
        codex status                        当前项目名 + 根目录
        codex sync on|off|toggle            codex跟随开关
        codex model                         当前模型与一致性
        codex model list                    实时拉取 Anker 模型列表
        codex model set <id>                切换模型并强制重启 Codex

      微信
        wechat status                       是否已绑定
        wechat bind                         触发扫码绑定
        wechat send [--to <id>] [--text <文字>] [文件...]
                                            向最近会话发送文字、图片或附件

      Togent（只配置角色，不能提交 Agent 任务）
        togent list                         列出角色
        togent show <name>                  回显角色详情与提示词
        togent models                       列出当前健康中转模型
        togent create --name <英文名> [--path <路径>] [--model <id>]
                      [--active on|off] [--prompt <文本> | --prompt-file <文件>]
        togent copy <源名称> [...]          复制提示词与模型，生成独立新角色
        togent update <名称> [...]          只改给出的字段
        togent open <名称>                  打开已保存角色工作区

      模型中转（不含密钥）
        model status                        Base URL、端口、运行状态与调用摘要
        model port                          读取当前端口
        model port <1024...65535>           设置固定 loopback 端口
        model models                        列出当前健康 published 模型
        model log                           用系统应用打开今日调用日志

      其他
        blackout（别名 .lshp）                工具 → 临时黑屏
        login on|off|toggle                 开机自启
        wheel vertical on|off|toggle        对调垂直滚轮
        wheel horizontal on|off|toggle      对调横向滚轮
        hidden on|off|toggle                显示/隐藏隐藏文件
        shortcut finder-move on|off|toggle  x/v 移动文件
        shortcut double-cmdq on|off|toggle  双击 ⌘Q
        shortcut finder-cmdq on|off|toggle  ⌘Q 强关访达
        quit                                退出 Tocode
    """

    /// 微信 .help 使用的命令表：每条命令以 . 开头、单独用代码框包裹，便于逐条复制。
    static let weChatHelpCommands: [(command: String, description: String)] = [
        ("help", "打印命令表"),
        ("status", "根目录、各开关、微信、Togent、模型中转与 Codex 状态汇总"),
        ("root get", "返回当前根目录"),
        ("root set <path>", "校验后设置根目录"),
        ("root choose", "弹出系统目录选择器"),
        ("root reset", "重置为默认目录"),
        ("root finder-follow on|off|toggle", "访达跟随开关"),
        ("root clipboard", "剪贴板为现有目录时设为根"),
        ("root open", "在访达打开固定根目录"),
        ("finder copy", "复制访达选中项绝对路径"),
        ("codex status", "当前项目名 + 根目录"),
        ("codex sync on|off|toggle", "codex跟随开关"),
        ("codex model", "当前模型与一致性"),
        ("codex model list", "实时拉取 Anker 模型列表"),
        ("codex model set <id>", "切换模型并强制重启 Codex"),
        ("wechat status", "是否已绑定"),
        ("wechat bind", "触发扫码绑定"),
        ("wechat send [--to <id>] [--text <文字>] [文件...]", "向最近会话发送文字、图片或附件"),
        ("togent list", "列出 Togent 角色"),
        ("togent show <name>", "回显角色详情与提示词"),
        ("togent models", "列出当前健康中转模型"),
        ("togent create --name <英文名> [...]", "新增角色（不能提交 Agent 任务）"),
        ("togent copy <源名称> [...]", "复制提示词与模型，生成独立新角色"),
        ("togent update <名称> [...]", "更新角色字段"),
        ("togent open <名称>", "打开已保存角色工作区"),
        ("model status", "模型中转状态摘要（不含密钥）"),
        ("model port [1024...65535]", "读取或设置中转端口"),
        ("model models", "列出当前健康 published 模型"),
        ("model log", "打开今日调用日志"),
        ("blackout", "工具 → 临时黑屏（别名 .lshp）"),
        ("login on|off|toggle", "开机自启"),
        ("wheel vertical on|off|toggle", "对调垂直滚轮"),
        ("wheel horizontal on|off|toggle", "对调横向滚轮"),
        ("hidden on|off|toggle", "显示/隐藏隐藏文件"),
        ("shortcut finder-move on|off|toggle", "x/v 移动文件"),
        ("shortcut double-cmdq on|off|toggle", "双击 ⌘Q"),
        ("shortcut finder-cmdq on|off|toggle", "⌘Q 强关访达"),
        ("quit", "退出 Tocode")
    ]

    static var weChatHelpText: String {
        var lines: [String] = ["tocode 微信命令表：", ""]
        for entry in weChatHelpCommands {
            lines.append("```\n.\(entry.command)\n```")
            lines.append(entry.description)
            lines.append("")
        }
        lines.append("快捷输入（整条消息，不要加点号）：")
        lines.append("")
        lines.append("```\n{space}\n```")
        lines.append("按下空格")
        lines.append("")
        lines.append("```\n\u{201C}\u{4F60}\u{597D}\u{201D}\n```")
        lines.append("输入文字")
        lines.append("")
        lines.append("```\n\u{201C}\u{4F60}\u{597D}\u{201D}{enter}\n```")
        lines.append("先输入文字再回车")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func isHelpCommand(_ body: String) -> Bool {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "help" || normalized == "commands"
    }

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
        case "finder":
            return parseFinder(rest)
        case "codex":
            return parseCodex(rest)
        case "wechat":
            return parseWechat(rest)
        case "togent":
            return parseTogent(rest)
        case "model":
            return parseModel(rest)
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
            return .failure(.invalidArguments("root init-from-finder 已改为 root finder-follow on|off|toggle"))
        case "finder-follow":
            guard tokens.count == 2 else { return .failure(.invalidArguments("root finder-follow on|off|toggle")) }
            guard let toggle = parseToggle([tokens[1]], verb: "root finder-follow") else {
                return .failure(.invalidToggle(tokens[1]))
            }
            return .success(.root(.finderFollow(toggle)))
        case "clipboard":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root clipboard")) }
            return .success(.root(.clipboard))
        case "open":
            guard tokens.count == 1 else { return .failure(.invalidArguments("root open")) }
            return .success(.root(.open))
        default:
            return .failure(.unknownCommand("root \(sub)"))
        }
    }

    private static func parseFinder(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .failure(.missingValue("finder copy"))
        }
        switch sub {
        case "copy":
            guard tokens.count == 1 else { return .failure(.invalidArguments("finder copy")) }
            return .success(.finder(.copy))
        default:
            return .failure(.unknownCommand("finder \(sub)"))
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
        case "send":
            return parseWechatSend(Array(tokens.dropFirst()))
        default:
            return .failure(.unknownCommand("wechat \(sub)"))
        }
    }

    private static func parseTogent(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .failure(.missingValue("togent list|show|models|create|copy|update|open"))
        }
        let rest = Array(tokens.dropFirst())
        switch sub {
        case "list":
            guard rest.isEmpty else { return .failure(.invalidArguments("togent list")) }
            return .success(.togent(.list))
        case "models":
            guard rest.isEmpty else { return .failure(.invalidArguments("togent models")) }
            return .success(.togent(.models))
        case "show":
            guard rest.count == 1 else { return .failure(.missingValue("togent show <name>")) }
            return .success(.togent(.show(rest[0])))
        case "open":
            guard rest.count == 1 else { return .failure(.missingValue("togent open <name>")) }
            return .success(.togent(.open(rest[0])))
        case "create":
            switch parseTogentOptions(rest) {
            case .failure(let error):
                return .failure(error)
            case .success(let options):
                guard let name = options.name, !name.isEmpty else {
                    return .failure(.missingValue("togent create --name <英文名>"))
                }
                return .success(.togent(.create(options)))
            }
        case "copy":
            guard let source = rest.first else {
                return .failure(.missingValue("togent copy <源名称>"))
            }
            switch parseTogentOptions(Array(rest.dropFirst())) {
            case .failure(let error):
                return .failure(error)
            case .success(let options):
                return .success(.togent(.copy(sourceName: source, options: options)))
            }
        case "update":
            guard let name = rest.first else {
                return .failure(.missingValue("togent update <名称>"))
            }
            switch parseTogentOptions(Array(rest.dropFirst())) {
            case .failure(let error):
                return .failure(error)
            case .success(let options):
                guard options.name != nil
                        || options.workspacePath != nil
                        || options.publishedModelID != nil
                        || options.isActive != nil
                        || options.prompt != nil else {
                    return .failure(.missingValue("togent update <名称> [--name|--path|--model|--active|--prompt|--prompt-file]"))
                }
                return .success(.togent(.update(name: name, options: options)))
            }
        default:
            return .failure(.unknownCommand("togent \(sub)"))
        }
    }

    private static func parseTogentOptions(
        _ tokens: [String]
    ) -> Result<TocodeTogentRoleOptions, TocodeCommandError> {
        var options = TocodeTogentRoleOptions()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--name":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --name <英文名>"))
                }
                options.name = tokens[index + 1]
                index += 2
            case "--path":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --path <路径>"))
                }
                options.workspacePath = tokens[index + 1]
                index += 2
            case "--model":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --model <id>"))
                }
                options.publishedModelID = tokens[index + 1]
                index += 2
            case "--active":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --active on|off"))
                }
                switch tokens[index + 1].lowercased() {
                case "on":
                    options.isActive = true
                case "off":
                    options.isActive = false
                default:
                    return .failure(.invalidToggle(tokens[index + 1]))
                }
                index += 2
            case "--prompt-file":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --prompt-file <文件>"))
                }
                if options.prompt != nil {
                    return .failure(.invalidArguments("togent 不能同时使用 --prompt 与 --prompt-file"))
                }
                let filePath = (tokens[index + 1] as NSString).expandingTildeInPath
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                      let text = String(data: data, encoding: .utf8) else {
                    return .failure(.operationFailed("无法读取提示词文件：\(tokens[index + 1])"))
                }
                options.prompt = text
                index += 2
            case "--prompt":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("togent --prompt <文本>"))
                }
                if options.prompt != nil {
                    return .failure(.invalidArguments("togent 不能同时使用 --prompt 与 --prompt-file"))
                }
                options.prompt = tokens[(index + 1)...].joined(separator: " ")
                index = tokens.count
            default:
                if token.hasPrefix("--") {
                    return .failure(.invalidArguments("togent \(token)"))
                }
                return .failure(.invalidArguments("togent \(token)"))
            }
        }
        return .success(options)
    }

    private static func parseModel(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .failure(.missingValue("model status|port|models|log"))
        }
        let rest = Array(tokens.dropFirst())
        switch sub {
        case "status":
            guard rest.isEmpty else { return .failure(.invalidArguments("model status")) }
            return .success(.model(.status))
        case "models":
            guard rest.isEmpty else { return .failure(.invalidArguments("model models")) }
            return .success(.model(.models))
        case "log":
            guard rest.isEmpty else { return .failure(.invalidArguments("model log")) }
            return .success(.model(.log))
        case "port":
            if rest.isEmpty {
                return .success(.model(.portGet))
            }
            guard rest.count == 1, let value = Int(rest[0]), (1024...65_535).contains(value) else {
                return .failure(.invalidArguments("model port <1024...65535>"))
            }
            return .success(.model(.portSet(value)))
        default:
            return .failure(.unknownCommand("model \(sub)"))
        }
    }

    private static func parseWechatSend(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var toUserID: String?
        var text: String?
        var files: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--to":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("wechat send --to <user_id>"))
                }
                toUserID = tokens[index + 1]
                index += 2
            case "--text":
                guard index + 1 < tokens.count else {
                    return .failure(.missingValue("wechat send --text <文字>"))
                }
                text = tokens[index + 1]
                index += 2
            default:
                if token.hasPrefix("--") {
                    return .failure(.invalidArguments("wechat send \(token)"))
                }
                files.append(token)
                index += 1
            }
        }
        let trimmedTo = toUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTo, trimmedTo.isEmpty {
            return .failure(.invalidArguments("wechat send --to"))
        }
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedText = (trimmedText?.isEmpty == false) ? trimmedText : nil
        guard resolvedText != nil || !files.isEmpty else {
            return .failure(.missingValue("wechat send --text <文字> | <文件>"))
        }
        return .success(.wechat(.send(TocodeWechatSendPayload(
            toUserID: (trimmedTo?.isEmpty == false) ? trimmedTo : nil,
            text: resolvedText,
            files: files
        ))))
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

enum TocodeWeChatRoutedInput: Equatable {
    case command(String)
    case quickInput([WeChatQuickInputSegment])
}

/// 微信入口分流：`.` 前缀命令优先；否则尝试拆成快捷输入段序列。
enum TocodeWeChatCommandGate {
    static func routedInput(from message: WeChatMessage) -> TocodeWeChatRoutedInput? {
        guard let first = message.items.first, first.type == 1,
              let raw = first.textItem?.text else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            let body = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .command(body)
        }
        if let segments = WeChatQuickInput.tokenize(trimmed) {
            return .quickInput(segments)
        }
        return nil
    }

    static func commandBody(from message: WeChatMessage) -> String? {
        if case .command(let body) = routedInput(from: message) {
            return body
        }
        return nil
    }
}
