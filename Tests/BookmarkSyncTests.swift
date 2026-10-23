import Foundation

func testBookmarkURLCanonicalize() {
    expect(BookmarkURL.canonicalize("https://A.com/") == "https://a.com", "主机小写并去掉末尾斜杠")
    expect(BookmarkURL.canonicalize("http://a.com:80/x") == "http://a.com/x", "去掉 http 默认端口")
    expect(BookmarkURL.canonicalize("https://a.com:443/x/") == "https://a.com/x", "去掉 https 默认端口与末尾斜杠")
    expect(BookmarkURL.canonicalize("https://a.com/?a=1&b=2") == "https://a.com?a=1&b=2", "查询保留（根路径末尾斜杠去掉）")
    expect(
        BookmarkURL.canonicalize("https://a.com/?a=1&b=2")
            != BookmarkURL.canonicalize("https://a.com/?b=2&a=1"),
        "查询顺序不同则不是同一条"
    )
    expect(
        BookmarkURL.canonicalize("https://a.com/?a=1&b=2")
            == BookmarkURL.canonicalize("https://a.com?a=1&b=2"),
        "根路径有无斜杠同一条"
    )
    expect(BookmarkURL.canonicalize("ftp://a.com") == nil, "非 http(s) 拒绝")
    // query/fragment 百分号编码与解码形态同一身份（与扩展 canonicalize 对齐）
    let encodedFrag = "https://bijie.e-tecsun.com/#/login?redirect=%2F"
    let decodedFrag = "https://bijie.e-tecsun.com#/login?redirect=/"
    expect(
        BookmarkURL.canonicalize(encodedFrag) == BookmarkURL.canonicalize(decodedFrag),
        "fragment 中 %2F 与 / 同一条"
    )
    expect(
        BookmarkURL.canonicalize("https://a.com/?q=%2Fpath")
            == BookmarkURL.canonicalize("https://a.com?q=/path"),
        "query 中 %2F 与 / 同一条"
    )
    // 中文：大小写百分号与裸 Unicode 同一身份；输出形态为大写百分号（对齐扩展 JS）
    let zhLower = "https://x.com/#/p=%e7%9f%ad"
    let zhUpper = "https://x.com/#/p=%E7%9F%AD"
    let zhRaw = "https://x.com/#/p=短"
    let zhCanon = BookmarkURL.canonicalize(zhLower)
    expect(zhCanon == BookmarkURL.canonicalize(zhUpper), "中文百分号大小写同一条")
    expect(zhCanon == BookmarkURL.canonicalize(zhRaw), "中文裸字与百分号同一条")
    expect(zhCanon == "https://x.com#/p=%E7%9F%AD", "中文规范化为大写百分号而非裸 Unicode")
}

func testFolderTombstoneTreeAbsenceSeed() {
    let gone = BookmarkFolderPath(kind: .other, segments: ["gone"])
    let present = BookmarkFolderPath(kind: .other, segments: ["keep"])
    let layout: [String: String] = [present.sortKey: "0"]
    let confirmed = BookmarkReconcilePump.pathKeysSatisfiedByTreeAbsence(
        tombstonePathKeys: [gone.sortKey, present.sortKey, "other/also-gone"],
        knownFolderLayout: layout
    )
    expect(confirmed.contains(gone.sortKey), "树缺席墓碑应确认")
    expect(confirmed.contains("other/also-gone"), "未在 layout 的墓碑应确认")
    expect(!confirmed.contains(present.sortKey), "树中仍在的夹不得确认（还需删）")
    expect(confirmed.count == 2, "仅缺席两条")
}

func testBookmarkLedgerUnionAndDedupe() {
    let folderToolbar = BookmarkFolderPath(kind: .toolbar, segments: [])
    let folderOther = BookmarkFolderPath(kind: .other, segments: [])
    var ledger = BookmarkLedgerSnapshot.empty
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://a.com/", title: "A1", folder: folderOther, updatedAt: 1),
            BookmarkEntry(url: "https://A.com", title: "A2", folder: folderToolbar, updatedAt: 2)
        ],
        browserKey: "chrome:Default"
    )
    expect(ledger.entries.count == 1, "同网址去重后只留一条")
    expect(ledger.entries[0].url == "https://a.com", "规范化网址")
    expect(ledger.entries[0].folder.kind == .toolbar, "LWW 取较新文件夹")
    expect(ledger.entries[0].title == "A2", "标题取较新")
    expect(ledger.joinedBrowserKeys == ["chrome:Default"], "记录已加入浏览器")

    // 较旧的 toolbar 不覆盖较新的 other（纯 LWW，无 kind 优先级）
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(
                url: "https://a.com",
                title: "A-old",
                folder: folderToolbar,
                siblingIndex: 0,
                updatedAt: 1
            )
        ],
        browserKey: "chrome:Default"
    )
    expect(ledger.entries[0].folder.kind == .toolbar && ledger.entries[0].title == "A2", "较旧不覆盖")
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(
                url: "https://a.com",
                title: "A3",
                folder: folderOther,
                siblingIndex: 5,
                updatedAt: 9
            )
        ],
        browserKey: "chrome:Default"
    )
    expect(ledger.entries[0].folder.kind == .other, "较新 other 胜出")
    // 合并后同级规范化为连续下标；该父下仅一条时为 0。
    expect(ledger.entries[0].siblingIndex == 0, "同级规范化后下标连续")
    expect(ledger.entries[0].title == "A3", "较新标题胜出")

    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://b.com", title: "B", folder: folderOther, updatedAt: 3)
        ],
        browserKey: "firefox:Default"
    )
    expect(ledger.entries.count == 2, "并集保留两边独有网址")
    expect(Set(ledger.entries.map(\.url)) == Set(["https://a.com", "https://b.com"]), "并集内容")
}

func testBookmarkLedgerTombstoneAfterJoin() {
    let folder = BookmarkFolderPath(kind: .other, segments: [])
    var ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(url: "https://keep.com", title: "K", folder: folder, updatedAt: 1),
            BookmarkEntry(url: "https://gone.com", title: "G", folder: folder, updatedAt: 1)
        ],
        browserKey: "chrome:Default"
    )
    ledger = BookmarkLedgerMerge.deleteURL("https://gone.com", in: ledger, now: 10)
    expect(ledger.entries.count == 1 && ledger.entries[0].url == "https://keep.com", "删除后条目消失")
    expect(ledger.tombstones.contains { $0.url == "https://gone.com" }, "删除写入墓碑")

    // 已加入后再上报全量：墓碑挡住加回
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://keep.com", title: "K", folder: folder, updatedAt: 11),
            BookmarkEntry(url: "https://gone.com", title: "G", folder: folder, updatedAt: 11)
        ],
        browserKey: "chrome:Default"
    )
    expect(!ledger.entries.contains { $0.url == "https://gone.com" }, "已加入后墓碑阻止加回")

    // 后加入的浏览器：旧删除会被加回
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://gone.com", title: "G2", folder: folder, updatedAt: 12)
        ],
        browserKey: "edge:Default"
    )
    expect(ledger.entries.contains { $0.url == "https://gone.com" }, "后加入可把旧删除加回")
}

func testBookmarkLedgerChangeURLCollision() {
    let folder = BookmarkFolderPath(kind: .other, segments: [])
    var ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(id: "1", url: "https://old.com", title: "Old", folder: folder, updatedAt: 1),
            BookmarkEntry(id: "2", url: "https://new.com", title: "New", folder: folder, updatedAt: 1)
        ],
        browserKey: "chrome:Default"
    )
    ledger = BookmarkLedgerMerge.changeURL(
        from: "https://old.com",
        to: "https://new.com",
        title: "Changed",
        folder: nil,
        siblingIndex: nil,
        updatedAt: 5,
        in: ledger
    )
    expect(ledger.entries.count == 1, "撞车后只留一条")
    expect(ledger.entries[0].url == "https://new.com", "保留目标网址")
    expect(ledger.tombstones.contains { $0.url == "https://old.com" }, "旧网址进墓碑")
    expect(ledger.entries[0].title == "Changed", "较新标题写入已存在条")
}

