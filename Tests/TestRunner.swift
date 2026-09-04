import Foundation
import AppKit

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

@main
struct TestRunnerMain {
    static func main() {
        testFileSystemService()
        testRootPathStore()
        testClipboardService()
        testFinderVisibilityService()
        testFinderSelectionService()

        if failures == 0 {
            print("\nALL TESTS PASSED")
        } else {
            print("\n\(failures) TEST(S) FAILED")
            exit(1)
        }
    }
}
