import Foundation
import AppKit
import CoreGraphics

var failures = 0

func expect(_ cond: Bool, _ msg: String) {
    if cond {
        print("PASS: \(msg)")
    } else {
        print("FAIL: \(msg)")
        failures += 1
    }
}

func testFileSystemService() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("tocode-test-\(UUID().uuidString)").path
    try! fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    try! fm.createDirectory(atPath: (tmp as NSString).appendingPathComponent("z-folder"), withIntermediateDirectories: false)
    try! fm.createDirectory(atPath: (tmp as NSString).appendingPathComponent("folder-a"), withIntermediateDirectories: false)
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent("b-file.txt"), contents: Data())
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent("a-file.txt"), contents: Data())
    fm.createFile(atPath: (tmp as NSString).appendingPathComponent(".hidden"), contents: Data())

    let fs = FileSystemService()
    let entries = fs.entries(in: tmp)

    expect(entries.count == 5, "条目数 == 5（含隐藏文件）")

    let dirs = entries.filter { $0.kind == .directory }
    expect(dirs.count == 2, "2 个文件夹")
    expect(dirs.map { $0.name } == ["folder-a", "z-folder"], "文件夹按名称升序")

    let files = entries.filter { $0.kind == .file }
    expect(files.count == 3, "3 个文件（含 .hidden）")

    let aIdx = files.firstIndex { $0.name == "a-file.txt" }
    let bIdx = files.firstIndex { $0.name == "b-file.txt" }
    expect(aIdx != nil && bIdx != nil, "a-file.txt / b-file.txt 都存在")
    if let a = aIdx, let b = bIdx { expect(a < b, "a-file.txt 排在 b-file.txt 前") }

    let hidden = entries.first { $0.name == ".hidden" }
    expect(hidden?.isHidden == true, ".hidden 的 isHidden 标记为 true")
    expect(hidden?.kind == .file, ".hidden 类型为文件")

    expect(fs.isExistingDirectory(tmp), "isExistingDirectory(目录) == true")
    expect(!fs.isExistingDirectory((tmp as NSString).appendingPathComponent("b-file.txt")), "isExistingDirectory(文件) == false")
    expect(!fs.isExistingDirectory((tmp as NSString).appendingPathComponent("nope")), "isExistingDirectory(不存在) == false")

    let empty = (tmp as NSString).appendingPathComponent("empty-dir")
    try! fm.createDirectory(atPath: empty, withIntermediateDirectories: false)
    expect(fs.entries(in: empty).isEmpty, "空目录返回空数组")

    let visibleOnly = fs.entries(in: tmp, includeHidden: false)
    expect(visibleOnly.contains { $0.name == ".hidden" } == false, "includeHidden=false 过滤点号文件")
    expect(visibleOnly.count == 5, "过滤点号后剩余可见项（含 empty-dir）")

    let flagged = (tmp as NSString).appendingPathComponent("flagged.txt")
    fm.createFile(atPath: flagged, contents: Data())
    var values = URLResourceValues()
    values.isHidden = true
    var flaggedURL = URL(fileURLWithPath: flagged)
    try! flaggedURL.setResourceValues(values)
    expect(fs.isHiddenEntry(name: "flagged.txt", path: flagged), "hidden 属性条目判定为隐藏")
    let hiddenOff = fs.entries(in: tmp, includeHidden: false)
    expect(hiddenOff.contains { $0.name == "flagged.txt" } == false, "includeHidden=false 过滤 hidden 属性文件")
    let hiddenOn = fs.entries(in: tmp, includeHidden: true)
    expect(hiddenOn.contains { $0.name == "flagged.txt" && $0.isHidden }, "includeHidden=true 保留 hidden 属性文件")
}

func testRootPathStore() {
    let suite = "tocode-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let fm = FileManager.default
    let store = RootPathStore(defaults: defaults)

    // 初始为 nil
    expect(store.load() == nil, "RootPathStore 初始为 nil")

    // 保存后读取一致
    store.save("/tmp/some/path")
    expect(store.load() == "/tmp/some/path", "RootPathStore 保存后读取一致")

    // 已保存且存在 → 返回保存值
    let savedDir = "/tmp/tocode-saved-\(UUID().uuidString)"
    try! fm.createDirectory(atPath: savedDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: savedDir) }
    store.save(savedDir)
    expect(store.resolveRoot(isDirectory: { fm.fileExists(atPath: $0, isDirectory: nil) }) == savedDir,
           "resolveRoot 已保存且存在时返回保存值")

    // 已保存但不存在 → 回退默认目录
    store.save("/tmp/tocode-nonexistent-\(UUID().uuidString)")
    expect(store.resolveRoot(isDirectory: { $0 == RootPathStore.defaultRoot }) == RootPathStore.defaultRoot,
           "resolveRoot 保存值不存在时回退默认目录")

    // 未保存 → 回退默认目录
    defaults.removePersistentDomain(forName: suite)
    expect(store.resolveRoot(isDirectory: { $0 == RootPathStore.defaultRoot }) == RootPathStore.defaultRoot,
           "resolveRoot 未保存时回退默认目录")

    // reset → 默认目录
    store.save("/tmp/other/path")
    store.reset()
    expect(store.load() == RootPathStore.defaultRoot, "reset 后根目录为默认目录")
    expect(RootPathStore.defaultRoot == "/Users/admin/Documents", "默认目录为 /Users/admin/Documents")
}