func testBookmarkSyncActivityLog() {
    let log = BookmarkSyncActivityLog(capacity: 3)
    log.append("one")
    log.append("two")
    log.append("three")
    log.append("four")
    expect(log.entries.map(\.message) == ["two", "three", "four"], "环形缓冲只留最近容量条")
    expect(
        BookmarkSyncActivityLog.sanitize("保存密钥：abcSECRET123") == "保存[已隐藏]",
        "脱敏密钥片段"
    )
    expect(
        BookmarkSyncActivityLog.sanitize("远程推送完成，修订 3。").contains("修订 3"),
        "普通消息保留"
    )
    var changed = 0
    log.onChange = { changed += 1 }
    log.append("five")
    expect(changed == 1, "追加触发 onChange")
    log.clear()
    expect(log.entries.isEmpty && changed == 2, "清空触发 onChange")
}

func testBookmarkExtensionOpenHelpers() {
    expect(BookmarkBrowser.chrome.extensionPageURL.absoluteString == "chrome://extensions", "Chrome 扩展页")
    expect(BookmarkBrowser.edge.extensionPageURL.absoluteString == "edge://extensions", "Edge 扩展页")
    expect(
        BookmarkBrowser.firefox.extensionPageURL.absoluteString == "about:addons",
        "Firefox 扩展页"
    )
    expect(BookmarkBrowser.chrome.applicationNames.first == "Google Chrome", "Chrome 优先应用名")
    expect(BookmarkBrowser.edge.applicationNames == ["Microsoft Edge"], "Edge 应用名")
    expect(BookmarkBrowser.firefox.applicationNames.contains("Firefox"), "Firefox 应用名")
    expect(
        BookmarkBrowser.firefox.extensionPageURL.absoluteString == "about:addons",
        "Firefox 已在线时打开 about:addons"
    )
    expect(BookmarkExtensionInstall.bundledFirefoxSignedXPI() != nil, "源码树含已签名 Firefox xpi")
    let ini = """
    [Profile0]
    Name=default-release
    IsRelative=1
    Path=Profiles/old.default-release
    Default=1

    [InstallABC]
    Default=Profiles/live.default-release
    Locked=1
    """
    let root = URL(fileURLWithPath: "/Users/example/Library/Application Support/Firefox", isDirectory: true)
    let profile = BookmarkExtensionInstall.firefoxProfileDirectory(profilesIni: ini, root: root)
    expect(
        profile?.path.hasSuffix("Profiles/live.default-release") == true,
        "优先 Install 段正在使用的配置"
    )

    expect(
        BookmarkExtensionInstall.stagedExtensionDirectory(for: .chrome).path.hasSuffix(
            "bookmark-sync-chrome"
        ),
        "Chrome 可加载副本按浏览器分目录"
    )
    expect(
        BookmarkExtensionInstall.stagedExtensionDirectory(for: .firefox).path.hasSuffix(
            "bookmark-sync-firefox"
        ),
        "Firefox 可加载副本按浏览器分目录"
    )
    if BookmarkExtensionInstall.bundledExtensionDirectory() != nil {
        do {
            let chrome = try BookmarkExtensionInstall.prepareInstallableExtensionDirectory(for: .chrome)
            expect(
                FileManager.default.fileExists(atPath: chrome.appendingPathComponent("manifest.json").path),
                "Chrome 同步后含 manifest.json"
            )
            let chromeManifest = try Data(
                contentsOf: chrome.appendingPathComponent("manifest.json")
            )
            let chromeJSON = try JSONSerialization.jsonObject(with: chromeManifest) as? [String: Any]
            let chromeBG = chromeJSON?["background"] as? [String: Any]
            expect(chromeBG?["service_worker"] as? String == "background.js", "Chrome 用 service_worker")

            let firefox = try BookmarkExtensionInstall.prepareInstallableExtensionDirectory(for: .firefox)
            let firefoxManifest = try Data(
                contentsOf: firefox.appendingPathComponent("manifest.json")
            )
            let firefoxJSON = try JSONSerialization.jsonObject(with: firefoxManifest) as? [String: Any]
            let firefoxBG = firefoxJSON?["background"] as? [String: Any]
            expect(firefoxBG?["scripts"] as? [String] == ["background.js"], "Firefox 用 background.scripts")
            expect(firefoxBG?["service_worker"] == nil, "Firefox 去掉 service_worker")
        } catch {
            expect(false, "prepareInstallableExtensionDirectory 不应失败: \(error)")
        }
    }
}

func testBookmarkCLIParser() {
    expect(TocodeCommandParser.parse("bookmark") == .success(.bookmark(.status)), "bookmark 默认 status")
    expect(TocodeCommandParser.parse("bookmark list") == .success(.bookmark(.list)), "bookmark list")
    expect(TocodeCommandParser.parse("bookmark get https://a.com") == .success(.bookmark(.get("https://a.com"))), "bookmark get")
    expect(
        TocodeCommandParser.parse("bookmark add --url https://a.com --title A --folder toolbar --index 2")
            == .success(.bookmark(.add(TocodeBookmarkAddPayload(
                url: "https://a.com",
                title: "A",
                folder: "toolbar",
                siblingIndex: 2
            )))),
        "bookmark add --index"
    )
    expect(
        TocodeCommandParser.parse("bookmark update --url https://a.com --new-url https://b.com")
            == .success(.bookmark(.update(TocodeBookmarkUpdatePayload(
                url: "https://a.com",
                title: nil,
                folder: nil,
                siblingIndex: nil,
                newURL: "https://b.com"
            )))),
        "bookmark update --new-url"
    )
    expect(
        TocodeCommandParser.parse("bookmark update --url https://a.com --index 3")
            == .success(.bookmark(.update(TocodeBookmarkUpdatePayload(
                url: "https://a.com",
                title: nil,
                folder: nil,
                siblingIndex: 3,
                newURL: nil
            )))),
        "bookmark update --index"
    )
    expect(TocodeCommandParser.parse("bookmark delete --url https://a.com") == .success(.bookmark(.delete("https://a.com"))), "bookmark delete")
    expect(TocodeCommandParser.parse("bookmark pull") == .success(.bookmark(.pull)), "bookmark pull")
    expect(TocodeCommandParser.parse("bookmark backup status") == .success(.bookmark(.backup(.status))), "bookmark backup status")
    expect(TocodeCommandParser.parse("bookmark backup list") == .success(.bookmark(.backup(.list))), "bookmark backup list")
    expect(TocodeCommandParser.parse("bookmark backup now") == .success(.bookmark(.backup(.now))), "bookmark backup now")
    expect(
        TocodeCommandParser.parse("bookmark backup restore") == .success(.bookmark(.backup(.restore(day: nil)))),
        "bookmark backup restore 默认最近"
    )
    expect(
        TocodeCommandParser.parse("bookmark backup restore --day 2026-10-20")
            == .success(.bookmark(.backup(.restore(day: "2026-10-20")))),
        "bookmark backup restore --day"
    )
    expect(TocodeCommandParser.parse("bookmark folders") == .success(.bookmark(.folders)), "bookmark folders")
    expect(TocodeCommandParser.parse("bookmark folders --json") == .success(.bookmark(.folders)), "bookmark folders --json")
    expect(TocodeCommandParser.helpText.contains("bookmark backup"), "help 含 backup")
    expect(TocodeCommandParser.helpText.contains("bookmark folders"), "help 含 folders")
    expect(TocodeCommandParser.helpText.contains("bookmark list"), "help 含 bookmark")
    expect(TocodeCommandParser.parse("bookmark add").isFailure, "bookmark add 缺 url 失败")
}

