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
    expect(ledger.entries[0].folder.kind == .toolbar, "文件夹优先书签栏")
    expect(ledger.entries[0].title == "A2", "标题取较新")
    expect(ledger.joinedBrowserKeys == ["chrome:Default"], "记录已加入浏览器")

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
        updatedAt: 5,
        in: ledger
    )
    expect(ledger.entries.count == 1, "撞车后只留一条")
    expect(ledger.entries[0].url == "https://new.com", "保留目标网址")
    expect(ledger.tombstones.contains { $0.url == "https://old.com" }, "旧网址进墓碑")
    expect(ledger.entries[0].title == "Changed", "较新标题写入已存在条")
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