func testClipboardService() {
    let name = NSPasteboard.Name("tocode-test-\(UUID().uuidString)")
    let pb = NSPasteboard(name: name)
    let clip = ClipboardService(pasteboard: pb)
    clip.copy("/Users/test/hello.txt")
    expect(clip.read() == "/Users/test/hello.txt", "ClipboardService 写入后读取一致")

    clip.copyPath("/Users/test/folder")
    expect(clip.read() == "「/Users/test/folder」", "ClipboardService.copyPath 用「」包裹路径")
}

final class MockVisibilityStore: FinderVisibilityStore {
    var value: Bool?
    var writeShouldFail = false
    var writes: [Bool] = []

    func readShowAllFiles() -> Bool? { value }

    func writeShowAllFiles(_ newValue: Bool) -> Bool {
        writes.append(newValue)
        if writeShouldFail { return false }
        value = newValue
        return true
    }
}

final class MockRelauncher: FinderRelauncher {
    var shouldFail = false
    var calls = 0

    func relaunch() -> Bool {
        calls += 1
        return !shouldFail
    }
}

func testFinderVisibilityService() {
    let store = MockVisibilityStore()
    let relauncher = MockRelauncher()
    let service = FinderVisibilityService(store: store, relauncher: relauncher)

    expect(service.currentShowAllFiles() == false, "缺失偏好视为隐藏")

    store.value = false
    expect(service.setShowAllFiles(true), "写入并重启成功")
    expect(store.value == true, "偏好已更新为显示")
    expect(relauncher.calls == 1, "成功路径重启一次")

    store.writeShouldFail = true
    let beforeFail = store.value
    let writeCalls = store.writes.count
    expect(!service.setShowAllFiles(false), "写入失败返回 false")
    expect(store.value == beforeFail, "写入失败不改权威值")
    expect(relauncher.calls == 1, "写入失败不重启")
    expect(store.writes.count == writeCalls + 1, "失败写入仍被尝试")

    store.writeShouldFail = false
    store.value = true
    relauncher.shouldFail = true
    expect(!service.setShowAllFiles(false), "重启失败返回 false")
    expect(store.value == true, "重启失败后恢复旧值")
    expect(store.writes.suffix(2).map { $0 } == [false, true], "重启失败先写新值再回滚")
}

struct MockScript: AppleScriptRunning {
    var result: Result<String, FinderSelectionError>

    func execute(_ source: String) -> Result<String, FinderSelectionError> {
        _ = source
        return result
    }
}

func testFinderSelectionService() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("tocode-sel-\(UUID().uuidString)").path
    try! fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    let file = (tmp as NSString).appendingPathComponent("note.txt")
    fm.createFile(atPath: file, contents: Data())
    let fs = FileSystemService()

    func service(result: Result<String, FinderSelectionError>) -> FinderSelectionService {
        FinderSelectionService(script: MockScript(result: result), fs: fs)
    }

    switch service(result: .success("")).resolveInitializationDirectory() {
    case .failure(.notExactlyOne):
        expect(true, "空选择视为非恰好一项")
    default:
        expect(false, "空选择视为非恰好一项")
    }

    switch service(result: .failure(.notExactlyOne)).resolveInitializationDirectory() {
    case .failure(.notExactlyOne):
        expect(true, "多选/非恰好一项失败")
    default:
        expect(false, "多选/非恰好一项失败")
    }

    switch service(result: .success(tmp)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "单选文件夹使用自身")
    default:
        expect(false, "单选文件夹使用自身")
    }

    switch service(result: .success(file)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "单选文件使用父级文件夹")
    default:
        expect(false, "单选文件使用父级文件夹")
    }

    let fileURL = URL(fileURLWithPath: file).absoluteString
    switch service(result: .success(fileURL)).resolveInitializationDirectory() {
    case .success(let dir):
        expect(dir == (tmp as NSString).standardizingPath, "Finder 文件 URL 解码后使用父级文件夹")
    default:
        expect(false, "Finder 文件 URL 解码后使用父级文件夹")
    }

    switch service(result: .success("file://%")).resolveInitializationDirectory() {
    case .failure(.invalidPath):
        expect(true, "无效 Finder 文件 URL 拒绝设根")
    default:
        expect(false, "无效 Finder 文件 URL 拒绝设根")
    }

    switch service(result: .success(tmp + "/missing-item")).resolveInitializationDirectory() {
    case .failure(.invalidPath):
        expect(true, "失效路径拒绝设根")
    default:
        expect(false, "失效路径拒绝设根")
    }

    switch service(result: .failure(.notPermitted)).resolveInitializationDirectory() {
    case .failure(.notPermitted):
        expect(true, "自动化权限拒绝")
    default:
        expect(false, "自动化权限拒绝")
    }

    switch service(result: .failure(.scriptFailed)).resolveInitializationDirectory() {
    case .failure(.scriptFailed):
        expect(true, "脚本错误拒绝设根")
    default:
        expect(false, "脚本错误拒绝设根")
    }
}