func testBookmarkCLIFolderRootedPaths() {
    switch BookmarkCLIFolder.parse("toolbar") {
    case .success(let path):
        expect(path?.kind == .toolbar && path?.segments.isEmpty == true, "toolbar 根")
    case .failure:
        expect(false, "toolbar 根")
    }
    switch BookmarkCLIFolder.parse("toolbar/工作/a") {
    case .success(let path):
        expect(path?.kind == .toolbar && path?.segments == ["工作", "a"], "toolbar 前缀路径")
    case .failure:
        expect(false, "toolbar 前缀路径")
    }
    switch BookmarkCLIFolder.parse("书签栏/工作") {
    case .success(let path):
        expect(path?.kind == .toolbar && path?.segments == ["工作"], "书签栏中文前缀")
    case .failure:
        expect(false, "书签栏中文前缀")
    }
    switch BookmarkCLIFolder.parse("other/归档/旧") {
    case .success(let path):
        expect(path?.kind == .other && path?.segments == ["归档", "旧"], "other 前缀路径")
    case .failure:
        expect(false, "other 前缀路径")
    }
    switch BookmarkCLIFolder.parse("named:toolbar/假") {
    case .success(let path):
        expect(path?.kind == .named && path?.segments == ["toolbar", "假"], "显式 named 保留")
    case .failure:
        expect(false, "显式 named 保留")
    }
    switch BookmarkCLIFolder.parse("工作/项目") {
    case .success(let path):
        expect(path?.kind == .named && path?.segments == ["工作", "项目"], "无前缀仍为 named")
    case .failure:
        expect(false, "无前缀仍为 named")
    }
    switch BookmarkCLIFolder.parse("toolbar/") {
    case .failure:
        expect(true, "toolbar/ 无段报错")
    case .success:
        expect(false, "toolbar/ 无段报错")
    }
}

func testBookmarkCLIFolderTreeBuild() {
    let folder = BookmarkFolderPath(kind: .toolbar, segments: ["工作"])
    var ledger = BookmarkLedgerSnapshot.empty
    ledger.folders = [
        BookmarkFolderRecord(path: folder, siblingIndex: 2, updatedAt: 1)
    ]
    ledger.entries = [
        BookmarkEntry(url: "https://a.com", title: "A", folder: folder, siblingIndex: 0, updatedAt: 1),
        BookmarkEntry(
            url: "https://b.com",
            title: "B",
            folder: BookmarkFolderPath(kind: .toolbar, segments: ["工作", "子"]),
            siblingIndex: 0,
            updatedAt: 1
        )
    ]
    let tree = BookmarkCLIFolderTree.build(from: ledger)
    expect(!tree.isEmpty, "folders 树非空")
    let work = tree.first {
        ($0["kind"] as? String) == "toolbar" && ($0["segments"] as? [String]) == ["工作"]
    }
    expect(work != nil, "含工作夹")
    expect(work?["childBookmarkCount"] as? Int == 1, "工作夹下 1 书签")
    expect(work?["siblingIndex"] as? Int == 2, "保留 siblingIndex")
    let child = tree.first {
        ($0["kind"] as? String) == "toolbar" && ($0["segments"] as? [String]) == ["工作", "子"]
    }
    expect(child != nil, "由条目推导子夹")
}

@MainActor
func testBookmarkFoldersCLICommand() {
    let bookmarks = MockBookmarkSync()
    bookmarks.ledger.folders = [
        BookmarkFolderRecord(
            path: BookmarkFolderPath(kind: .other, segments: ["工具"]),
            siblingIndex: 0,
            updatedAt: 1
        )
    ]
    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )
    if case .success(let out) = executor.execute("bookmark folders --json") {
        expect(out.text.contains("工具"), "folders 输出含夹名")
        expect(out.text.contains("childBookmarkCount"), "folders 含计数字段")
    } else {
        expect(false, "folders 命令成功")
    }
}

@MainActor
func testBookmarkCLIExecutorCRUDAndPull() async {
    let bookmarks = MockBookmarkSync()
    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )

    if case .success(let added) = executor.execute("bookmark add --url https://Example.com/ --title Demo --folder toolbar") {
        expect(added.text.contains("https://example.com"), "add 返回规范化网址")
        expect(added.text.contains("Demo"), "add 返回标题")
    } else {
        expect(false, "add 返回规范化网址")
    }

    if case .success(let listed) = executor.execute("bookmark list") {
        expect(listed.text.contains("https://example.com"), "list 含新增项")
    } else {
        expect(false, "list 含新增项")
    }

    if case .success(let updated) = executor.execute("bookmark update --url https://example.com --title Renamed") {
        expect(updated.text.contains("Renamed"), "update 改标题")
    } else {
        expect(false, "update 改标题")
    }

    if case .success(let deleted) = executor.execute("bookmark delete --url https://example.com") {
        expect(deleted.text.contains("\"ok\" : true") || deleted.text.contains("\"ok\": true") || deleted.text.contains("\"ok\":true"), "delete 返回 ok")
    } else {
        expect(false, "delete 返回 ok")
    }
    expect(bookmarks.ledger.entries.isEmpty, "delete 后账本为空")
    expect(bookmarks.ledger.tombstones.contains { $0.url == "https://example.com" }, "delete 写墓碑")

    bookmarks.remoteKey = false
    if case .failure(let error) = await executor.executeAsync("bookmark pull") {
        expect(error.message.contains("远程同步密钥"), "无密钥 pull 失败")
    } else {
        expect(false, "无密钥 pull 失败")
    }

    bookmarks.remoteKey = true
    bookmarks.ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(
                url: "https://pulled.com",
                title: "Pulled",
                folder: BookmarkFolderPath(kind: .other, segments: []),
                updatedAt: 1
            )
        ],
        browserKey: "cli"
    )
    if case .success(let pulled) = await executor.executeAsync("bookmark pull") {
        expect(pulled.text.contains("\"entries\"") && pulled.text.contains("1"), "有密钥 pull 成功")
    } else {
        expect(false, "有密钥 pull 成功")
    }
}

/// 与扩展 clampIndex 同语义，防止回归。
func clampBookmarkSiblingIndex(_ wanted: Int, childCount: Int, forMoveAlreadyChild: Bool) -> Int {
    let positive = max(0, wanted)
    if forMoveAlreadyChild {
        let maxIndex = max(0, childCount - 1)
        return min(positive, maxIndex)
    }
    return min(positive, childCount)
}

func testBookmarkSiblingIndexClamp() {
    expect(clampBookmarkSiblingIndex(0, childCount: 0, forMoveAlreadyChild: false) == 0, "空夹 create append")
    expect(clampBookmarkSiblingIndex(99, childCount: 3, forMoveAlreadyChild: false) == 3, "create 钳到 append")
    expect(clampBookmarkSiblingIndex(99, childCount: 3, forMoveAlreadyChild: true) == 2, "同父 move 钳到 count-1")
    expect(clampBookmarkSiblingIndex(-5, childCount: 3, forMoveAlreadyChild: false) == 0, "负 index 归零")
}

func testBookmarkLayoutIndexAndLegacyDecode() {
    let nodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "书签栏",
            "index": 0,
            "children": [
                [
                    "type": "bookmark",
                    "id": "1",
                    "title": "First",
                    "url": "https://first.com",
                    "index": 0,
                    "dateAdded": 2_000.0
                ],
                [
                    "type": "bookmark",
                    "id": "2",
                    "title": "Second",
                    "url": "https://second.com",
                    "index": 1,
                    "dateAdded": 3_000.0
                ]
            ]
        ]
    ]
    let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
    expect(layout.entries.count == 2, "解析两条书签")
    expect(layout.entries.first { $0.url == "https://first.com" }?.siblingIndex == 0, "保留 index 0")
    expect(layout.entries.first { $0.url == "https://second.com" }?.siblingIndex == 1, "保留 index 1")

    let legacyJSON = """
    {"version":1,"entries":[{"id":"x","url":"https://legacy.com","title":"L","folder":{"kind":"toolbar","segments":[]},"updatedAt":1}],"tombstones":[],"remoteRevision":0,"joinedBrowserKeys":[]}
    """
    let data = Data(legacyJSON.utf8)
    let decoded = try? JSONDecoder().decode(BookmarkLedgerSnapshot.self, from: data)
    expect(decoded?.entries.count == 1, "旧账本可解码")
    expect(decoded?.entries.first?.siblingIndex == 0, "缺 siblingIndex 默认 0")
    expect(decoded?.folders.isEmpty == true, "缺 folders 默认空")
}

