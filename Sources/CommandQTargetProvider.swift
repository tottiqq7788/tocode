import ApplicationServices
import AppKit

enum AppSwitcherLookup: Equatable {
    case inactive
    case selected(FrontmostAppInfo)
    case unresolved
}

enum AXAttributeCopyResult {
    case value(CFTypeRef)
    case missing
    case timedOut
}

/// 把 Dock AX 读结果收成切换器结论；超时一律未知，避免回退前台误关 Finder。
enum DockSwitcherLookupDecision {
    static func fromFocused(_ result: AXAttributeCopyResult) -> AppSwitcherLookup? {
        switch result {
        case .timedOut:
            return .unresolved
        case .missing:
            return .inactive
        case .value:
            return nil
        }
    }

    static func fromSubrole(_ result: AXAttributeCopyResult, expected: String) -> AppSwitcherLookup? {
        switch result {
        case .timedOut:
            return .unresolved
        case .missing:
            return .inactive
        case .value(let raw):
            guard let subrole = raw as? String, subrole == expected else {
                return .inactive
            }
            return nil
        }
    }

    static func fromSelectedChildren(_ result: AXAttributeCopyResult) -> AppSwitcherLookup? {
        switch result {
        case .timedOut, .missing:
            return .unresolved
        case .value:
            return nil
        }
    }
}

protocol AppSwitcherInspecting {
    func lookup() -> AppSwitcherLookup
}

protocol CommandQTargetProviding {
    func commandQTarget() -> FrontmostAppInfo?
}

/// 把切换器选中项解析为唯一运行中应用；无法唯一匹配则视为未知。
enum AppSwitcherSelectionResolver {
    static func resolve(
        bundleURL: URL?,
        title: String?,
        running: [FrontmostAppInfo]
    ) -> AppSwitcherLookup {
        if let bundleURL {
            let identifier = Bundle(url: bundleURL)?.bundleIdentifier
            let matches = running.filter { info in
                if let identifier, info.bundleIdentifier == identifier {
                    return true
                }
                if let appURL = info.bundleURL {
                    return appURL.standardizedFileURL == bundleURL.standardizedFileURL
                }
                return false
            }
            if matches.count == 1 {
                return .selected(matches[0])
            }
            if identifier == "com.apple.finder" || bundleURL.lastPathComponent == "Finder.app" {
                if let finder = running.first(where: { $0.isFinder }) {
                    return .selected(finder)
                }
            }
            if matches.isEmpty {
                return .unresolved
            }
            return .unresolved
        }
        guard let title, !title.isEmpty else {
            return .unresolved
        }
        let matches = running.filter { $0.localizedName == title }
        if matches.count == 1 {
            return .selected(matches[0])
        }
        return .unresolved
    }
}

struct WorkspaceCommandQTargetProvider: CommandQTargetProviding {
    let frontmost: FrontmostApplicationProviding
    let switcher: AppSwitcherInspecting

    init(
        frontmost: FrontmostApplicationProviding = WorkspaceFrontmostApplication(),
        switcher: AppSwitcherInspecting = DockAppSwitcherInspector()
    ) {
        self.frontmost = frontmost
        self.switcher = switcher
    }

    func commandQTarget() -> FrontmostAppInfo? {
        switch switcher.lookup() {
        case .inactive:
            return frontmost.frontmost()
        case .selected(let app):
            return app
        case .unresolved:
            return nil
        }
    }
}

/// 读取 Dock 的 AXProcessSwitcherList；超时或结构不明则返回未知。
final class DockAppSwitcherInspector: AppSwitcherInspecting {
    static let timeout: TimeInterval = 0.05

    private var cachedDockPID: pid_t?

    func lookup() -> AppSwitcherLookup {
        guard let dockPID = dockPID() else {
            return .inactive
        }
        let app = AXUIElementCreateApplication(dockPID)
        let focusedResult = copyAttribute(app, kAXFocusedUIElementAttribute as CFString)
        if let decision = DockSwitcherLookupDecision.fromFocused(focusedResult) {
            return decision
        }
        guard case .value(let focused) = focusedResult else {
            return .unresolved
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let expectedSubrole = kAXProcessSwitcherListSubrole as String
        let subroleResult = copyAttribute(element, kAXSubroleAttribute as CFString)
        if let decision = DockSwitcherLookupDecision.fromSubrole(subroleResult, expected: expectedSubrole) {
            return decision
        }
        let selectedResult = copyAttribute(element, kAXSelectedChildrenAttribute as CFString)
        if let decision = DockSwitcherLookupDecision.fromSelectedChildren(selectedResult) {
            return decision
        }
        guard case .value(let rawSelected) = selectedResult else {
            return .unresolved
        }
        let selected: [AXUIElement]
        if let typed = rawSelected as? [AXUIElement] {
            selected = typed
        } else if let objects = rawSelected as? [AnyObject] {
            selected = objects.map { unsafeBitCast($0, to: AXUIElement.self) }
        } else {
            return .unresolved
        }
        guard let first = selected.first else {
            return .unresolved
        }
        var bundleURL: URL?
        if case .value(let urlValue) = copyAttribute(first, kAXURLAttribute as CFString) {
            if let url = urlValue as? URL {
                bundleURL = url
            } else if let text = urlValue as? String {
                bundleURL = URL(string: text)
            }
        }
        let title: String?
        if case .value(let titleValue) = copyAttribute(first, kAXTitleAttribute as CFString) {
            title = titleValue as? String
        } else {
            title = nil
        }
        let running = NSWorkspace.shared.runningApplications.map { app in
            FrontmostAppInfo(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName,
                bundleURL: app.bundleURL
            )
        }
        return AppSwitcherSelectionResolver.resolve(
            bundleURL: bundleURL,
            title: title,
            running: running
        )
    }

    private func dockPID() -> pid_t? {
        if let cachedDockPID,
           NSRunningApplication(processIdentifier: cachedDockPID)?.bundleIdentifier == "com.apple.dock" {
            return cachedDockPID
        }
        let pid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }?.processIdentifier
        cachedDockPID = pid
        return pid
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXAttributeCopyResult {
        final class Box: @unchecked Sendable {
            var result: AXAttributeCopyResult = .missing
        }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value {
                box.result = .value(value)
            } else {
                box.result = .missing
            }
            group.leave()
        }
        if group.wait(timeout: .now() + Self.timeout) == .timedOut {
            return .timedOut
        }
        return box.result
    }
}