func snapshot(
    _ keyCode: Int64,
    down: Bool,
    repeat isRepeat: Bool = false,
    synthesized: Bool = false,
    shift: Bool = false,
    option: Bool = false,
    control: Bool = false,
    command: Bool = true
) -> KeyboardEventSnapshot {
    var flags: CGEventFlags = command ? .maskCommand : []
    if shift { flags.insert(.maskShift) }
    if option { flags.insert(.maskAlternate) }
    if control { flags.insert(.maskControl) }
    return ShortcutKeyClassifier.snapshot(
        keyCode: keyCode,
        flags: flags,
        isKeyDown: down,
        isAutoRepeat: isRepeat,
        userData: synthesized ? GlobalShortcutEngine.synthesizerMarker : 0
    )
}

let finderApp = FrontmostAppInfo(pid: 10, bundleIdentifier: "com.apple.finder", localizedName: "Finder")
let safariApp = FrontmostAppInfo(pid: 20, bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func testShortcutSettingsStoreDefaults() {
    let suite = "tocode-shortcut-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = ShortcutSettingsStore(defaults: defaults)
    expect(!store.finderMoveHotkeysEnabled, "finderMove 默认关闭")
    expect(!store.doubleCommandQEnabled, "doubleCommandQ 默认关闭")

    store.finderMoveHotkeysEnabled = true
    store.doubleCommandQEnabled = true
    expect(store.finderMoveHotkeysEnabled, "finderMove 可持久化为开启")
    expect(store.doubleCommandQEnabled, "doubleCommandQ 可持久化为开启")
    expect(!store.finderCommandQEnabled, "finderCommandQ 默认关闭")

    store.finderCommandQEnabled = true
    expect(store.finderCommandQEnabled, "finderCommandQ 可持久化为开启")

    store.finderMoveHotkeysEnabled = false
    expect(!store.finderMoveHotkeysEnabled, "finderMove 可写回关闭")
}

func testShortcutEventClassification() {
    let cmdX = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyX,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: false,
        userData: 0
    )
    expect(cmdX.key == .commandX && cmdX.isKeyDown, "⌘X keyDown 分类")

    let cmdVUp = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyV,
        flags: .maskCommand,
        isKeyDown: false,
        isAutoRepeat: false,
        userData: 0
    )
    expect(cmdVUp.key == .commandV && !cmdVUp.isKeyDown, "⌘V keyUp 分类")

    let cmdQ = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyQ,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: true,
        userData: 0
    )
    expect(cmdQ.key == .commandQ && cmdQ.isAutoRepeat, "⌘Q 自动重复分类")

    let plainX = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyX,
        flags: [],
        isKeyDown: true,
        isAutoRepeat: false,
        userData: 0
    )
    expect(plainX.key == .other, "无 Command 的 X 不分类为快捷键")

    let synth = ShortcutKeyClassifier.snapshot(
        keyCode: ShortcutKeyClassifier.keyC,
        flags: .maskCommand,
        isKeyDown: true,
        isAutoRepeat: false,
        userData: GlobalShortcutEngine.synthesizerMarker
    )
    expect(synth.isSynthesized && synth.key == .other, "合成 ⌘C 带标记且不进入 X/V/Q")

    let rewritten = ShortcutEventApplicator.flags(for: .rewriteOptionCommandV, current: .maskCommand)
    expect(rewritten?.contains(.maskAlternate) == true && rewritten?.contains(.maskCommand) == true, "⌘V 改写附加 Option")
    expect(ShortcutEventApplicator.flags(for: .suppress, current: .maskCommand) == nil, "suppress 不返回 flags")
}

func testFinderMoveStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setFinderMoveEnabled(true)

    let xDown = snapshot(ShortcutKeyClassifier.keyX, down: true)
    let xUp = snapshot(ShortcutKeyClassifier.keyX, down: false)
    let vDown = snapshot(ShortcutKeyClassifier.keyV, down: true)
    let vUp = snapshot(ShortcutKeyClassifier.keyV, down: false)

    expect(
        engine.process(xDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1) == .pass,
        "非 Finder 的 ⌘X 透传"
    )
    expect(!engine.isCutPrepared, "非 Finder 不进入剪切预备")

    let probe = engine.process(xDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(probe.action == .suppress && probe.effect == .probeFinderCut, "Finder ⌘X keyDown 吞掉并探测")
    expect(!engine.isCutPrepared, "探测开始时清掉旧预备")
    expect(engine.process(xUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "Finder ⌘X keyUp 吞掉")

    let repeatX = snapshot(ShortcutKeyClassifier.keyX, down: true, repeat: true)
    expect(engine.process(repeatX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "⌘X 自动重复不探测")

    let shiftX = snapshot(ShortcutKeyClassifier.keyX, down: true, shift: true)
    expect(engine.process(shiftX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "⌘⇧X 透传")

    let synthX = snapshot(ShortcutKeyClassifier.keyX, down: true, synthesized: true)
    expect(engine.process(synthX, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "合成 ⌘X 防递归透传")

    engine.armCut(changeCount: 4)
    expect(engine.process(vDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 4) == .pass, "非 Finder 的 ⌘V 不改写")
    expect(engine.isCutPrepared, "离开 Finder 不清除仍有效的预备")

    let rewrite = engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 4)
    expect(rewrite.action == .rewriteOptionCommandV, "有效预备下 ⌘V 改写为 ⌥⌘V")
    expect(!engine.isCutPrepared, "完成一次移动后清除预备")
    expect(
        engine.process(vUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 5).action == .rewriteOptionCommandV,
        "对应 keyUp 一并改写"
    )
    expect(engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 5) == .pass, "无预备时普通粘贴透传")

    engine.armCut(changeCount: 7)
    engine.invalidateCutIfNeeded(currentChangeCount: 8)
    expect(!engine.isCutPrepared, "剪贴板变化取消预备")
    expect(engine.process(vDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 8) == .pass, "剪贴板已变则普通粘贴")

    engine.setFinderMoveEnabled(false)
    engine.armCut(changeCount: 9)
    engine.setFinderMoveEnabled(false)
    expect(!engine.isCutPrepared, "关闭开关清除预备")
    expect(engine.process(xDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 9) == .pass, "开关关闭时 Finder ⌘X 透传")
}

func testDoubleCommandQStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setDoubleCommandQEnabled(true)
    let qDown = snapshot(ShortcutKeyClassifier.keyQ, down: true)
    let qUp = snapshot(ShortcutKeyClassifier.keyQ, down: false)

    expect(engine.process(qDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "第一次 ⌘Q keyDown 吞掉")
    expect(engine.process(qUp, frontmost: safariApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "第一次 ⌘Q keyUp 吞掉")
    expect(engine.quitArm?.pid == safariApp.pid, "记录前台 PID")

    let repeatQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, repeat: true)
    expect(engine.process(repeatQ, frontmost: safariApp, now: t0.addingTimeInterval(0.2), pasteboardChangeCount: 1).action == .suppress, "自动重复不算第二次")
    expect(engine.quitArm != nil, "自动重复不解除武装")

    let second = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(1.0), pasteboardChangeCount: 1)
    expect(second == .pass, "2 秒内同 PID 第二次放行")
    expect(engine.quitArm == nil, "确认退出后解除武装")
    expect(engine.process(qUp, frontmost: safariApp, now: t0.addingTimeInterval(1.0), pasteboardChangeCount: 1) == .pass, "第二次 keyUp 放行")

    let firstAgain = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(1.1), pasteboardChangeCount: 1)
    expect(firstAgain.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: false), "新周期第一次发出提示")
    let switched = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(1.5), pasteboardChangeCount: 1)
    expect(switched.action == .suppress && switched.effect == .notifyQuitArmed(appName: "Safari", finderDismiss: false), "切换应用重新计数")

    _ = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(10), pasteboardChangeCount: 1)
    let timedOut = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(12.1), pasteboardChangeCount: 1)
    expect(timedOut.action == .suppress, "超时后本次当作新的第一次")

    let shiftQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, shift: true)
    expect(engine.process(shiftQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "⌘⇧Q 不拦截")
    let optionQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, option: true)
    expect(engine.process(optionQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "⌥⌘Q 不拦截")
    let synthQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, synthesized: true)
    expect(engine.process(synthQ, frontmost: safariApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1) == .pass, "合成 ⌘Q 透传")
    expect(engine.process(qDown, frontmost: nil, now: t0.addingTimeInterval(30), pasteboardChangeCount: 1) == .pass, "无前台应用时 ⌘Q fail-open")

    engine.setDoubleCommandQEnabled(false)
    expect(engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(40), pasteboardChangeCount: 1) == .pass, "开关关闭时 ⌘Q 零处理")
}

final class MockShortcutPermissions: ShortcutPermissionChecking {
    var accessibility = false
    var grantOnRequest = false
    var requests = 0

    func hasAccessibilityAccess() -> Bool { accessibility }
    func requestAccessibilityAccess() -> Bool {
        requests += 1
        if grantOnRequest { accessibility = true }
        return accessibility
    }
}

final class MockShortcutTap: ShortcutTapControlling {
    var isInstalled = false
    var isEnabled = false
    var installShouldFail = false
    var reenableShouldFail = false
    var installCount = 0
    var removeCount = 0
    var handler: ((CGEventType, CGEvent) -> ShortcutAction)?

    func install(handler: @escaping (CGEventType, CGEvent) -> ShortcutAction) -> Bool {
        if installShouldFail { return false }
        self.handler = handler
        isInstalled = true
        isEnabled = true
        installCount += 1
        return true
    }

    func remove() {
        isInstalled = false
        isEnabled = false
        handler = nil
        removeCount += 1
    }

    func reenable() -> Bool {
        if reenableShouldFail {
            isEnabled = false
            return false
        }
        isEnabled = true
        return isInstalled
    }
}

final class MockFrontmost: FrontmostApplicationProviding {
    var app: FrontmostAppInfo?
    func frontmost() -> FrontmostAppInfo? { app }
}

final class MockFilePasteboard: FilePasteboardReading {
    var changeCount = 1
    var hasFiles = false
    func containsFileURLs() -> Bool { hasFiles }
}

final class MockSynthesizer: KeyboardEventSynthesizing {
    var posted: [String] = []
    func postCommandX() { posted.append("x") }
    func postCommandC() { posted.append("c") }
}

final class MockEditingContext: FinderEditingContextChecking {
    var editing = false
    func isEditingText() -> Bool { editing }
}