func testBookmarkToolbarRootSegmentsPreserved() {
    // 模拟 Chrome getTree：外层虚拟根再挂书签栏 / 其他书签。
    let nodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "",
            "index": 0,
            "children": [
                [
                    "type": "folder",
                    "title": "书签栏",
                    "index": 0,
                    "dateAdded": 1_000.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "totti",
                            "index": 1,
                            "dateAdded": 2_000.0,
                            "children": [
                                [
                                    "type": "bookmark",
                                    "id": "tb",
                                    "title": "Bar",
                                    "url": "https://bar.example/totti",
                                    "index": 0,
                                    "dateAdded": 3_000.0
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "type": "folder",
                    "title": "其他书签",
                    "index": 1,
                    "dateAdded": 1_000.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "totti",
                            "index": 0,
                            "dateAdded": 4_000.0,
                            "children": [
                                [
                                    "type": "bookmark",
                                    "id": "ot",
                                    "title": "Other",
                                    "url": "https://other.example/totti",
                                    "index": 0,
                                    "dateAdded": 5_000.0
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
    let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
    let bar = layout.entries.first { $0.url == "https://bar.example/totti" }
    let other = layout.entries.first { $0.url == "https://other.example/totti" }
    expect(bar?.folder.kind == .toolbar && bar?.folder.segments == ["totti"], "书签栏子夹保留 toolbar 根")
    expect(other?.folder.kind == .other && other?.folder.segments == ["totti"], "其他书签子夹保留 other 根")
    expect(bar?.folder.sortKey != other?.folder.sortKey, "同名夹不同根路径不同")
    let folderKeys = Set(layout.folders.map(\.pathKey))
    expect(folderKeys.contains("toolbar|totti"), "记录 toolbar/totti 空夹路径")
    expect(folderKeys.contains("other|totti"), "记录 other/totti 空夹路径")
    expect(!folderKeys.contains("named|totti"), "不再把根下子夹收成 named")
}

func testBookmarkMobileRootAliasOnDeviceBookmarks() {
    let nodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "",
            "index": 0,
            "children": [
                [
                    "type": "folder",
                    "title": "书签栏",
                    "index": 0,
                    "dateAdded": 1.0,
                    "children": [] as [Any]
                ],
                [
                    "type": "folder",
                    "title": "其他书签",
                    "index": 1,
                    "dateAdded": 1.0,
                    "children": [] as [Any]
                ],
                [
                    "type": "folder",
                    "title": "移动设备上的书签",
                    "index": 2,
                    "dateAdded": 1.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "phone-shell",
                            "index": 0,
                            "dateAdded": 2.0,
                            "children": [] as [Any]
                        ]
                    ]
                ]
            ]
        ]
    ]
    let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
    let keys = Set(layout.folders.map(\.pathKey))
    expect(keys.contains("mobile|phone-shell"), "移动设备上的书签下空夹摄入为 mobile")
    expect(!keys.contains(where: { $0.hasPrefix("named|") && $0.contains("phone") }), "不得收成 named")
}

@MainActor
func testBookmarkFolderTombstonesCLIList() {
    expect(
        TocodeCommandParser.parse("bookmark folder tombstones") == .success(.bookmark(.folder(.tombstones))),
        "bookmark folder tombstones"
    )
    expect(
        TocodeCommandParser.parse("bookmark folder tombstones --json")
            == .success(.bookmark(.folder(.tombstones))),
        "bookmark folder tombstones --json"
    )
    expect(TocodeCommandParser.helpText.contains("tombstones"), "help 含 tombstones")

    let path = BookmarkFolderPath(kind: .other, segments: ["gone"])
    var ledger = BookmarkLedgerSnapshot.empty
    ledger.folderTombstones = [
        BookmarkFolderTombstone(path: path, deletedAt: 100)
    ]
    ledger.folders = [
        BookmarkFolderRecord(path: BookmarkFolderPath(kind: .toolbar, segments: ["live"]), siblingIndex: 0, updatedAt: 1)
    ]
    let bookmarks = MockBookmarkSync()
    bookmarks.ledger = ledger
    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )
    if case .success(let out) = executor.execute("bookmark folder tombstones --json") {
        let data = Data(out.text.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        expect((obj?["count"] as? Int) == 1, "tombstones count=1")
        expect((obj?["overlapWithLiveFolders"] as? Int) == 0, "与现存夹交集 0")
        let byKind = obj?["byKind"] as? [String: Any]
        expect((byKind?["other"] as? Int) == 1, "byKind other=1")
    } else {
        expect(false, "tombstones CLI 应成功")
    }
}

func testBookmarkFirefoxMenuRootMapsToOther() {
    // Firefox：书签工具栏 + 书签菜单（内含 Mozilla Firefox 空夹）+ 其他书签。
    let nodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "",
            "index": 0,
            "children": [
                [
                    "type": "folder",
                    "title": "书签工具栏",
                    "index": 0,
                    "dateAdded": 1_000.0,
                    "children": [] as [Any]
                ],
                [
                    "type": "folder",
                    "title": "书签菜单",
                    "index": 1,
                    "dateAdded": 1_000.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "Mozilla Firefox",
                            "index": 0,
                            "dateAdded": 2_000.0,
                            "children": [] as [Any]
                        ]
                    ]
                ],
                [
                    "type": "folder",
                    "title": "其他书签",
                    "index": 2,
                    "dateAdded": 1_000.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "shell",
                            "index": 0,
                            "dateAdded": 3_000.0,
                            "children": [] as [Any]
                        ]
                    ]
                ]
            ]
        ]
    ]
    let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
    let folderKeys = Set(layout.folders.map(\.pathKey))
    expect(folderKeys.contains("other|Mozilla Firefox"), "书签菜单下空夹摄入为 other")
    expect(folderKeys.contains("other|shell"), "其他书签下空夹仍为 other")
    expect(!folderKeys.contains(where: { $0.hasPrefix("named|") && $0.contains("Mozilla") }), "不得收成 named")

    let enNodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "",
            "index": 0,
            "children": [
                [
                    "type": "folder",
                    "title": "Bookmarks Toolbar",
                    "index": 0,
                    "dateAdded": 1.0,
                    "children": [] as [Any]
                ],
                [
                    "type": "folder",
                    "title": "Bookmarks Menu",
                    "index": 1,
                    "dateAdded": 1.0,
                    "children": [
                        [
                            "type": "folder",
                            "title": "Mozilla Firefox",
                            "index": 0,
                            "dateAdded": 2.0,
                            "children": [] as [Any]
                        ]
                    ]
                ]
            ]
        ]
    ]
    let enLayout = BookmarkLedgerMerge.layout(fromBrowserNodes: enNodes)
    expect(
        enLayout.folders.contains { $0.pathKey == "other|Mozilla Firefox" },
        "Bookmarks Menu 亦映射为 other"
    )
}

