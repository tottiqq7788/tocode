import AppKit

struct BookmarkMenuNode: Equatable {
    var title: String
    /// 非 nil 时这一项是可打开的网址，不再展开。
    var url: String?
    var children: [BookmarkMenuNode]
}

enum BookmarkMenuModel {
    static func roots(from snapshot: BookmarkLedgerSnapshot) -> [BookmarkMenuNode] {
        var nodes: [BookmarkMenuNode] = []
        for kind in [BookmarkFolderKind.toolbar, .other, .mobile] {
            let children = children(of: BookmarkFolderPath(kind: kind, segments: []), in: snapshot)
            guard !children.isEmpty else { continue }
            nodes.append(BookmarkMenuNode(title: rootTitle(kind), url: nil, children: children))
        }
        nodes.append(contentsOf: children(of: BookmarkFolderPath(kind: .named, segments: []), in: snapshot))
        return nodes
    }

    private static func rootTitle(_ kind: BookmarkFolderKind) -> String {
        switch kind {
        case .toolbar:
            return "书签栏"
        case .other:
            return "其他书签"
        case .mobile:
            return "移动设备书签"
        case .named:
            return "其他文件夹"
        }
    }

    private static func children(
        of parent: BookmarkFolderPath,
        in snapshot: BookmarkLedgerSnapshot
    ) -> [BookmarkMenuNode] {
        struct Piece {
            var index: Int
            var tie: Int
            var title: String
            var node: BookmarkMenuNode
        }

        let prefix = parent.segments
        var pieces: [Piece] = []
        var folderNames = Set<String>()

        func childName(_ segments: [String]) -> String? {
            guard segments.count == prefix.count + 1 else { return nil }
            guard Array(segments.dropLast()) == prefix else { return nil }
            return segments.last
        }

        for folder in snapshot.folders where folder.path.kind == parent.kind {
            guard let name = childName(folder.path.segments), !folderNames.contains(name) else { continue }
            folderNames.insert(name)
            let path = BookmarkFolderPath(kind: parent.kind, segments: prefix + [name])
            pieces.append(Piece(
                index: folder.siblingIndex,
                tie: 0,
                title: name,
                node: BookmarkMenuNode(
                    title: name,
                    url: nil,
                    children: children(of: path, in: snapshot)
                )
            ))
        }

        var implicitIndex: [String: Int] = [:]
        for entry in snapshot.entries where entry.folder.kind == parent.kind {
            let segments = entry.folder.segments
            guard segments.count > prefix.count, Array(segments.prefix(prefix.count)) == prefix else { continue }
            let name = segments[prefix.count]
            guard !folderNames.contains(name) else { continue }
            implicitIndex[name] = min(implicitIndex[name] ?? entry.siblingIndex, entry.siblingIndex)
        }
        for (name, index) in implicitIndex {
            let path = BookmarkFolderPath(kind: parent.kind, segments: prefix + [name])
            pieces.append(Piece(
                index: index,
                tie: 0,
                title: name,
                node: BookmarkMenuNode(
                    title: name,
                    url: nil,
                    children: children(of: path, in: snapshot)
                )
            ))
        }

        for entry in snapshot.entries where entry.folder == parent {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = title.isEmpty ? entry.url : title
            pieces.append(Piece(
                index: entry.siblingIndex,
                tie: 1,
                title: shown,
                node: BookmarkMenuNode(title: shown, url: entry.url, children: [])
            ))
        }

        return pieces
            .sorted { lhs, rhs in
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                if lhs.tie != rhs.tie { return lhs.tie < rhs.tie }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map(\.node)
    }
}

enum BookmarkMenuBuilder {
    @MainActor
    static func fill(
        _ menu: NSMenu,
        snapshot: BookmarkLedgerSnapshot,
        target: AnyObject,
        action: Selector
    ) {
        let roots = BookmarkMenuModel.roots(from: snapshot)
        if roots.isEmpty {
            let empty = NSMenuItem(title: "没有书签", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for node in roots {
            menu.addItem(item(for: node, target: target, action: action))
        }
    }

    @MainActor
    private static func item(
        for node: BookmarkMenuNode,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        if let url = node.url {
            let item = NSMenuItem(title: node.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = url
            item.toolTip = url
            item.image = NSImage(systemSymbolName: "link", accessibilityDescription: node.title)
            return item
        }
        let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: node.title)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if node.children.isEmpty {
            let empty = NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for child in node.children {
                submenu.addItem(self.item(for: child, target: target, action: action))
            }
        }
        item.submenu = submenu
        return item
    }
}
