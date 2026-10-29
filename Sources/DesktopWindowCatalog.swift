import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

protocol DesktopWindowCataloging: AnyObject {
    /// 读不到桌面结构时返回 nil。
    func loadMenu() -> [DesktopMenuEntry]?
}

protocol DesktopSpaceSwitching: AnyObject {
    func switchToSpace(_ target: DesktopSpaceTarget) -> Bool
    func raiseWindow(pid: Int32, windowID: UInt32) -> Bool
}

/// 用 SkyLight 私有接口读取各显示器的空间和窗口。打开菜单时不查询辅助功能。
final class SystemDesktopWindowCatalog: DesktopWindowCataloging {
    func loadMenu() -> [DesktopMenuEntry]? {
        guard let raw = SkyLightSpaces.copyDisplayArray(),
              let parsed = SkyLightSpaceDumpParser.parse(raw) else {
            return nil
        }
        var displays = parsed
        if let bySpace = SkyLightSpaces.copyWindowIDs(in: displays) {
            displays = DesktopSpaceWindowLists.apply(bySpace, to: displays)
        }
        displays = DesktopSpaceAppNames.apply(SkyLightSpaces.appNames(in: displays), to: displays)
        let listed = WindowListReader.read()
        let names = DisplayNameResolver.names(for: displays.map(\.identifier))
        let windowIDs = displays.flatMap { $0.spaces.flatMap(\.windowIDs) }
        let facts = DesktopWindowOrderedState.apply(
            SkyLightSpaces.orderedInFlags(for: windowIDs) ?? [:],
            to: listed.facts
        )
        let entries = DesktopWindowMenuBuilder.make(
            displays: displays,
            names: names,
            windows: facts,
            frontToBack: listed.frontToBack
        )
        return entries.isEmpty ? nil : entries
    }
}

final class SystemDesktopSpaceSwitcher: DesktopSpaceSwitching {
    func switchToSpace(_ target: DesktopSpaceTarget) -> Bool {
        guard let layout = SkyLightSpaces.orderedSpaceIDs(displayID: target.displayID),
              let steps = DesktopSpacePath.steps(
                spaceIDs: layout.ids,
                current: layout.current,
                target: target.spaceID
              ),
              let start = layout.ids.firstIndex(of: layout.current) else {
            return false
        }
        if steps.isEmpty { return true }
        var index = start
        for step in steps {
            let next = step == .towardHigherIndex ? index + 1 : index - 1
            guard layout.ids.indices.contains(next) else { return false }
            DesktopSpaceGesture.swipe(towardHigherIndex: step == .towardHigherIndex)
            guard SkyLightSpaces.waitUntil(displayID: target.displayID, spaceID: layout.ids[next]) else {
                return false
            }
            index = next
        }
        return layout.ids[index] == target.spaceID
    }

    func raiseWindow(pid: Int32, windowID: UInt32) -> Bool {
        AccessibilityWindowRaiser.raise(pid: pid, windowID: windowID)
    }
}

private enum SkyLightSpaces {
    private static let connectionID: (@convention(c) () -> Int32)? = load("CGSMainConnectionID")
    private static let copySpaces: (@convention(c) (Int32) -> Unmanaged<CFArray>?)? = load("CGSCopyManagedDisplaySpaces")
    private static let copyWindows: CopyWindows? = load("SLSCopyWindowsWithOptionsAndTags")
    private static let isOrderedIn: WindowIsOrderedIn? = load("SLSWindowIsOrderedIn")

    static func copyDisplayArray() -> [Any]? {
        guard let connectionID, let copySpaces else { return nil }
        guard let unmanaged = copySpaces(connectionID()) else { return nil }
        let array = unmanaged.takeRetainedValue()
        return array as? [Any] ?? (array as NSArray).map { $0 }
    }

    static func orderedSpaceIDs(displayID: String) -> (current: UInt64, ids: [UInt64])? {
        guard let raw = copyDisplayArray(),
              let displays = SkyLightSpaceDumpParser.parse(raw),
              let display = displays.first(where: { $0.identifier == displayID }) else { return nil }
        let ids = display.spaces.map(\.spaceID)
        guard !ids.isEmpty else { return nil }
        return (display.currentSpaceID, ids)
    }

    /// 符号不存在时返回 nil，调用方把窗口视为仍在显示。查询失败的单个窗口也不隐藏。
    static func orderedInFlags(for windowIDs: [UInt32]) -> [UInt32: Bool]? {
        guard let connectionID, let isOrderedIn else { return nil }
        let cid = connectionID()
        var result: [UInt32: Bool] = [:]
        for windowID in Set(windowIDs) {
            var shown: UInt8 = 1
            guard isOrderedIn(cid, windowID, &shown) == 0 else { continue }
            result[windowID] = shown != 0
        }
        return result
    }

    /// 符号不存在时返回 nil，调用方保留空间字典里的窗口编号。
    static func copyWindowIDs(in displays: [SkyLightDisplayDump]) -> [UInt64: [UInt32]]? {
        guard let connectionID, let copyWindows else { return nil }
        let cid = connectionID()
        var result: [UInt64: [UInt32]] = [:]
        for display in displays {
            for space in display.spaces {
                if let ids = windowIDs(cid: cid, spaceID: space.spaceID, copy: copyWindows) {
                    result[space.spaceID] = ids
                }
            }
        }
        return result
    }

    static func appNames(in displays: [SkyLightDisplayDump]) -> [Int32: String] {
        var names: [Int32: String] = [:]
        for display in displays {
            for space in display.spaces where space.pid > 0 && names[space.pid] == nil {
                names[space.pid] = NSRunningApplication(processIdentifier: space.pid)?.localizedName ?? ""
            }
        }
        return names
    }