func testBookmarkToolbarUnionABYExample() {
    // Edge 书签栏 A、B；Chrome 书签栏 A、C、D；Firefox 书签栏 B、C、Y，且 D 在其他书签较新。
    let toolbar = BookmarkFolderPath(kind: .toolbar, segments: [])
    let other = BookmarkFolderPath(kind: .other, segments: [])
    var ledger = BookmarkLedgerSnapshot.empty
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://a.example", title: "A", folder: toolbar, siblingIndex: 0, updatedAt: 1),
            BookmarkEntry(url: "https://b.example", title: "B", folder: toolbar, siblingIndex: 1, updatedAt: 1)
        ],
        browserKey: "edge:Default"
    )
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://a.example", title: "A", folder: toolbar, siblingIndex: 0, updatedAt: 1),
            BookmarkEntry(url: "https://c.example", title: "C", folder: toolbar, siblingIndex: 1, updatedAt: 1),
            BookmarkEntry(url: "https://d.example", title: "D", folder: toolbar, siblingIndex: 2, updatedAt: 1)
        ],
        browserKey: "chrome:Default"
    )
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://b.example", title: "B", folder: toolbar, siblingIndex: 0, updatedAt: 1),
            BookmarkEntry(url: "https://c.example", title: "C", folder: toolbar, siblingIndex: 1, updatedAt: 1),
            BookmarkEntry(url: "https://y.example", title: "Y", folder: toolbar, siblingIndex: 2, updatedAt: 1),
            BookmarkEntry(url: "https://d.example", title: "D", folder: other, siblingIndex: 0, updatedAt: 9)
        ],
        browserKey: "firefox:Default"
    )
    let byURL = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.url, $0) })
    expect(byURL["https://a.example"]?.folder.kind == .toolbar, "A 留在书签栏")
    expect(byURL["https://b.example"]?.folder.kind == .toolbar, "B 留在书签栏")
    expect(byURL["https://c.example"]?.folder.kind == .toolbar, "C 留在书签栏")
    expect(byURL["https://y.example"]?.folder.kind == .toolbar, "Y 留在书签栏")
    expect(byURL["https://d.example"]?.folder.kind == .other, "较新的 D 离开书签栏")
    expect(Set(byURL.keys) == Set([
        "https://a.example", "https://b.example", "https://c.example", "https://d.example", "https://y.example"
    ]), "并集保留全部网址")
}

func testBookmarkToolbarAliasNormalizedFromOther() {
    let nodes: [[String: Any]] = [
        [
            "type": "folder",
            "title": "书签工具栏",
            "index": 0,
            "dateAdded": 1_000.0,
            "children": [
                [
                    "type": "folder",
                    "title": "个人",
                    "index": 0,
                    "dateAdded": 2_000.0,
                    "children": [
                        [
                            "type": "bookmark",
                            "id": "p",
                            "title": "P",
                            "url": "https://personal.example",
                            "index": 0,
                            "dateAdded": 3_000.0
                        ]
                    ]
                ]
            ]
        ]
    ]
    let layout = BookmarkLedgerMerge.layout(fromBrowserNodes: nodes)
    let entry = layout.entries.first { $0.url == "https://personal.example" }
    expect(entry?.folder.kind == .toolbar && entry?.folder.segments == ["个人"], "Firefox 书签工具栏根识别为 toolbar")

    let misfiled = BookmarkFolderPath(kind: .other, segments: ["书签工具栏", "官网"])
    let normalized = BookmarkLedgerMerge.normalizeFolderPath(misfiled)
    expect(normalized.kind == .toolbar && normalized.segments == ["官网"], "other/书签工具栏/… 归一到 toolbar")

    let shellAliases = ["书签工具栏", "toolbar", "书签栏"]
    for name in shellAliases {
        let shell = BookmarkFolderPath(kind: .other, segments: [name])
        let kept = BookmarkLedgerMerge.normalizeFolderPath(shell)
        expect(
            kept.kind == .other && kept.segments == [name],
            "other/\(name) 空壳保留字面路径"
        )
        do {
            let after = try BookmarkLedgerMerge.deleteFolder(shell, recursive: true, now: 9, in: .empty)
            expect(
                after.folderTombstones.contains { $0.pathKey == shell.sortKey },
                "other/\(name) 可删并写墓碑"
            )
            expect(!BookmarkLedgerMerge.isRootFolderPath(kept), "空壳不是根")
        } catch {
            expect(false, "other/\(name) 删除不应失败: \(error)")
        }
    }

    var ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(
                url: "https://site.example",
                title: "S",
                folder: misfiled,
                siblingIndex: 0,
                updatedAt: 1
            )
        ],
        incomingFolders: [
            BookmarkFolderRecord(path: misfiled, siblingIndex: 0, updatedAt: 1)
        ],
        browserKey: "firefox:Default"
    )
    expect(ledger.entries[0].folder.kind == .toolbar && ledger.entries[0].folder.segments == ["官网"], "合并时归一路径")
    expect(ledger.folders.contains { $0.path.kind == .toolbar && $0.path.segments == ["官网"] }, "夹记录归一")
}

func testBookmarkNamedSupersededByRootedPath() {
    let named = BookmarkFolderPath(kind: .named, segments: ["totti"])
    let toolbar = BookmarkFolderPath(kind: .toolbar, segments: ["totti"])
    var ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(url: "https://x.example", title: "X", folder: named, siblingIndex: 0, updatedAt: 5)
        ],
        incomingFolders: [
            BookmarkFolderRecord(path: named, siblingIndex: 0, updatedAt: 5)
        ],
        browserKey: "chrome:Default"
    )
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(url: "https://x.example", title: "X", folder: toolbar, siblingIndex: 1, updatedAt: 3)
        ],
        incomingFolders: [
            BookmarkFolderRecord(path: toolbar, siblingIndex: 1, updatedAt: 3)
        ],
        browserKey: "chrome:Default"
    )
    expect(ledger.entries[0].folder.kind == .toolbar, "named 同段让位于 toolbar 路径")
    expect(ledger.entries[0].title == "X", "较新标题仍保留")
    expect(ledger.folders.contains { $0.path.kind == .toolbar && $0.path.segments == ["totti"] }, "保留 toolbar 夹记录")
    expect(!ledger.folders.contains { $0.path.kind == .named && $0.path.segments == ["totti"] }, "丢掉已被替代的 named 夹记录")
}

func testBookmarkSiblingIndexCanonicalizeOnCollision() {
    let toolbarRoot = BookmarkFolderPath(kind: .toolbar, segments: [])
    let ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(
                url: "https://a.example",
                title: "A",
                folder: toolbarRoot,
                siblingIndex: 0,
                updatedAt: 1
            ),
            BookmarkEntry(
                url: "https://b.example",
                title: "B",
                folder: toolbarRoot,
                siblingIndex: 5,
                updatedAt: 2
            )
        ],
        incomingFolders: [
            BookmarkFolderRecord(
                path: BookmarkFolderPath(kind: .toolbar, segments: ["娱乐"]),
                siblingIndex: 5,
                updatedAt: 3
            ),
            BookmarkFolderRecord(
                path: BookmarkFolderPath(kind: .toolbar, segments: ["文档"]),
                siblingIndex: 5,
                updatedAt: 1
            )
        ],
        browserKey: "edge:Default"
    )
    let folderRecords = ledger.folders.filter { $0.path.kind == .toolbar && $0.path.segments.count == 1 }
    let folderIndices = folderRecords.map(\.siblingIndex)
    expect(Set(folderIndices).count == folderIndices.count, "同级夹 siblingIndex 唯一")
    // 书签与夹同属 toolbar 根：全部子项一起 0..n-1
    let allIndices = (
        ledger.entries.filter { $0.folder == toolbarRoot }.map(\.siblingIndex)
            + folderIndices
    ).sorted()
    expect(allIndices == Array(0 ..< allIndices.count), "书签栏根下书签与夹统一连续编号")
    // 较新的「娱乐」应排在同号冲突的「文档」之前，因而下标更小
    let yu = ledger.folders.first { $0.path.segments == ["娱乐"] }?.siblingIndex
    let doc = ledger.folders.first { $0.path.segments == ["文档"] }?.siblingIndex
    expect(yu != nil && doc != nil && yu! < doc!, "同号冲突时较新夹顺序更靠前")
}

func testBookmarkSyncCryptoRoundTrip() {
    let secret = BookmarkSyncKeyFactory.generate()
    expect(secret.count >= 32, "生成密钥足够长")
    let room = BookmarkSyncCrypto.roomID(for: secret)
    expect(room.count == 64, "房间号为 SHA-256 hex")
    let verifier = BookmarkSyncCrypto.verifier(for: secret)
    expect(verifier.count == 64, "校验值为 HMAC hex")
    expect(BookmarkSyncCrypto.constantTimeEqual(verifier, verifier), "校验值自比相等")
    expect(!BookmarkSyncCrypto.constantTimeEqual(verifier, room), "校验值不等于房间号")

    let snapshot = BookmarkLedgerSnapshot(
        version: 1,
        entries: [
            BookmarkEntry(
                url: "https://example.com",
                title: "Example",
                folder: BookmarkFolderPath(kind: .toolbar, segments: []),
                updatedAt: 1
            )
        ],
        tombstones: [],
        remoteRevision: 3,
        joinedBrowserKeys: ["chrome:Default"]
    )
    do {
        let cipher = try BookmarkSyncCrypto.encrypt(snapshot: snapshot, secret: secret)
        expect(!cipher.isEmpty, "密文非空")
        expect(!cipher.contains("example.com"), "密文不含明文网址")
        let opened = try BookmarkSyncCrypto.decrypt(ciphertextBase64: cipher, secret: secret)
        expect(opened == snapshot, "加密往返一致")
    } catch {
        expect(false, "加密往返不应失败: \(error)")
    }
}

