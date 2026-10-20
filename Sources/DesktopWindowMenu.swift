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
}

struct DesktopWindowFacts: Equatable {
    var pid: Int32
    var ownerName: String
    var listTitle: String
    var accessibilityTitle: String?
    var appName: String
    var layer: Int
    var minimized: Bool
}

struct SkyLightSpaceDump: Equatable {
    let spaceID: UInt64
    let type: Int
    let windowIDs: [UInt32]

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
        let accessibility = facts.accessibilityTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listed = facts.listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = facts.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = facts.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if !accessibility.isEmpty {
            base = accessibility
        } else if !listed.isEmpty {
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
            let target = DesktopSpaceTarget(displayID: display.identifier, spaceID: space.spaceID)
            let included = order(space.windowIDs, frontToBack: frontToBack).compactMap { windowID -> DesktopMenuWindow? in
                guard let facts = windows[windowID], include(facts) else { return nil }
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
                title = fullscreenTitle(included, windows: windows)
            }
            result.append(DesktopMenuSpace(
                title: title,
                isCurrent: space.spaceID == display.currentSpaceID,
                target: target,
                windows: included
            ))
        }
        return result
    }

    private static func fullscreenTitle(
        _ windows: [DesktopMenuWindow],
        windows facts: [UInt32: DesktopWindowFacts]
    ) -> String {
        guard let first = windows.first, let info = facts[first.windowID] else { return "全屏" }
        let app = info.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty { return "全屏 · \(app)" }
        let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return "全屏 · \(title)" }
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
