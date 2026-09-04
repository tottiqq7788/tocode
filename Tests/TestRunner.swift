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

@main
struct TestRunnerMain {
    static func main() {
        testFileSystemService()
        testRootPathStore()
        testClipboardService()

        if failures == 0 {
            print("\nALL TESTS PASSED")
        } else {
            print("\n\(failures) TEST(S) FAILED")
            exit(1)
        }
    }
}