final class MockClock: ShortcutClock {
    var current = t0
    func now() -> Date { current }
}

final class ManualScheduler: ShortcutScheduling {
    var pending: [() -> Void] = []
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func asyncAfter(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        _ = seconds
        pending.append(work)
    }
    func runNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }
    func runAll() {
        while !pending.isEmpty { runNext() }
    }
}

final class MockAlerts: ShortcutAlerting {
    var titles: [String] = []
    func notify(title: String, body: String) {
        _ = body
        titles.append(title)
    }
}

final class MockCommandQTarget: CommandQTargetProviding {
    let frontmost: MockFrontmost
    var override: FrontmostAppInfo?
    var unknown = false

    init(frontmost: MockFrontmost) {
        self.frontmost = frontmost
    }

    func commandQTarget() -> FrontmostAppInfo? {
        if unknown { return nil }
        return override ?? frontmost.app
    }
}

final class MockFinderDismiss: FinderWindowDismissing {
    var calls = 0
    var result: Result<Void, FinderDismissError> = .success(())

    func dismissWindowsAndHide() -> Result<Void, FinderDismissError> {
        calls += 1
        return result
    }
}

final class MockFinderHider: FinderHiding {
    var calls = 0
    var succeed = true

    func hideFinder() -> Bool {
        calls += 1
        return succeed
    }
}

func makeShortcutHarness(
    accessibility: Bool = true,
    tapShouldFail: Bool = false
) -> (
    GlobalShortcutService,
    ShortcutSettingsStore,
    MockShortcutPermissions,
    MockShortcutTap,
    MockFrontmost,
    MockFilePasteboard,
    MockSynthesizer,
    MockEditingContext,
    MockClock,
    ManualScheduler,
    MockAlerts,
    MockCommandQTarget,
    MockFinderDismiss
) {
    let suite = "tocode-shortcut-svc-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = ShortcutSettingsStore(defaults: defaults)
    let permissions = MockShortcutPermissions()
    permissions.accessibility = accessibility
    let tap = MockShortcutTap()
    tap.installShouldFail = tapShouldFail
    let frontmost = MockFrontmost()
    let pasteboard = MockFilePasteboard()
    let synthesizer = MockSynthesizer()
    let editing = MockEditingContext()
    let clock = MockClock()
    let scheduler = ManualScheduler()
    let alerts = MockAlerts()
    let qTarget = MockCommandQTarget(frontmost: frontmost)
    let dismiss = MockFinderDismiss()
    let service = GlobalShortcutService(
        settings: settings,
        permissions: permissions,
        tap: tap,
        frontmostApps: frontmost,
        commandQTargets: qTarget,
        pasteboard: pasteboard,
        synthesizer: synthesizer,
        editingContext: editing,
        dismisser: dismiss,
        clock: clock,
        scheduler: scheduler,
        alerts: alerts
    )
    return (service, settings, permissions, tap, frontmost, pasteboard, synthesizer, editing, clock, scheduler, alerts, qTarget, dismiss)
}