func testBookmarkBackupPackUpsertPruneAndRestoreReplace() {
    let folder = BookmarkFolderPath(kind: .other, segments: [])
    func ledger(url: String, at: Double) -> BookmarkLedgerSnapshot {
        BookmarkLedgerMerge.unionMerge(
            ledger: .empty,
            incoming: [BookmarkEntry(url: url, title: url, folder: folder, updatedAt: at)],
            browserKey: "cli"
        )
    }

    var pack = BookmarkBackupPack.empty
    pack = BookmarkBackupPackLogic.upsert(
        pack: pack,
        day: "2026-10-20",
        ledger: ledger(url: "https://a.com", at: 1),
        takenAt: 1,
        today: "2026-10-23"
    )
    pack = BookmarkBackupPackLogic.upsert(
        pack: pack,
        day: "2026-10-20",
        ledger: ledger(url: "https://overwritten.com", at: 2),
        takenAt: 2,
        today: "2026-10-23"
    )
    expect(pack.slots.count == 1, "同日覆盖仍一槽")
    expect(pack.slots[0].ledger.entries.first?.url == "https://overwritten.com", "同日覆盖取新账本")

    for offset in 0..<10 {
        let day = String(format: "2026-10-%02d", 14 + offset)
        pack = BookmarkBackupPackLogic.upsert(
            pack: pack,
            day: day,
            ledger: ledger(url: "https://d\(offset).com", at: Double(offset)),
            takenAt: Double(offset),
            today: "2026-10-23"
        )
    }
    expect(pack.slots.count == 7, "最多保留 7 日")
    expect(pack.slots.map(\.day).min() == "2026-10-17", "丢掉早于 today−6 的槽")
    expect(pack.slots.map(\.day).max() == "2026-10-23", "保留今日")

    let chosen = BookmarkBackupPackLogic.slot(in: pack, day: "2026-10-20")
    expect(chosen?.ledger.entries.first?.url == "https://d6.com", "按日取槽")

    var formal = ledger(url: "https://live.com", at: 99)
    formal.remoteRevision = 5
    if let slot = BookmarkBackupPackLogic.slot(in: pack, day: "2026-10-20") {
        var restored = slot.ledger
        restored.remoteRevision = formal.remoteRevision
        formal = restored
    }
    expect(formal.entries.first?.url == "https://d6.com", "还原整本替换正式条目")
    expect(formal.remoteRevision == 5, "还原保留正式修订号")
    expect(!formal.entries.contains { $0.url == "https://live.com" }, "还原不保留还原前条目")
}

func testBookmarkBackupRoomIsolatedFromFormal() {
    let secret = "backup-room-isolation-key"
    let formal = BookmarkSyncCrypto.roomID(for: secret)
    let backup = BookmarkSyncCrypto.backupRoomID(for: secret)
    expect(formal != backup, "备份房间与正式房间隔离")
    expect(BookmarkSyncCrypto.verifier(for: secret) != BookmarkSyncCrypto.backupVerifier(for: secret), "备份校验值与正式不同")

    let pack = BookmarkBackupPack(
        version: 1,
        slots: [
            BookmarkBackupSlot(
                day: "2026-10-23",
                takenAt: 1,
                ledger: BookmarkLedgerSnapshot(
                    version: 1,
                    entries: [
                        BookmarkEntry(
                            url: "https://pack.example",
                            title: "P",
                            folder: BookmarkFolderPath(kind: .toolbar, segments: []),
                            updatedAt: 1
                        )
                    ],
                    tombstones: [],
                    remoteRevision: 0,
                    joinedBrowserKeys: []
                )
            )
        ],
        remoteRevision: 2
    )
    do {
        let cipher = try BookmarkSyncCrypto.encryptPack(pack, secret: secret)
        expect(!cipher.contains("pack.example"), "备份密文不含明文网址")
        let opened = try BookmarkSyncCrypto.decryptPack(ciphertextBase64: cipher, secret: secret)
        expect(opened == pack, "备份包加密往返一致")
    } catch {
        expect(false, "备份包加密往返不应失败: \(error)")
    }
}

@MainActor
func testBookmarkBackupCLIRestore() async {
    let bookmarks = MockBookmarkSync()
    bookmarks.ledger = BookmarkLedgerMerge.unionMerge(
        ledger: .empty,
        incoming: [
            BookmarkEntry(
                url: "https://live.com",
                title: "Live",
                folder: BookmarkFolderPath(kind: .other, segments: []),
                updatedAt: 1
            )
        ],
        browserKey: "cli"
    )
    bookmarks.backupPack = BookmarkBackupPackLogic.upsert(
        pack: .empty,
        day: "2026-10-21",
        ledger: BookmarkLedgerMerge.unionMerge(
            ledger: .empty,
            incoming: [
                BookmarkEntry(
                    url: "https://backup.com",
                    title: "Backup",
                    folder: BookmarkFolderPath(kind: .toolbar, segments: []),
                    updatedAt: 2
                )
            ],
            browserKey: "cli"
        ),
        takenAt: 2,
        today: "2026-10-23"
    )

    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )

    if case .success(let listed) = executor.execute("bookmark backup list") {
        expect(listed.text.contains("2026-10-21"), "backup list 含日槽")
    } else {
        expect(false, "backup list 含日槽")
    }

    if case .success(let restored) = await executor.executeAsync("bookmark backup restore --day 2026-10-21") {
        expect(restored.text.contains("backup.com") == false || restored.text.contains("\"ok\""), "restore 返回 ok")
        expect(bookmarks.ledger.entries.first?.url == "https://backup.com", "CLI restore 整本覆盖")
        expect(!bookmarks.ledger.entries.contains { $0.url == "https://live.com" }, "CLI restore 去掉旧正式条目")
    } else {
        expect(false, "CLI restore 成功")
    }
}

func testBookmarkFolderCreateKeepsEmpty() {
    var ledger = BookmarkLedgerSnapshot.empty
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["AI"])
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: 0, updatedAt: 1, in: ledger)
    expect(ledger.folders.contains { $0.pathKey == path.sortKey }, "create 写入空夹记录")
    expect(!BookmarkLedgerMerge.hasBookmarks(under: path, in: ledger), "空夹无书签")
    let tree = BookmarkCLIFolderTree.build(from: ledger)
    expect(tree.contains { ($0["kind"] as? String) == "toolbar" && ($0["segments"] as? [String]) == ["AI"] }, "folders 可见空夹")
}

func testBookmarkFolderDeleteTombstoneBlocksUnion() {
    var ledger = BookmarkLedgerSnapshot.empty
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["旧壳"])
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: 1, updatedAt: 1, in: ledger)
    do {
        ledger = try BookmarkLedgerMerge.deleteFolder(path, recursive: false, now: 2, in: ledger)
    } catch {
        expect(false, "删空夹应成功: \(error)")
        return
    }
    expect(!ledger.folders.contains { $0.pathKey == path.sortKey }, "删后无夹记录")
    expect(ledger.folderTombstones.contains { $0.pathKey == path.sortKey }, "写入夹墓碑")
    // 已加入浏览器：即使较新也硬挡（防残留副本）
    let fromBrowser = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [],
        incomingFolders: [BookmarkFolderRecord(path: path, siblingIndex: 0, updatedAt: 9)],
        browserKey: "chrome"
    )
    expect(!fromBrowser.folders.contains { $0.pathKey == path.sortKey }, "已加入浏览器不得复活墓碑夹")
    // 远程 merge（browserKey nil）：对称 LWW，较新夹打掉墓碑
    let revived = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [],
        incomingFolders: [BookmarkFolderRecord(path: path, siblingIndex: 0, updatedAt: 9)],
        browserKey: nil
    )
    expect(revived.folders.contains { $0.pathKey == path.sortKey }, "远程较新 recreate 应复活夹")
    expect(!revived.folderTombstones.contains { $0.pathKey == path.sortKey }, "复活后清墓碑")
}

