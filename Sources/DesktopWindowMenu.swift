import Foundation

/// 菜单栏主键点击的去向。右键始终是功能菜单；左键只在正在按住 totti 时打开桌面窗口菜单。
enum StatusItemPrimaryClick: Equatable {
    case directory
    case actionMenu
    case desktopWindows

    static func resolve(isRightClick: Bool, tottiHeld: Bool) -> StatusItemPrimaryClick {
        if isRightClick { return .actionMenu }
        return tottiHeld ? .desktopWindows : .directory
    }
}

enum DesktopSpaceKind: Equatable {
    case desktop
    case fullscreen
}

struct DesktopSpaceTarget: Equatable {
    let displayID: String
    let spaceID: UInt64
    var kind: DesktopSpaceKind
    var pid: Int32
    var focusWindowID: UInt32

    init(
        displayID: String,
        spaceID: UInt64,
        kind: DesktopSpaceKind = .desktop,
        pid: Int32 = 0,
        focusWindowID: UInt32 = 0
    ) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.kind = kind
        self.pid = pid
        self.focusWindowID = focusWindowID
    }
}

struct DesktopWindowFacts: Equatable {
    var pid: Int32
    var ownerName: String
    var listTitle: String
    var accessibilityTitle: String?
    var appName: String
    var layer: Int
    var minimized: Bool
    var alpha: Double = 1
    /// 系统仍把它算在这个桌面上，但已经撤出显示时为 false。
    var orderedIn: Bool = true
}

struct SkyLightSpaceDump: Equatable {
    let spaceID: UInt64
    let type: Int
    var pid: Int32
    var appName: String
    var windowIDs: [UInt32]

    init(spaceID: UInt64, type: Int, pid: Int32 = 0, appName: String = "", windowIDs: [UInt32]) {
        self.spaceID = spaceID
        self.type = type
        self.pid = pid
        self.appName = appName
        self.windowIDs = windowIDs
    }

    var kind: DesktopSpaceKind? {
        switch type {
        case 0: return .desktop
        case 4: return .fullscreen
        default: return nil
        }
    }
}

struct SkyLightDisplayDump: Equatable {
    let identifier: String
    let currentSpaceID: UInt64
    let spaces: [SkyLightSpaceDump]
}

struct DesktopMenuWindow: Equatable {
    let title: String
    let windowID: UInt32
    let pid: Int32
    let target: DesktopSpaceTarget
}

struct DesktopMenuSpace: Equatable {
    let title: String
    let isCurrent: Bool
    let target: DesktopSpaceTarget
    let windows: [DesktopMenuWindow]
}

enum DesktopMenuEntry: Equatable {
    case display(title: String, spaces: [DesktopMenuSpace])
    case space(DesktopMenuSpace)
}

enum DesktopWindowStep: Equatable {
    case switchSpace(DesktopSpaceTarget)
    case raiseWindow(pid: Int32, windowID: UInt32)
}

final class DesktopWindowCommandBox: NSObject {
    let command: DesktopWindowCommand

    init(_ command: DesktopWindowCommand) {
        self.command = command
    }
}

enum DesktopWindowCommand: Equatable {
    case space(DesktopSpaceTarget)
    case window(DesktopSpaceTarget, windowID: UInt32, pid: Int32)

    var steps: [DesktopWindowStep] {
        switch self {
        case .space(let target):
            return [.switchSpace(target)]
        case .window(let target, let windowID, let pid):
            return [.switchSpace(target), .raiseWindow(pid: pid, windowID: windowID)]
        }
    }

    /// 实际切换使用的目标。点窗口时把焦点窗口改成被点的那一个。
    var spaceTarget: DesktopSpaceTarget {
        switch self {
        case .space(let target):
            return target
        case .window(let target, let windowID, let pid):
            return DesktopSpaceTarget(
                displayID: target.displayID,
                spaceID: target.spaceID,
                kind: target.kind,
                pid: pid > 0 ? pid : target.pid,
                focusWindowID: windowID != 0 ? windowID : target.focusWindowID
            )
        }
    }
}