func testShortcutServiceLifecycleAndFaults() {
    do {
        let (service, settings, _, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(accessibility: false)
        service.applySavedSettings()
        expect(!settings.finderMoveHotkeysEnabled && !settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "启动时默认开关关闭")
        expect(!tap.isInstalled, "默认不安装钩子")
        expect(!service.isFinderMoveEffective && !service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "默认无效")
        expect(alerts.titles.isEmpty, "默认关闭不提示")
    }

    do {
        let (service, settings, permissions, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(accessibility: false)
        expect(!service.setFinderMoveEnabled(true), "无辅助功能授权时开启失败")
        expect(!settings.finderMoveHotkeysEnabled, "失败后开关保持关闭")
        expect(!service.isFinderMoveEffective, "失败后不显示开启")
        expect(!tap.isInstalled, "无权限不安装钩子")
        expect(permissions.requests == 1, "只请求一次辅助功能授权")
        expect(alerts.titles.contains("无法开启快捷键"), "无权限给出提示")
    }

    do {
        let (service, settings, permissions, tap, _, _, _, _, _, _, _, _, _) = makeShortcutHarness(accessibility: false)
        permissions.grantOnRequest = true
        expect(service.setDoubleCommandQEnabled(true), "辅助功能请求即时获准后可开启")
        expect(settings.doubleCommandQEnabled && service.isDoubleCommandQEffective, "获准并安装钩子后才显示开启")
        expect(tap.isInstalled, "辅助功能获准后安装钩子")
        expect(permissions.requests == 1, "不会请求额外 Input Monitoring 或 PostEvent")
    }

    do {
        let (service, settings, _, tap, _, _, _, _, _, _, alerts, _, _) = makeShortcutHarness(tapShouldFail: true)
        expect(!service.setFinderMoveEnabled(true), "钩子创建失败则开启失败")
        expect(!settings.finderMoveHotkeysEnabled, "钩子失败后开关关闭")
        expect(!tap.isInstalled, "创建失败不保留钩子")
        expect(alerts.titles.contains("无法开启快捷键"), "钩子失败给出提示")
    }

    do {
        let (service, settings, _, tap, _, _, _, _, _, _, _, _, _) = makeShortcutHarness()
        expect(service.setFinderMoveEnabled(true), "权限与钩子可用时开启移动")
        expect(settings.finderMoveHotkeysEnabled && service.isFinderMoveEffective, "生效后才算开启")
        expect(tap.installCount == 1, "首次开启安装一次钩子")
        expect(service.setDoubleCommandQEnabled(true), "第二项复用同一钩子")
        expect(tap.installCount == 1, "共享钩子不重复安装")
        expect(service.isDoubleCommandQEffective, "第二项也生效")
        expect(service.setFinderCommandQEnabled(true), "第三项复用同一钩子")
        expect(tap.installCount == 1, "第三项不重复安装")
        expect(service.isFinderCommandQEffective, "第三项也生效")

        expect(service.setFinderMoveEnabled(false), "关闭其中一项")
        expect(tap.isInstalled, "仍有一项开启时保留钩子")
        expect(!service.isFinderMoveEffective && service.isDoubleCommandQEffective, "只关闭被关的一项")

        expect(service.setDoubleCommandQEnabled(false), "关闭第二项后仍保留钩子")
        expect(tap.isInstalled, "第三项仍开启时保留钩子")
        expect(service.setFinderCommandQEnabled(false), "关闭最后一项")
        expect(!tap.isInstalled, "全部关闭后移除钩子")
        expect(tap.removeCount >= 1, "全部关闭会拆除钩子")
    }

    do {
        let suite = "tocode-shortcut-apply-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = ShortcutSettingsStore(defaults: defaults)
        settings.finderMoveHotkeysEnabled = true
        settings.doubleCommandQEnabled = true
        settings.finderCommandQEnabled = true
        let permissions = MockShortcutPermissions()
        let tap = MockShortcutTap()
        let alerts = MockAlerts()
        let service = GlobalShortcutService(
            settings: settings,
            permissions: permissions,
            tap: tap,
            frontmostApps: MockFrontmost(),
            pasteboard: MockFilePasteboard(),
            synthesizer: MockSynthesizer(),
            editingContext: MockEditingContext(),
            clock: MockClock(),
            scheduler: ManualScheduler(),
            alerts: alerts
        )
        service.applySavedSettings()
        expect(!settings.finderMoveHotkeysEnabled && !settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "启动恢复失败则写回关闭")
        expect(!service.isFinderMoveEffective && !service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "启动恢复失败不生效")
    }

    do {
        let (service, settings, _, tap, frontmost, _, _, _, _, scheduler, alerts, _, _) = makeShortcutHarness()
        expect(service.setDoubleCommandQEnabled(true), "开启双击以便注入钩子停用")
        tap.isEnabled = false
        tap.reenableShouldFail = true
        _ = tap.handler?(.tapDisabledByTimeout, CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
        scheduler.runAll()
        expect(!settings.doubleCommandQEnabled && !settings.finderCommandQEnabled, "无法恢复时关闭开关")
        expect(!service.isDoubleCommandQEffective && !service.isFinderCommandQEffective, "无法恢复后不显示开启")
        expect(!tap.isInstalled, "无法恢复后拆除钩子")
        expect(alerts.titles.contains("快捷键保护已关闭"), "无法恢复时提示并放行")
        _ = frontmost
    }
}

func testFinderCutProbeAndQuitEffects() {
    let (service, _, _, _, frontmost, pasteboard, synthesizer, editing, clock, scheduler, alerts, _, _) = makeShortcutHarness()
    expect(service.setFinderMoveEnabled(true), "测试探测前开启移动")
    expect(service.setDoubleCommandQEnabled(true), "测试探测前开启双击")
    frontmost.app = finderApp

    editing.editing = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runAll()
    expect(synthesizer.posted == ["x"], "文本编辑回放 ⌘X")
    expect(!service.isCutPrepared, "文本编辑不进入剪切预备")

    synthesizer.posted.removeAll()
    editing.editing = false
    pasteboard.changeCount = 3
    pasteboard.hasFiles = false
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    expect(synthesizer.posted == ["c"], "文件上下文补发 ⌘C")
    scheduler.runAll()
    expect(!service.isCutPrepared, "无文件 URL 不沿用旧剪贴板")

    pasteboard.changeCount = 5
    pasteboard.hasFiles = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    pasteboard.changeCount = 6
    scheduler.runAll()
    expect(service.isCutPrepared, "changeCount 变化且含文件 URL 才预备")

    frontmost.app = safariApp
    let foreign = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(foreign == .pass, "切到其他应用后 ⌘V 透传")
    expect(service.isCutPrepared, "其他应用不消耗预备")

    frontmost.app = finderApp
    pasteboard.changeCount = 9
    let stale = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(stale == .pass, "剪贴板被改写后普通粘贴")
    expect(!service.isCutPrepared, "剪贴板变化取消预备")

    pasteboard.changeCount = 10
    pasteboard.hasFiles = true
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyX, down: true))
    scheduler.runNext()
    pasteboard.changeCount = 11
    scheduler.runAll()
    let moved = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyV, down: true))
    expect(moved.action == .rewriteOptionCommandV, "有效预备改写为移动")

    frontmost.app = safariApp
    clock.current = t0
    let firstQ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(firstQ.action == .suppress, "服务层第一次 ⌘Q 吞掉")
    scheduler.runAll()
    expect(alerts.titles.contains("再次按 ⌘Q 退出 Safari"), "第一次提示退出当前应用")
    clock.current = t0.addingTimeInterval(1)
    let secondQ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(secondQ == .pass, "同 PID 时间窗内第二次放行")
}

