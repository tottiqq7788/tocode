import Foundation

enum BookmarkCLIFolder {
    static func parse(_ raw: String?) -> Result<BookmarkFolderPath?, TocodeCommandError> {
        guard let raw else { return .success(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidArguments("bookmark --folder"))
        }
        let lower = trimmed.lowercased()
        switch lower {
        case "toolbar", "bar", "书签栏":
            return .success(BookmarkFolderPath(kind: .toolbar, segments: []))
        case "other", "其他", "其他书签":
            return .success(BookmarkFolderPath(kind: .other, segments: []))
        case "mobile", "移动", "移动设备书签":
            return .success(BookmarkFolderPath(kind: .mobile, segments: []))
        default:
            var path = trimmed
            if path.lowercased().hasPrefix("named:") {
                path = String(path.dropFirst(6))
            }
            let segments = path
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !segments.isEmpty else {
                return .failure(.invalidArguments("bookmark --folder"))
            }
            return .success(BookmarkFolderPath(kind: .named, segments: segments))
        }
    }

    static func encode(_ folder: BookmarkFolderPath) -> [String: Any] {
        [
            "kind": folder.kind.rawValue,
            "segments": folder.segments
        ]
    }
}

enum BookmarkCLIJSON {
    static func entry(_ entry: BookmarkEntry) -> [String: Any] {
        [
            "id": entry.id,
            "url": entry.url,
            "title": entry.title,
            "folder": BookmarkCLIFolder.encode(entry.folder),
            "updatedAt": entry.updatedAt
        ]
    }

    static func encode(_ value: Any) -> Result<String, TocodeCommandError> {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(.operationFailed("无法编码书签 JSON"))
        }
        return .success(text)
    }
}

protocol BookmarkSyncCommanding: AnyObject {
    var isRemoteEnabled: Bool { get }
    var hasRemoteKey: Bool { get }
    var connectedBrowserKeys: [String] { get }
    var snapshot: BookmarkLedgerSnapshot { get }

    func entry(url: String) -> BookmarkEntry?
    func addCLI(url: String, title: String?, folder: BookmarkFolderPath?) throws -> BookmarkEntry
    func updateCLI(url: String, title: String?, folder: BookmarkFolderPath?, newURL: String?) throws -> BookmarkEntry
    func deleteCLI(url: String) throws
    func pullRemoteForCLI() async -> Result<BookmarkLedgerSnapshot, Error>
}

@MainActor
extension BookmarkSyncService: BookmarkSyncCommanding {}