enum DesktopSpaceStep: Equatable {
    /// 调度中心顺序里更靠后的一格。
    case towardHigherIndex
    /// 调度中心顺序里更靠前的一格。
    case towardLowerIndex
}

enum DesktopSpacePath {
    /// 从当前空间走到目标空间要经过的每一格。已经在目标上时为空。认不出编号时返回 nil。
    static func steps(spaceIDs: [UInt64], current: UInt64, target: UInt64) -> [DesktopSpaceStep]? {
        guard let from = spaceIDs.firstIndex(of: current), let to = spaceIDs.firstIndex(of: target) else { return nil }
        if from == to { return [] }
        let step: DesktopSpaceStep = to > from ? .towardHigherIndex : .towardLowerIndex
        return Array(repeating: step, count: abs(to - from))
    }
}

enum DesktopWindowActivation {
    /// 空间没有变成目标时不得前置窗口。点击桌面夹只切空间。
    static func shouldRaise(switched: Bool, command: DesktopWindowCommand) -> Bool {
        guard switched else { return false }
        if case .window = command { return true }
        return false
    }
}

enum DesktopSpaceWindowLists {
    /// 用按空间查到的窗口编号覆盖对应空间。没查到的空间保留原来的编号。
    static func apply(_ windowsBySpace: [UInt64: [UInt32]], to displays: [SkyLightDisplayDump]) -> [SkyLightDisplayDump] {
        displays.map { display in
            SkyLightDisplayDump(
                identifier: display.identifier,
                currentSpaceID: display.currentSpaceID,
                spaces: display.spaces.map { space in
                    guard let ids = windowsBySpace[space.spaceID] else { return space }
                    return SkyLightSpaceDump(
                        spaceID: space.spaceID,
                        type: space.type,
                        pid: space.pid,
                        appName: space.appName,
                        windowIDs: ids
                    )
                }
            )
        }
    }
}

enum DesktopSpaceAppNames {
    static func apply(_ names: [Int32: String], to displays: [SkyLightDisplayDump]) -> [SkyLightDisplayDump] {
        displays.map { display in
            SkyLightDisplayDump(
                identifier: display.identifier,
                currentSpaceID: display.currentSpaceID,
                spaces: display.spaces.map { space in
                    let provided = names[space.pid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard space.pid > 0, !provided.isEmpty else { return space }
                    return SkyLightSpaceDump(
                        spaceID: space.spaceID,
                        type: space.type,
                        pid: space.pid,
                        appName: provided,
                        windowIDs: space.windowIDs
                    )
                }
            )
        }
    }
}

enum SkyLightSpaceDumpParser {
    /// 解析 CGSCopyManagedDisplaySpaces 的显示器数组。结构认不出时返回 nil。
    static func parse(_ rawDisplays: [Any]) -> [SkyLightDisplayDump]? {
        var displays: [SkyLightDisplayDump] = []
        var sawDictionary = false
        for item in rawDisplays {
            guard let dictionary = nsDictionary(item) else { continue }
            sawDictionary = true
            guard let identifier = dictionary["Display Identifier"] as? String, !identifier.isEmpty else {
                continue
            }
            guard let current = spaceID(in: dictionary["Current Space"]) else { continue }
            let spaces = array(dictionary["Spaces"]).compactMap(parseSpace)
            displays.append(SkyLightDisplayDump(
                identifier: identifier,
                currentSpaceID: current,
                spaces: spaces
            ))
        }
        guard sawDictionary, !displays.isEmpty else { return nil }
        return displays
    }

    private static func parseSpace(_ value: Any) -> SkyLightSpaceDump? {
        guard let dictionary = nsDictionary(value), let spaceID = spaceID(in: dictionary) else {
            return nil
        }
        let type = uInt(dictionary["type"]) ?? 0
        return SkyLightSpaceDump(
            spaceID: spaceID,
            type: type,
            pid: int32(dictionary["pid"]) ?? 0,
            windowIDs: array(dictionary["Windows"]).compactMap(uInt32)
        )
    }

    private static func nsDictionary(_ value: Any?) -> NSDictionary? {
        if let dictionary = value as? NSDictionary { return dictionary }
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary as NSDictionary
    }