func testShortcutMenuAppearance() {
    let item = NSMenuItem()

    ShortcutMenuAppearance.apply(to: item, enabled: false)
    expect(item.state == .off, "快捷键关闭时菜单 state 为 off")
    expect(ShortcutMenuAppearance.symbolName(enabled: false) == "circle", "快捷键关闭时使用 circle")
    expect(item.image != nil, "快捷键关闭图标可创建")

    ShortcutMenuAppearance.apply(to: item, enabled: true)
    expect(item.state == .off, "快捷键生效后不显示额外系统勾选")
    expect(
        ShortcutMenuAppearance.symbolName(enabled: true) == "checkmark.circle.fill",
        "快捷键生效后立即使用勾选图标"
    )
    expect(item.image != nil, "快捷键开启图标可创建")
}

func testFinderCommandQStateMachine() {
    var engine = GlobalShortcutEngine()
    engine.setFinderCommandQEnabled(true)
    let qDown = snapshot(ShortcutKeyClassifier.keyQ, down: true)
    let qUp = snapshot(ShortcutKeyClassifier.keyQ, down: false)

    expect(engine.process(qDown, frontmost: safariApp, now: t0, pasteboardChangeCount: 1) == .pass, "仅关窗隐藏时非 Finder 透传")
    let dismiss = engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(dismiss.action == .suppress && dismiss.effect == .dismissFinderWindows, "仅关窗隐藏时 Finder 单击关窗隐藏")
    expect(engine.process(qUp, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "关窗隐藏后吞掉配对 keyUp")

    let shiftQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, shift: true)
    expect(engine.process(shiftQ, frontmost: finderApp, now: t0, pasteboardChangeCount: 1) == .pass, "⌘⇧Q 不关窗")
    let repeatQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, repeat: true)
    expect(engine.process(repeatQ, frontmost: finderApp, now: t0, pasteboardChangeCount: 1).action == .suppress, "自动重复不算另一次关窗")
    expect(
        engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1, commandQTargetUnknown: true) == .pass,
        "目标不明时放行"
    )

    engine.setDoubleCommandQEnabled(true)
    let first = engine.process(qDown, frontmost: finderApp, now: t0, pasteboardChangeCount: 1)
    expect(
        first.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true),
        "双开时第一次只提示关窗隐藏"
    )
    let second = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(1), pasteboardChangeCount: 1)
    expect(second.action == .suppress && second.effect == .dismissFinderWindows, "双开时第二次关窗隐藏且不放行原生 ⌘Q")

    _ = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(10), pasteboardChangeCount: 1)
    let switched = engine.process(qDown, frontmost: safariApp, now: t0.addingTimeInterval(11), pasteboardChangeCount: 1)
    expect(
        switched.action == .suppress && switched.effect == .notifyQuitArmed(appName: "Safari", finderDismiss: false),
        "切换 PID 后重新第一次"
    )
    _ = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(20), pasteboardChangeCount: 1)
    let timedOut = engine.process(qDown, frontmost: finderApp, now: t0.addingTimeInterval(22.1), pasteboardChangeCount: 1)
    expect(timedOut.action == .suppress && timedOut.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true), "超时后重新第一次")

    let optionQ = snapshot(ShortcutKeyClassifier.keyQ, down: true, option: true)
    expect(engine.process(optionQ, frontmost: finderApp, now: t0.addingTimeInterval(30), pasteboardChangeCount: 1) == .pass, "⌥⌘Q 不关窗")
}

func testCommandQTargetResolver() {
    let finder = FrontmostAppInfo(
        pid: 10,
        bundleIdentifier: "com.apple.finder",
        localizedName: "Finder",
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    )
    let safari = FrontmostAppInfo(
        pid: 20,
        bundleIdentifier: "com.apple.Safari",
        localizedName: "Safari",
        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )
    let running = [finder, safari]

    switch AppSwitcherSelectionResolver.resolve(
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        title: "Finder",
        running: running
    ) {
    case .selected(let app):
        expect(app.isFinder, "URL 优先解析为 Finder")
    default:
        expect(false, "URL 优先解析为 Finder")
    }

    switch AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: "Safari", running: running) {
    case .selected(let app):
        expect(app.bundleIdentifier == "com.apple.Safari", "唯一标题匹配 Safari")
    default:
        expect(false, "唯一标题匹配 Safari")
    }

    let twins = [
        FrontmostAppInfo(pid: 1, bundleIdentifier: "a", localizedName: "Notes"),
        FrontmostAppInfo(pid: 2, bundleIdentifier: "b", localizedName: "Notes")
    ]
    if case .unresolved = AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: "Notes", running: twins) {
        expect(true, "标题歧义视为未知")
    } else {
        expect(false, "标题歧义视为未知")
    }

    if case .unresolved = AppSwitcherSelectionResolver.resolve(bundleURL: nil, title: nil, running: running) {
        expect(true, "无 URL 无标题视为未知")
    } else {
        expect(false, "无 URL 无标题视为未知")
    }

    if case .unresolved = DockSwitcherLookupDecision.fromFocused(.timedOut) {
        expect(true, "AX 焦点超时视为未知")
    } else {
        expect(false, "AX 焦点超时视为未知")
    }
    if case .inactive = DockSwitcherLookupDecision.fromFocused(.missing) {
        expect(true, "无焦点视为切换器未打开")
    } else {
        expect(false, "无焦点视为切换器未打开")
    }
    if case .unresolved = DockSwitcherLookupDecision.fromSelectedChildren(.timedOut) {
        expect(true, "选中项超时视为未知")
    } else {
        expect(false, "选中项超时视为未知")
    }

    final class MockSwitcher: AppSwitcherInspecting {
        var lookupResult: AppSwitcherLookup = .inactive
        func lookup() -> AppSwitcherLookup { lookupResult }
    }
    let switcher = MockSwitcher()
    let frontmost = MockFrontmost()
    frontmost.app = safari
    let provider = WorkspaceCommandQTargetProvider(frontmost: frontmost, switcher: switcher)
    expect(provider.commandQTarget()?.bundleIdentifier == "com.apple.Safari", "切换器未打开时用前台")
    switcher.lookupResult = .selected(finder)
    expect(provider.commandQTarget()?.isFinder == true, "切换器选中 Finder 覆盖前台")
    switcher.lookupResult = .unresolved
    expect(provider.commandQTarget() == nil, "切换器歧义或超时不回退前台")
}

