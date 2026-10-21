import Foundation

/// Tocode 自己记住「哪个会话属于哪个项目」。不写入 Hermes 正在看的那条会话。
final class PhoneHermesSessionIndex {
    private let fileURL: URL
    private var tree: [String: [String: [String]]]

    init(fileURL: URL = PhoneHermesSessionIndex.applicationSupportURL()) {
        self.fileURL = fileURL
        tree = Self.read(fileURL)
    }

    static func applicationSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.tocode.app/phone-hermes-sessions.json")
    }

    func sessionIDs(profile: String, projectID: String) -> [String] {
        tree[profile]?[projectID] ?? []
    }

    func projectID(profile: String, sessionID: String) -> String? {
        for (project, ids) in tree[profile] ?? [:] where ids.contains(sessionID) {
            return project
        }
        return nil
    }

    func remember(profile: String, projectID: String, sessionID: String) {
        var projects = tree[profile] ?? [:]
        var ids = projects[projectID] ?? []
        ids.removeAll { $0 == sessionID }
        ids.insert(sessionID, at: 0)
        projects[projectID] = ids
        tree[profile] = projects
        write()
    }

    func forget(profile: String, sessionID: String) {
        var projects = tree[profile] ?? [:]
        for (project, ids) in projects {
            projects[project] = ids.filter { $0 != sessionID }
        }
        tree[profile] = projects
        write()
    }

    private func write() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func read(_ url: URL) -> [String: [String: [String]]] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [String]]] else {
            return [:]
        }
        return raw
    }
}