    private static func spaceID(in value: Any?) -> UInt64? {
        guard let dictionary = nsDictionary(value) else { return nil }
        return uInt64(dictionary["id64"]) ?? uInt64(dictionary["ManagedSpaceID"])
    }

    private static func array(_ value: Any?) -> [Any] {
        if let list = value as? [Any] { return list }
        if let list = value as? NSArray { return list.map { $0 } }
        return []
    }

    private static func uInt64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func uInt(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func uInt32(_ value: Any) -> UInt32? {
        (value as? NSNumber)?.uint32Value
    }

    private static func int32(_ value: Any?) -> Int32? {
        (value as? NSNumber)?.int32Value
    }
}

enum DesktopWindowOrderedState {
    static func apply(
        _ flags: [UInt32: Bool],
        to facts: [UInt32: DesktopWindowFacts]
    ) -> [UInt32: DesktopWindowFacts] {
        guard !flags.isEmpty else { return facts }
        var copy = facts
        for (windowID, orderedIn) in flags {
            copy[windowID]?.orderedIn = orderedIn
        }
        return copy
    }
}

enum DesktopWindowMenuBuilder {
    static let excludedOwners: Set<String> = [
        "Window Server",
        "Dock",
        "Control Center",
        "ControlCenter",
        "Notification Center",
        "NotificationCenter",
        "Wallpaper",
        "SystemUIServer"
    ]

