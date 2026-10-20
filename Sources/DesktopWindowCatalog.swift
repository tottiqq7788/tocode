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

/// 用 SkyLight 私有接口读取各显示器的空间，并用窗口列表与辅助功能补标题。
final class SystemDesktopWindowCatalog: DesktopWindowCataloging {
    func loadMenu() -> [DesktopMenuEntry]? {
        guard let raw = SkyLightSpaces.copyDisplayArray(),
              let displays = SkyLightSpaceDumpParser.parse(raw) else {
            return nil
        }
        let listed = WindowListReader.read()
        let accessibility = AccessibilityWindowDetails.read(pids: Set(listed.facts.values.map(\.pid)))
        var windows = listed.facts
        for (windowID, detail) in accessibility {
            if var facts = windows[windowID] {
                if !detail.title.isEmpty { facts.accessibilityTitle = detail.title }
                facts.minimized = detail.minimized
                windows[windowID] = facts
            } else {
                windows[windowID] = DesktopWindowFacts(
                    pid: detail.pid,
                    ownerName: detail.ownerName,
                    listTitle: "",
                    accessibilityTitle: detail.title,
                    appName: detail.appName,
                    layer: 0,
                    minimized: detail.minimized
                )
            }
        }
        let names = DisplayNameResolver.names(for: displays.map(\.identifier))
        let entries = DesktopWindowMenuBuilder.make(
            displays: displays,
            names: names,
            windows: windows,
            frontToBack: listed.frontToBack
        )
        return entries.isEmpty ? nil : entries
    }
}

final class SystemDesktopSpaceSwitcher: DesktopSpaceSwitching {
    func switchToSpace(_ target: DesktopSpaceTarget) -> Bool {
        SkyLightSpaces.setCurrentSpace(displayID: target.displayID, spaceID: target.spaceID)
    }

    func raiseWindow(pid: Int32, windowID: UInt32) -> Bool {
        AccessibilityWindowRaiser.raise(pid: pid, windowID: windowID)
    }
}

private enum SkyLightSpaces {
    private static let connectionID: (@convention(c) () -> Int32)? = load("CGSMainConnectionID")
    private static let copySpaces: (@convention(c) (Int32) -> Unmanaged<CFArray>?)? = load("CGSCopyManagedDisplaySpaces")
    private static let setSpace: (@convention(c) (Int32, CFString, UInt64) -> Void)? = load("CGSManagedDisplaySetCurrentSpace")

    static func copyDisplayArray() -> [Any]? {
        guard let connectionID, let copySpaces else { return nil }
        guard let unmanaged = copySpaces(connectionID()) else { return nil }
        let array = unmanaged.takeRetainedValue()
        return array as? [Any] ?? (array as NSArray).map { $0 }
    }

    static func setCurrentSpace(displayID: String, spaceID: UInt64) -> Bool {
        guard let connectionID, let setSpace, !displayID.isEmpty else { return false }
        setSpace(connectionID(), displayID as CFString, spaceID)
        return true
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
                minimized: false
            )
        }
        return ListedWindows(frontToBack: frontToBack, facts: facts)
    }
}

private struct AccessibilityWindowDetail {
    var pid: Int32
    var ownerName: String
    var appName: String
    var title: String
    var minimized: Bool
}

private enum AccessibilityWindowDetails {
    static func read(pids: Set<Int32>) -> [UInt32: AccessibilityWindowDetail] {
        guard AXIsProcessTrusted() else { return [:] }
        var result: [UInt32: AccessibilityWindowDetail] = [:]
        for pid in pids where pid > 0 {
            let application = NSRunningApplication(processIdentifier: pid)
            let appName = application?.localizedName ?? ""
            let ownerName = application?.bundleIdentifier ?? appName
            let element = AXUIElementCreateApplication(pid)
            for window in elements(element, kAXWindowsAttribute) {
                guard let windowID = windowNumber(window) else { continue }
                result[windowID] = AccessibilityWindowDetail(
                    pid: pid,
                    ownerName: ownerName,
                    appName: appName,
                    title: string(window, kAXTitleAttribute) ?? "",
                    minimized: bool(window, kAXMinimizedAttribute) ?? false
                )
            }
        }
        return result
    }

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
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self)
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

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
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
