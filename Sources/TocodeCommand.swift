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
    case location
    case send(TocodeWechatSendPayload)
}

struct TocodeBookmarkAddPayload: Equatable {
    var url: String
    var title: String?
    var folder: String?
    var siblingIndex: Int?
}

struct TocodeBookmarkUpdatePayload: Equatable {
    var url: String
    var title: String?
    var folder: String?
    var siblingIndex: Int?
    var newURL: String?
}

enum TocodeBookmarkBackupCommand: Equatable {
    case status
    case list
    case now
    case restore(day: String?)
}

enum TocodeBookmarkFolderCommand: Equatable {
    case create(path: String, index: Int?)
    case delete(path: String, recursive: Bool)
    case pruneEmpty(under: String?)
    case move(path: String, to: String?, index: Int?)
}

enum TocodeBookmarkCommand: Equatable {
    case status
    case list
    case get(String)
    case add(TocodeBookmarkAddPayload)
    case update(TocodeBookmarkUpdatePayload)
    case delete(String)
    case pull
    case log(Int)
    case folders
    case folder(TocodeBookmarkFolderCommand)
    case apply(file: String, dryRun: Bool)
    case backup(TocodeBookmarkBackupCommand)
}

enum TocodeCommand: Equatable {
    case help
    case status
    case root(TocodeRootCommand)
    case finder(TocodeFinderCommand)
    case codex(TocodeCodexCommand)
    case wechat(TocodeWechatCommand)
    case bookmark(TocodeBookmarkCommand)
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
        status                              根目录、各开关、微信与 Codex 状态汇总

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

      微信
        wechat status                       是否已绑定
        wechat bind                         触发扫码绑定
        wechat location                     创建并在访达打开归档目录
        wechat send [--to <id>] [--text <文字>] [文件...]
                                            向最近会话发送文字、图片或附件

      书签（JSON；须 Tocode 在运行）
        bookmark status                     条数、远程开关、是否有密钥、修订号
        bookmark list                       全部书签 JSON 数组
        bookmark get <url>                  单条书签 JSON
        bookmark add --url <url> [--title <标题>] [--folder toolbar|other|mobile|<路径>] [--index <n>]
        bookmark update --url <url> [--title <标题>] [--folder ...] [--index <n>] [--new-url <url>]
        bookmark delete --url <url>         删除并写墓碑
        bookmark pull                       用本机远程同步密钥拉取并合并最新账本
        bookmark log [行数]                 打印最近同步活动日志（默认 80 行）
        bookmark folders [--json]           只读导出夹树 JSON（含顺序与是否空）
        bookmark folder create <path> [--index <n>]
                                            新建空夹（含祖先）
        bookmark folder delete <path> [--recursive]
                                            删空夹；递归只删空夹树（有书签则失败）
        bookmark folder prune-empty [--under <path>]
                                            批量清理空壳夹
        bookmark folder move <path> --index <n>
        bookmark folder move <path> --to <newPath> [--index <n>]
                                            同父改序，或改路径并迁移子项
        bookmark apply --file <plan.json> [--dry-run]
                                            串行批处理 add|update|delete
        bookmark backup status|list|now     七日备份状态 / 列表 / 立即日备
        bookmark backup restore [--day YYYY-MM-DD]
                                            从指定日（默认最近）整本还原正式账本

