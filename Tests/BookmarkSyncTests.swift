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
    expect(ledger.entries[0].siblingIndex == 5, "较新 siblingIndex 胜出")
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
        BookmarkBrowser.firefox.extensionPageURL.absoluteString
            == "about:debugging#/runtime/this-firefox",
        "Firefox 扩展页"
    )
    expect(BookmarkBrowser.chrome.applicationNames.first == "Google Chrome", "Chrome 优先应用名")
    expect(BookmarkBrowser.edge.applicationNames == ["Microsoft Edge"], "Edge 应用名")
    expect(BookmarkBrowser.firefox.applicationNames.contains("Firefox"), "Firefox 应用名")
    expect(
        BookmarkBrowser.firefox.extensionPageURL.absoluteString.hasPrefix("about:debugging"),
        "Firefox 用 about:debugging 而非 about:addons"
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
    expect(TocodeCommandParser.helpText.contains("bookmark list"), "help 含 bookmark")
    expect(TocodeCommandParser.parse("bookmark add").isFailure, "bookmark add 缺 url 失败")
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