    static func waitUntil(displayID: String, spaceID: UInt64) -> Bool {
        if currentSpaceID(displayID: displayID) == spaceID { return true }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if currentSpaceID(displayID: displayID) == spaceID { return true }
        }
        return currentSpaceID(displayID: displayID) == spaceID
    }

    private static func currentSpaceID(displayID: String) -> UInt64? {
        orderedSpaceIDs(displayID: displayID)?.current
    }

    private static func windowIDs(cid: Int32, spaceID: UInt64, copy: CopyWindows) -> [UInt32]? {
        let ids = [NSNumber(value: spaceID)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let raw = copy(cid, 0, ids, 0x7, &setTags, &clearTags)?.takeRetainedValue() else { return nil }
        return (raw as NSArray).compactMap { ($0 as? NSNumber)?.uint32Value }
    }

    private static func load<T>(_ name: String) -> T? {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else { continue }
            return unsafeBitCast(symbol, to: T.self)
        }
        return nil
    }
}

private typealias WindowIsOrderedIn = @convention(c) (
    Int32,
    UInt32,
    UnsafeMutablePointer<UInt8>
) -> Int32

private typealias CopyWindows = @convention(c) (
    Int32,
    UInt32,
    CFArray,
    UInt32,
    UnsafeMutablePointer<UInt64>,
    UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?

/// 系统真正换桌面用的滑动手势。正方向走向调度中心顺序里更靠后的一格。
private enum DesktopSpaceGesture {
    private static let eventType = CGEventField(rawValue: 55)!
    private static let hidType = CGEventField(rawValue: 110)!
    private static let motion = CGEventField(rawValue: 123)!
    private static let progress = CGEventField(rawValue: 124)!
    private static let velocityX = CGEventField(rawValue: 129)!
    private static let velocityY = CGEventField(rawValue: 130)!
    private static let phase = CGEventField(rawValue: 132)!

    static func swipe(towardHigherIndex: Bool) {
        let sign: Double = towardHigherIndex ? 1 : -1
        let phases: [(Int64, Double)] = [
            (1, sign * 0.000016),
            (2, sign),
            (4, sign)
        ]
        for (phaseValue, distance) in phases {
            guard let event = CGEvent(source: nil) else { return }
            event.setIntegerValueField(eventType, value: 30)
            event.setIntegerValueField(hidType, value: 23)
            event.setIntegerValueField(phase, value: phaseValue)
            event.setIntegerValueField(motion, value: 1)
            event.setDoubleValueField(progress, value: distance)
            event.setDoubleValueField(velocityX, value: sign * 400)
            event.setDoubleValueField(velocityY, value: sign * 400)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

private enum DisplayNameResolver {
    static func names(for identifiers: [String]) -> [String: String] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
            let text = CFUUIDCreateString(nil, uuid) as String
            if wanted.contains(text) {
                result[text] = screen.localizedName
            }
        }
        return result
    }
}

private struct ListedWindows {
    var frontToBack: [UInt32]
    var facts: [UInt32: DesktopWindowFacts]
}

private enum WindowListReader {
    static func read() -> ListedWindows {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return ListedWindows(frontToBack: [], facts: [:])
        }
        var frontToBack: [UInt32] = []
        var facts: [UInt32: DesktopWindowFacts] = [:]
        var appNames: [Int32: String] = [:]
        for item in info {
            guard let windowID = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                continue
            }
            frontToBack.append(windowID)
            if appNames[pid] == nil {
                appNames[pid] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            }
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            facts[windowID] = DesktopWindowFacts(
                pid: pid,
                ownerName: owner,
                listTitle: item[kCGWindowName as String] as? String ?? "",
                accessibilityTitle: nil,
                appName: appNames[pid] ?? owner,
                layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                minimized: false,
                alpha: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
        return ListedWindows(frontToBack: frontToBack, facts: facts)
    }
}

private enum AccessibilityWindowDetails {
    fileprivate static func windows(of element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXWindowsAttribute)
    }

    fileprivate static func number(of element: AXUIElement) -> UInt32? {
        windowNumber(element)
    }

    fileprivate static func isMinimized(_ element: AXUIElement) -> Bool {
        bool(element, kAXMinimizedAttribute) ?? false
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return []
        }
        if let list = value as? [AXUIElement] { return list }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap {
            guard let item = CFArrayGetValueAtIndex(array, $0) else { return nil }
            let object = Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue()
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    private static func windowNumber(_ element: AXUIElement) -> UInt32? {
        if let getter = axWindowID {
            var windowID: UInt32 = 0
            if getter(element, &windowID) == .success { return windowID }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.uint32Value
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static let axWindowID: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError)? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError).self
        )
    }()
}

private enum AccessibilityWindowRaiser {
    static func raise(pid: Int32, windowID: UInt32) -> Bool {
        guard AXIsProcessTrusted(), pid > 0 else { return false }
        let application = AXUIElementCreateApplication(pid)
        for window in AccessibilityWindowDetails.windows(of: application) {
            guard AccessibilityWindowDetails.number(of: window) == windowID else { continue }
            if AccessibilityWindowDetails.isMinimized(window) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            let front = AXUIElementSetAttributeValue(
                application,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            ) == .success
            if let application = NSRunningApplication(processIdentifier: pid) {
                if #available(macOS 14.0, *) {
                    application.activate(from: NSRunningApplication.current, options: [])
                } else {
                    application.activate(options: [.activateIgnoringOtherApps])
                }
            }
            return raised || front
        }
        return false
    }
}