    static func make(
        displays: [SkyLightDisplayDump],
        names: [String: String],
        windows: [UInt32: DesktopWindowFacts],
        frontToBack: [UInt32]
    ) -> [DesktopMenuEntry] {
        let visible: [(id: String, spaces: [DesktopMenuSpace])] = displays.compactMap { display in
            let spaces = menuSpaces(display, windows: windows, frontToBack: frontToBack)
            guard !spaces.isEmpty else { return nil }
            return (display.identifier, spaces)
        }
        guard !visible.isEmpty else { return [] }
        if visible.count == 1, let only = visible.first {
            return only.spaces.map { .space($0) }
        }
        return visible.enumerated().map { index, item in
            let provided = names[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = provided.isEmpty ? "显示器 \(index + 1)" : provided
            return .display(title: title, spaces: item.spaces)
        }
    }

    static func windowTitle(_ facts: DesktopWindowFacts) -> String {
        let listed = facts.listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = facts.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = facts.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if !listed.isEmpty {
            base = listed
        } else if !app.isEmpty {
            base = app
        } else if !owner.isEmpty {
            base = owner
        } else {
            base = "窗口"
        }
        return facts.minimized ? "\(base)（最小化）" : base
    }

    static func include(_ facts: DesktopWindowFacts) -> Bool {
        let owner = facts.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if excludedOwners.contains(owner) { return false }
        if facts.pid <= 0 { return false }
        if facts.alpha <= 0 { return false }
        if !facts.orderedIn { return false }
        if facts.layer != 0 && !facts.minimized { return false }
        return true
    }

    private static func menuSpaces(
        _ display: SkyLightDisplayDump,
        windows: [UInt32: DesktopWindowFacts],
        frontToBack: [UInt32]
    ) -> [DesktopMenuSpace] {
        var desktopIndex = 0
        var result: [DesktopMenuSpace] = []
        for space in display.spaces {
            guard let kind = space.kind else { continue }
            let includedFacts = order(space.windowIDs, frontToBack: frontToBack).compactMap { windowID -> (UInt32, DesktopWindowFacts)? in
                guard let facts = windows[windowID], include(facts) else { return nil }
                return (windowID, facts)
            }
            let focus = includedFacts.first
            let target = DesktopSpaceTarget(
                displayID: display.identifier,
                spaceID: space.spaceID,
                kind: kind,
                pid: space.pid > 0 ? space.pid : (focus?.1.pid ?? 0),
                focusWindowID: focus?.0 ?? 0
            )
            let included: [DesktopMenuWindow] = includedFacts.map { item in
                let (windowID, facts) = item
                return DesktopMenuWindow(
                    title: windowTitle(facts),
                    windowID: windowID,
                    pid: facts.pid,
                    target: target
                )
            }
            let title: String
            switch kind {
            case .desktop:
                desktopIndex += 1
                title = "桌面 \(desktopIndex)"
            case .fullscreen:
                title = fullscreenTitle(space, windows: included, facts: windows)
            }
            result.append(DesktopMenuSpace(
                title: title,
                isCurrent: space.spaceID == display.currentSpaceID,
                target: target,
                windows: kind == .desktop ? included : []
            ))
        }
        return result
    }

    private static func fullscreenTitle(
        _ space: SkyLightSpaceDump,
        windows: [DesktopMenuWindow],
        facts: [UInt32: DesktopWindowFacts]
    ) -> String {
        let named = space.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        guard let first = windows.first, let info = facts[first.windowID] else { return "全屏" }
        let app = info.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty { return app }
        let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return "全屏"
    }

    private static func order(_ ids: [UInt32], frontToBack: [UInt32]) -> [UInt32] {
        var rank: [UInt32: Int] = [:]
        for (index, windowID) in frontToBack.enumerated() where rank[windowID] == nil {
            rank[windowID] = index
        }
        return ids.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element] ?? Int.max
            let right = rank[rhs.element] ?? Int.max
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// 手机遥控看到的桌面目录。内容和菜单栏那份相同，只多一个「当前窗口」标记。
enum PhoneDesktopList {
    static func body(_ entries: [DesktopMenuEntry]) -> [String: Any] {
        [
            "displays": groups(entries).map { group in
                [
                    "title": group.title,
                    "spaces": group.spaces.map(spaceBody),
                ]
            },
        ]
    }

    static func command(entries: [DesktopMenuEntry], target: [String: Any]) -> DesktopWindowCommand? {
        guard let displayID = target["display_id"] as? String, !displayID.isEmpty else { return nil }
        guard let spaceID = unsigned(target["space_id"]) else { return nil }
        let windowID = UInt32(truncatingIfNeeded: unsigned(target["window_id"]) ?? 0)
        let pid = Int32(truncatingIfNeeded: unsigned(target["pid"]) ?? 0)
        if (windowID == 0) != (pid == 0) { return nil }
        for group in groups(entries) {
            for space in group.spaces where space.target.displayID == displayID && space.target.spaceID == spaceID {
                if windowID == 0 { return .space(space.target) }
                guard let window = space.windows.first(where: { $0.windowID == windowID && $0.pid == pid }) else {
                    return nil
                }
                return .window(window.target, windowID: window.windowID, pid: window.pid)
            }
        }
        return nil
    }

    private static func groups(_ entries: [DesktopMenuEntry]) -> [(title: String, spaces: [DesktopMenuSpace])] {
        var displays: [(title: String, spaces: [DesktopMenuSpace])] = []
        var loose: [DesktopMenuSpace] = []
        for entry in entries {
            switch entry {
            case .display(let title, let spaces):
                displays.append((title, spaces))
            case .space(let space):
                loose.append(space)
            }
        }
        if !displays.isEmpty { return displays }
        return loose.isEmpty ? [] : [("", loose)]
    }

    private static func spaceBody(_ space: DesktopMenuSpace) -> [String: Any] {
        [
            "title": space.title,
            "current": space.isCurrent,
            "kind": space.target.kind == .fullscreen ? "fullscreen" : "desktop",
            "display_id": space.target.displayID,
            "space_id": NSNumber(value: space.target.spaceID),
            "windows": space.windows.enumerated().map { index, window in
                [
                    "title": window.title,
                    "window_id": NSNumber(value: window.windowID),
                    "pid": NSNumber(value: window.pid),
                    "front": space.isCurrent && index == 0,
                ]
            },
        ]
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let value, !(value is Bool) else { return nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            if number.doubleValue < 0 { return nil }
            return number.uint64Value
        }
        if let int = value as? Int, int >= 0 { return UInt64(int) }
        if let int = value as? UInt64 { return int }
        if let int = value as? UInt32 { return UInt64(int) }
        return nil
    }
}