func testFinderDismissServiceFaults() {
    let hider = MockFinderHider()
    let permitted = FinderDismissService(script: MockScript(result: .success("")), hider: hider)
    if case .success = permitted.dismissWindowsAndHide() {
        expect(true, "关窗成功后隐藏")
    } else {
        expect(false, "关窗成功后隐藏")
    }
    expect(hider.calls == 1, "零窗口或关窗成功后仍隐藏")

    hider.calls = 0
    let denied = FinderDismissService(script: MockScript(result: .failure(.notPermitted)), hider: hider)
    if case .failure(.notPermitted) = denied.dismissWindowsAndHide() {
        expect(true, "Automation 拒绝")
    } else {
        expect(false, "Automation 拒绝")
    }
    expect(hider.calls == 0, "Automation 失败不隐藏")

    let failed = FinderDismissService(script: MockScript(result: .failure(.scriptFailed)), hider: hider)
    if case .failure(.scriptFailed) = failed.dismissWindowsAndHide() {
        expect(true, "脚本失败")
    } else {
        expect(false, "脚本失败")
    }
    expect(hider.calls == 0, "脚本失败不隐藏")

    hider.succeed = false
    let hideFail = FinderDismissService(script: MockScript(result: .success("")), hider: hider)
    if case .failure(.hideFailed) = hideFail.dismissWindowsAndHide() {
        expect(true, "隐藏失败单独报告")
    } else {
        expect(false, "隐藏失败单独报告")
    }
}

func testFinderCommandQServiceEffects() {
    let (service, _, _, _, frontmost, _, _, _, _, scheduler, alerts, qTarget, dismiss) = makeShortcutHarness()
    expect(service.setFinderCommandQEnabled(true), "开启关窗隐藏")
    frontmost.app = safariApp
    qTarget.override = finderApp
    let switched = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(switched.effect == .dismissFinderWindows, "Command-Tab 选中 Finder 时仍关窗")
    scheduler.runAll()
    expect(dismiss.calls == 1, "异步执行关窗隐藏")

    qTarget.override = nil
    qTarget.unknown = true
    let unknown = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(unknown == .pass, "切换器目标不明时透传")
    expect(dismiss.calls == 1, "目标不明不关窗")

    qTarget.unknown = false
    frontmost.app = finderApp
    dismiss.result = .failure(.notPermitted)
    _ = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    scheduler.runAll()
    expect(alerts.titles.contains("无法关闭访达窗口"), "Automation 失败给出提示")

    expect(service.setDoubleCommandQEnabled(true), "同时开启双击")
    dismiss.result = .success(())
    dismiss.calls = 0
    let first = service.handleSnapshot(snapshot(ShortcutKeyClassifier.keyQ, down: true))
    expect(first.effect == .notifyQuitArmed(appName: "Finder", finderDismiss: true), "服务层双开第一次提示关窗")
    scheduler.runAll()
    expect(alerts.titles.contains("再次按 ⌘Q 强关访达"), "提示文案针对 Finder 关窗")
    expect(dismiss.calls == 0, "第一次不关窗")
}

@main
struct TestRunnerMain {
    static func main() {
        testFileSystemService()
        testRootPathStore()
        testClipboardService()
        testFinderVisibilityService()
        testFinderSelectionService()
        testShortcutSettingsStoreDefaults()
        testShortcutEventClassification()
        testFinderMoveStateMachine()
        testDoubleCommandQStateMachine()
        testShortcutServiceLifecycleAndFaults()
        testFinderCutProbeAndQuitEffects()
        testShortcutMenuAppearance()
        testFinderCommandQStateMachine()
        testCommandQTargetResolver()
        testFinderDismissServiceFaults()
        testFinderCommandQServiceEffects()

        if failures == 0 {
            print("\nALL TESTS PASSED")
        } else {
            print("\n\(failures) TEST(S) FAILED")
            exit(1)
        }
    }
}