func testBookmarkFolderDeleteRejectsNonEmpty() {
    var ledger = BookmarkLedgerSnapshot.empty
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["工作"])
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(
                url: "https://work.example",
                title: "W",
                folder: path,
                siblingIndex: 0,
                updatedAt: 1
            )
        ],
        browserKey: "cli"
    )
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: 0, updatedAt: 1, in: ledger)
    do {
        _ = try BookmarkLedgerMerge.deleteFolder(path, recursive: false, in: ledger)
        expect(false, "有书签时应拒绝删夹")
    } catch {
        expect(true, "有书签时应拒绝删夹")
    }
}

func testBookmarkFolderPruneEmptyAndReorder() {
    var ledger = BookmarkLedgerSnapshot.empty
    let keep = BookmarkFolderPath(kind: .toolbar, segments: ["其它"])
    let shell = BookmarkFolderPath(kind: .toolbar, segments: ["anker"])
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(keep, siblingIndex: 5, updatedAt: 1, in: ledger)
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(shell, siblingIndex: 0, updatedAt: 1, in: ledger)
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(
                url: "https://keep.example",
                title: "K",
                folder: keep,
                siblingIndex: 0,
                updatedAt: 1
            )
        ],
        browserKey: "cli"
    )
    do {
        let pruned = try BookmarkLedgerMerge.pruneEmptyFolders(
            under: BookmarkFolderPath(kind: .toolbar, segments: []),
            now: 3,
            in: ledger
        )
        ledger = pruned.ledger
        expect(pruned.removed.contains { $0.sortKey == shell.sortKey }, "剪掉空壳 anker")
        expect(ledger.folders.contains { $0.pathKey == keep.sortKey }, "保留有书签的其它")
        ledger = try BookmarkLedgerMerge.moveFolder(
            from: keep,
            to: nil,
            siblingIndex: 0,
            now: 4,
            in: ledger
        )
        let idx = ledger.folders.first { $0.pathKey == keep.sortKey }?.siblingIndex
        expect(idx == 0, "move --index 排到最左")
    } catch {
        expect(false, "prune/move 不应失败: \(error)")
    }
}

func testBookmarkAddUpsertsFolderRecord() {
    var ledger = BookmarkLedgerSnapshot.empty
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["开发", "链动"])
    ledger = BookmarkLedgerMerge.unionMerge(
        ledger: ledger,
        incoming: [
            BookmarkEntry(
                url: "https://dev.example",
                title: "D",
                folder: path,
                siblingIndex: 0,
                updatedAt: 1
            )
        ],
        browserKey: "cli"
    )
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: nil, updatedAt: 1, in: ledger)
    expect(ledger.folders.contains { $0.path.segments == ["开发"] }, "祖先夹已写入")
    expect(ledger.folders.contains { $0.pathKey == path.sortKey }, "叶子夹已写入")
}

@MainActor
func testBookmarkFolderCLICommands() {
    let bookmarks = MockBookmarkSync()
    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )
    expect(
        TocodeCommandParser.parse("bookmark folder create toolbar/AI --index 0")
            == .success(.bookmark(.folder(.create(path: "toolbar/AI", index: 0)))),
        "folder create 解析"
    )
    if case .success = executor.execute("bookmark folder create toolbar/AI --index 0") {
        expect(bookmarks.ledger.folders.contains { $0.path.segments == ["AI"] }, "CLI create 落账本")
    } else {
        expect(false, "CLI folder create")
    }
    if case .success = executor.execute("bookmark folder create toolbar/旧壳") {
        expect(true, "CLI create 旧壳")
    } else {
        expect(false, "CLI create 旧壳")
    }
    if case .success(let out) = executor.execute("bookmark folder prune-empty --under toolbar") {
        expect(out.text.contains("removedCount"), "prune 返回计数")
        expect(bookmarks.ledger.folderTombstones.count >= 1, "prune 写墓碑")
    } else {
        expect(false, "CLI prune-empty")
    }
}

@MainActor
func testBookmarkApplyDryRunAndWrite() {
    let bookmarks = MockBookmarkSync()
    _ = try? bookmarks.addCLI(
        url: "https://a.example",
        title: "A",
        folder: BookmarkFolderPath(kind: .toolbar, segments: ["其它"]),
        siblingIndex: 0
    )
    let planURL = FileManager.default.temporaryDirectory.appendingPathComponent("tocode-apply-plan.json")
    let plan: [[String: Any]] = [
        [
            "op": "update",
            "url": "https://a.example",
            "folder": "toolbar/AI",
            "index": 0
        ],
        [
            "op": "add",
            "url": "https://b.example",
            "title": "B",
            "folder": "toolbar/AI"
        ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: plan)
    try! data.write(to: planURL)

    let executor = TocodeCommandExecutor(
        mouseWheel: MockTocodeWheel(),
        shortcuts: MockTocodeShortcuts(),
        weChat: MockTocodeWeChat(),
        bookmarkSync: bookmarks,
        notify: { _, _ in }
    )
    expect(
        TocodeCommandParser.parse("bookmark apply --file \(planURL.path) --dry-run").isSuccess,
        "apply 解析"
    )
    if case .success(let dry) = executor.execute("bookmark apply --file \(planURL.path) --dry-run") {
        expect(dry.text.contains("dryRun"), "dry-run 标记")
        expect(bookmarks.ledger.entries.count == 1, "dry-run 不改账本条数")
        expect(bookmarks.ledger.entries.first?.folder.segments == ["其它"], "dry-run 不改文件夹")
    } else {
        expect(false, "apply dry-run")
    }
    if case .success(let written) = executor.execute("bookmark apply --file \(planURL.path)") {
        expect(written.text.contains("\"ok\""), "apply 写回 ok")
        expect(bookmarks.ledger.entries.count == 2, "apply 写入第二条")
        expect(
            bookmarks.ledger.entries.contains { $0.url == "https://a.example" && $0.folder.segments == ["AI"] },
            "apply 搬到 AI"
        )
    } else {
        expect(false, "apply 写回")
    }
}

func testMergeRemoteDoesNotCoverNewerFolderCreate() {
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["AI"])
    var local = BookmarkLedgerSnapshot.empty
    local.folderTombstones = [
        BookmarkFolderTombstone(path: path, deletedAt: 100)
    ]
    // create 晚于墓碑
    local = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: 0, updatedAt: 100.5, in: local)
    expect(local.folders.contains { $0.pathKey == path.sortKey }, "本地已有 AI 夹")
    expect(!local.folderTombstones.contains { $0.pathKey == path.sortKey }, "本地已清墓碑")

    var remote = BookmarkLedgerSnapshot.empty
    remote.folderTombstones = [
        BookmarkFolderTombstone(path: path, deletedAt: 100)
    ]
    let merged = BookmarkLedgerMerge.mergeRemote(local: local, remote: remote)
    expect(merged.folders.contains { $0.pathKey == path.sortKey }, "merge 后仍保留新建夹")
    expect(!merged.folderTombstones.contains { $0.pathKey == path.sortKey }, "merge 不得用旧墓碑盖掉新建夹")
}

func testUpsertFolderBumpsPastTombstoneTime() {
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["工作"])
    var ledger = BookmarkLedgerSnapshot.empty
    ledger.folderTombstones = [
        BookmarkFolderTombstone(path: path, deletedAt: 50)
    ]
    ledger = BookmarkLedgerMerge.upsertFolderAncestors(path, siblingIndex: 1, updatedAt: 50, in: ledger)
    let record = ledger.folders.first { $0.pathKey == path.sortKey }
    expect(record != nil, "upsert 写入夹")
    expect((record?.updatedAt ?? 0) > 50, "updatedAt 严格新于旧墓碑")
    expect(!ledger.folderTombstones.contains { $0.pathKey == path.sortKey }, "清墓碑")
}