      书签 --folder / folder 路径
        toolbar|other|mobile|书签栏|其他书签|移动设备书签
                                            三个根（可单独）
        toolbar/<路径>  other/<路径>  mobile/<路径>
        书签栏/<路径>  其他书签/<路径> …
                                            根下具名夹
        named:<路径> 或 <路径>              具名（named）；非法根写法会报错

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
        case "bookmark":
            return parseBookmark(rest)
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
        default:
            return .failure(.unknownCommand("codex \(sub)"))
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
        case "send":
            return parseWechatSend(Array(tokens.dropFirst()))
        default:
            return .failure(.unknownCommand("wechat \(sub)"))
        }
    }

    private static func parseBookmark(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .success(.bookmark(.status))
        }
        switch sub {
        case "status":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark status")) }
            return .success(.bookmark(.status))
        case "list":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark list")) }
            return .success(.bookmark(.list))
        case "get":
            guard tokens.count >= 2 else { return .failure(.missingValue("bookmark get <url>")) }
            let url = tokens.dropFirst().joined(separator: " ")
            return .success(.bookmark(.get(url)))
        case "add":
            return parseBookmarkAdd(Array(tokens.dropFirst()))
        case "update":
            return parseBookmarkUpdate(Array(tokens.dropFirst()))
        case "delete", "remove", "rm":
            return parseBookmarkDelete(Array(tokens.dropFirst()))
        case "pull", "sync":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark pull")) }
            return .success(.bookmark(.pull))
        case "log":
            if tokens.count == 1 {
                return .success(.bookmark(.log(80)))
            }
            guard tokens.count == 2, let lines = Int(tokens[1]), lines > 0 else {
                return .failure(.invalidArguments("bookmark log [行数]"))
            }
            return .success(.bookmark(.log(min(lines, 2000))))
        case "folders":
            if tokens.count == 1 {
                return .success(.bookmark(.folders))
            }
            guard tokens.count == 2, tokens[1] == "--json" || tokens[1] == "-json" else {
                return .failure(.invalidArguments("bookmark folders [--json]"))
            }
            return .success(.bookmark(.folders))
        case "folder":
            return parseBookmarkFolder(Array(tokens.dropFirst()))
        case "apply":
            return parseBookmarkApply(Array(tokens.dropFirst()))
        case "backup":
            return parseBookmarkBackup(Array(tokens.dropFirst()))
        default:
            return .failure(.unknownCommand("bookmark \(sub)"))
        }
    }

    private static func parseBookmarkFolder(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .failure(.missingValue("bookmark folder create|delete|prune-empty|move"))
        }
        let rest = Array(tokens.dropFirst())
        switch sub {
        case "create":
            return parseFolderCreate(rest)
        case "delete", "rm", "remove":
            return parseFolderDelete(rest)
        case "prune-empty", "prune":
            return parseFolderPrune(rest)
        case "move":
            return parseFolderMove(rest)
        default:
            return .failure(.unknownCommand("bookmark folder \(sub)"))
        }
    }

    private static func parseFolderCreate(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var path: String?
        var index: Int?
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--index" || t == "-index" {
                guard i + 1 < tokens.count, let n = Int(tokens[i + 1]), n >= 0 else {
                    return .failure(.invalidArguments("bookmark folder create --index <n>"))
                }
                index = n
                i += 2
            } else if t.hasPrefix("-") {
                return .failure(.invalidArguments("bookmark folder create <path> [--index <n>]"))
            } else if path == nil {
                path = t
                i += 1
            } else {
                return .failure(.invalidArguments("bookmark folder create <path> [--index <n>]"))
            }
        }
        guard let path, !path.isEmpty else {
            return .failure(.missingValue("bookmark folder create <path>"))
        }
        return .success(.bookmark(.folder(.create(path: path, index: index))))
    }

    private static func parseFolderDelete(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var path: String?
        var recursive = false
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--recursive" || t == "-r" {
                recursive = true
                i += 1
            } else if t.hasPrefix("-") {
                return .failure(.invalidArguments("bookmark folder delete <path> [--recursive]"))
            } else if path == nil {
                path = t
                i += 1
            } else {
                return .failure(.invalidArguments("bookmark folder delete <path> [--recursive]"))
            }
        }
        guard let path, !path.isEmpty else {
            return .failure(.missingValue("bookmark folder delete <path>"))
        }
        return .success(.bookmark(.folder(.delete(path: path, recursive: recursive))))
    }

    private static func parseFolderPrune(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var under: String?
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--under" {
                guard i + 1 < tokens.count else {
                    return .failure(.missingValue("bookmark folder prune-empty --under <path>"))
                }
                under = tokens[i + 1]
                i += 2
            } else if t.hasPrefix("-") {
                return .failure(.invalidArguments("bookmark folder prune-empty [--under <path>]"))
            } else {
                return .failure(.invalidArguments("bookmark folder prune-empty [--under <path>]"))
            }
        }
        return .success(.bookmark(.folder(.pruneEmpty(under: under))))
    }

    private static func parseFolderMove(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var path: String?
        var to: String?
        var index: Int?
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--to" {
                guard i + 1 < tokens.count else {
                    return .failure(.missingValue("bookmark folder move --to <newPath>"))
                }
                to = tokens[i + 1]
                i += 2
            } else if t == "--index" || t == "-index" {
                guard i + 1 < tokens.count, let n = Int(tokens[i + 1]), n >= 0 else {
                    return .failure(.invalidArguments("bookmark folder move --index <n>"))
                }
                index = n
                i += 2
            } else if t.hasPrefix("-") {
                return .failure(.invalidArguments("bookmark folder move <path> (--index <n>|--to <newPath>)"))
            } else if path == nil {
                path = t
                i += 1
            } else {
                return .failure(.invalidArguments("bookmark folder move <path> (--index <n>|--to <newPath>)"))
            }
        }
        guard let path, !path.isEmpty else {
            return .failure(.missingValue("bookmark folder move <path>"))
        }
        guard to != nil || index != nil else {
            return .failure(.invalidArguments("bookmark folder move 须提供 --index 或 --to"))
        }
        return .success(.bookmark(.folder(.move(path: path, to: to, index: index))))
    }

    private static func parseBookmarkApply(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var file: String?
        var dryRun = false
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--file" || t == "-f" {
                guard i + 1 < tokens.count else {
                    return .failure(.missingValue("bookmark apply --file <plan.json>"))
                }
                file = tokens[i + 1]
                i += 2
            } else if t == "--dry-run" || t == "--dryrun" {
                dryRun = true
                i += 1
            } else if t.hasPrefix("-") {
                return .failure(.invalidArguments("bookmark apply --file <plan.json> [--dry-run]"))
            } else if file == nil {
                file = t
                i += 1
            } else {
                return .failure(.invalidArguments("bookmark apply --file <plan.json> [--dry-run]"))
            }
        }
        guard let file, !file.isEmpty else {
            return .failure(.missingValue("bookmark apply --file <plan.json>"))
        }
        return .success(.bookmark(.apply(file: file, dryRun: dryRun)))
    }

    private static func parseBookmarkBackup(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        guard let sub = tokens.first?.lowercased() else {
            return .failure(.missingValue("bookmark backup status|list|now|restore"))
        }
        switch sub {
        case "status":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark backup status")) }
            return .success(.bookmark(.backup(.status)))
        case "list":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark backup list")) }
            return .success(.bookmark(.backup(.list)))
        case "now":
            guard tokens.count == 1 else { return .failure(.invalidArguments("bookmark backup now")) }
            return .success(.bookmark(.backup(.now)))
        case "restore":
            return parseBookmarkBackupRestore(Array(tokens.dropFirst()))
        default:
            return .failure(.unknownCommand("bookmark backup \(sub)"))
        }
    }

    private static func parseBookmarkBackupRestore(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        if tokens.isEmpty {
            return .success(.bookmark(.backup(.restore(day: nil))))
        }
        var day: String?
        var cursor = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            switch token {
            case "--day":
                guard cursor + 1 < tokens.count else {
                    return .failure(.missingValue("bookmark backup restore --day YYYY-MM-DD"))
                }
                day = tokens[cursor + 1]
                cursor += 2
            default:
                if day == nil, BookmarkBackupPackLogic.parseDay(token) != nil {
                    day = token
                    cursor += 1
                } else {
                    return .failure(.invalidArguments("bookmark backup restore \(token)"))
                }
            }
        }
        if let day, BookmarkBackupPackLogic.parseDay(day) == nil {
            return .failure(.invalidArguments("bookmark backup restore --day 须为 YYYY-MM-DD"))
        }
        return .success(.bookmark(.backup(.restore(day: day))))
    }

    private static func parseBookmarkAdd(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var url: String?
        var title: String?
        var folder: String?
        var siblingIndex: Int?
        var cursor = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            switch token {
            case "--url":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark add --url <url>")) }
                url = tokens[cursor + 1]
                cursor += 2
            case "--title":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark add --title <标题>")) }
                title = tokens[cursor + 1]
                cursor += 2
            case "--folder":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark add --folder <folder>")) }
                folder = tokens[cursor + 1]
                cursor += 2
            case "--index":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark add --index <n>")) }
                guard let value = Int(tokens[cursor + 1]), value >= 0 else {
                    return .failure(.invalidArguments("bookmark add --index 须为非负整数"))
                }
                siblingIndex = value
                cursor += 2
            default:
                return .failure(.invalidArguments("bookmark add \(token)"))
            }
        }
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingValue("bookmark add --url <url>"))
        }
        return .success(.bookmark(.add(TocodeBookmarkAddPayload(
            url: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex
        ))))
    }

    private static func parseBookmarkUpdate(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        var url: String?
        var title: String?
        var folder: String?
        var siblingIndex: Int?
        var newURL: String?
        var cursor = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            switch token {
            case "--url":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark update --url <url>")) }
                url = tokens[cursor + 1]
                cursor += 2
            case "--title":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark update --title <标题>")) }
                title = tokens[cursor + 1]
                cursor += 2
            case "--folder":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark update --folder <folder>")) }
                folder = tokens[cursor + 1]
                cursor += 2
            case "--index":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark update --index <n>")) }
                guard let value = Int(tokens[cursor + 1]), value >= 0 else {
                    return .failure(.invalidArguments("bookmark update --index 须为非负整数"))
                }
                siblingIndex = value
                cursor += 2
            case "--new-url":
                guard cursor + 1 < tokens.count else { return .failure(.missingValue("bookmark update --new-url <url>")) }
                newURL = tokens[cursor + 1]
                cursor += 2
            default:
                return .failure(.invalidArguments("bookmark update \(token)"))
            }
        }
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingValue("bookmark update --url <url>"))
        }
        guard title != nil || folder != nil || siblingIndex != nil || newURL != nil else {
            return .failure(.missingValue("bookmark update 至少提供 --title / --folder / --index / --new-url 之一"))
        }
        return .success(.bookmark(.update(TocodeBookmarkUpdatePayload(
            url: url,
            title: title,
            folder: folder,
            siblingIndex: siblingIndex,
            newURL: newURL
        ))))
    }

    private static func parseBookmarkDelete(_ tokens: [String]) -> Result<TocodeCommand, TocodeCommandError> {
        if tokens.count == 1, tokens[0] != "--url" {
            return .success(.bookmark(.delete(tokens[0])))
        }
        guard tokens.count == 2, tokens[0] == "--url" else {
            return .failure(.missingValue("bookmark delete --url <url>"))
        }
        return .success(.bookmark(.delete(tokens[1])))
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