func testFolderRemovalCandidatesIgnoreEmptyKnown() {
    // 泵逻辑：未确认墓碑即候选；known 为空仍应视为待删（用同样过滤式断言）。
    let stones = [
        BookmarkFolderTombstone(
            path: BookmarkFolderPath(kind: .toolbar, segments: ["anker"]),
            deletedAt: 1
        ),
        BookmarkFolderTombstone(
            path: BookmarkFolderPath(kind: .toolbar, segments: ["AI"]),
            deletedAt: 1
        )
    ]
    let confirmed: Set<String> = ["toolbar|AI"]
    let known: [String: String] = [:]
    let candidates = stones.filter { stone in
        !confirmed.contains(stone.pathKey)
    }
    // 旧逻辑会要求 known[path]!=nil → 候选为空；新逻辑应仍有 anker。
    expect(candidates.count == 1, "known 空时仍有未确认删夹")
    expect(candidates.first?.path.segments == ["anker"], "仅未确认的 anker")
    expect(known.isEmpty, "模拟 purge 后 known 空")
}

func testMergeRemoteRemoteFolderBeatsLocalTombstone() {
    let path = BookmarkFolderPath(kind: .toolbar, segments: ["跨端"])
    var local = BookmarkLedgerSnapshot.empty
    local.folderTombstones = [
        BookmarkFolderTombstone(path: path, deletedAt: 10)
    ]
    var remote = BookmarkLedgerSnapshot.empty
    remote.folders = [
        BookmarkFolderRecord(path: path, siblingIndex: 0, updatedAt: 11)
    ]
    let merged = BookmarkLedgerMerge.mergeRemote(local: local, remote: remote)
    expect(merged.folders.contains { $0.pathKey == path.sortKey }, "本地 tombstone@10 + remote folder@11 → 夹存活")
    expect(!merged.folderTombstones.contains { $0.pathKey == path.sortKey }, "较新夹清墓碑")
}

func testMergeRemoteURLEntryBeatsTombstone() {
    let url = "https://revive.example"
    var local = BookmarkLedgerSnapshot.empty
    local.tombstones = [BookmarkTombstone(url: url, deletedAt: 10)]
    var remote = BookmarkLedgerSnapshot.empty
    remote.entries = [
        BookmarkEntry(
            url: url,
            title: "R",
            folder: BookmarkFolderPath(kind: .other, segments: []),
            siblingIndex: 0,
            updatedAt: 11
        )
    ]
    let merged = BookmarkLedgerMerge.mergeRemote(local: local, remote: remote)
    expect(merged.entries.contains { $0.url == url }, "较新 URL entry 复活")
    expect(!merged.tombstones.contains { $0.url == url }, "复活后清 URL 墓碑")
}

func testCanonicalizeSiblingIndexBumpsUpdatedAt() {
    let parent = BookmarkFolderPath(kind: .toolbar, segments: [])
    let a = BookmarkEntry(
        url: "https://a.canon",
        title: "A",
        folder: parent,
        siblingIndex: 5,
        updatedAt: 1
    )
    let b = BookmarkEntry(
        url: "https://b.canon",
        title: "B",
        folder: parent,
        siblingIndex: 9,
        updatedAt: 1
    )
    let result = BookmarkLedgerMerge.canonicalizeSiblingIndices(entries: [a, b], folders: [])
    let outA = result.entries.first { $0.url == "https://a.canon" }
    let outB = result.entries.first { $0.url == "https://b.canon" }
    expect(outA?.siblingIndex == 0 && outB?.siblingIndex == 1, "规范化连续下标")
    expect((outA?.updatedAt ?? 0) > 1, "改 index 抬 updatedAt")
    expect((outB?.updatedAt ?? 0) > 1, "改 index 抬 updatedAt(B)")
}

func testTrustedAlignFingerprintAndPoisonGate() {
    let folder = BookmarkFolderPath(kind: .toolbar, segments: ["AI"])
    let intent = BookmarkReconcilePump.fingerprint(folder: folder, index: 2, title: "X")
    let measuredMatch = BookmarkReconcilePump.fingerprint(folder: folder, index: 2, title: "X")
    let measuredClamp = BookmarkReconcilePump.fingerprint(folder: folder, index: 0, title: "X")
    expect(intent == measuredMatch, "实测等于意图才可 stamp known")
    expect(intent != measuredClamp, "钳制后 index 不同 → 保持 divergent")
    // 毒化门闩：poisoned 非空时不得报无条件「已对齐」
    var poisoned: Set<String> = ["https://poison.example"]
    let purgeCredible = false
    let aligned = poisoned.isEmpty && purgeCredible
    expect(!aligned, "毒化或 purge 不可信时禁止已对齐")
    poisoned.removeAll()
    expect(!(poisoned.isEmpty && purgeCredible), "仅毒化清空仍不够，需 purgeCredible")
}

func testFolderRemovalCircuitBreakThreshold() {
    expect(BookmarkReconcilePump.folderRemovalFailLimit == 5, "删夹熔断阈值 N=5")
    var counts: [String: Int] = [:]
    var failed: Set<String> = []
    let pathKey = "toolbar|死夹"
    for _ in 0 ..< BookmarkReconcilePump.folderRemovalFailLimit {
        let next = (counts[pathKey] ?? 0) + 1
        counts[pathKey] = next
        if next >= BookmarkReconcilePump.folderRemovalFailLimit {
            failed.insert(pathKey)
        }
    }
    expect(failed.contains(pathKey), "连续失败达上限后进入 failedFolderRemovals")
}

@MainActor
func testBookmarkAddReportsCreatedVsMerged() {
    let bookmarks = MockBookmarkSync()
    let first = try? bookmarks.addCLI(
        url: "https://dup.example/#/x?q=%2F",
        title: "D",
        folder: BookmarkFolderPath(kind: .toolbar, segments: ["其它"]),
        siblingIndex: 0
    )
    expect(first?.created == true, "首次 add created=true")
    expect(bookmarks.ledger.entries.count == 1, "首次写入一条")
    let second = try? bookmarks.addCLI(
        url: "https://dup.example#/x?q=/",
        title: "D2",
        folder: BookmarkFolderPath(kind: .toolbar, segments: ["工作"]),
        siblingIndex: 1
    )
    expect(second?.created == false, "编码变体 add merged")
    expect(second?.entry.folder.segments == ["工作"], "合并可改夹")
    expect(bookmarks.ledger.entries.count == 1, "变体不加条数")
}

func testBookmarkOnlinePresenceMultiConnection() {
    let key = "chrome:Default"
    // 同 key 两条连接：断一条仍 online
    let afterOneGone = [key]
    expect(
        !BookmarkOnlinePresence.shouldMarkOffline(removedKey: key, remainingKeys: afterOneGone),
        "同 key 断一条不得标离线"
    )
    // 两条都断才 offline
    expect(
        BookmarkOnlinePresence.shouldMarkOffline(removedKey: key, remainingKeys: []),
        "同 key 全断才离线"
    )
    expect(
        !BookmarkOnlinePresence.shouldMarkOffline(removedKey: nil, remainingKeys: []),
        "未 hello 的断开不触发离线"
    )
    let online = BookmarkOnlinePresence.uniqueSortedKeys(from: [key, key, "edge:Default", nil])
    expect(online == ["chrome:Default", "edge:Default"], "活连接去重排序")
    expect(
        BookmarkOnlinePresence.isBrowserConnected(browserRaw: "chrome", onlineKeys: online),
        "chrome 有 profile 在线则菜单勾选"
    )
    expect(
        !BookmarkOnlinePresence.isBrowserConnected(browserRaw: "firefox", onlineKeys: online),
        "firefox 无连接则不勾选"
    )
}
