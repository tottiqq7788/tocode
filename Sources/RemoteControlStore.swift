import Foundation

struct RemoteControlStore {
    let fileURL: URL

    static var live: RemoteControlStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RemoteControlStore(
            fileURL: base.appendingPathComponent("com.tocode.app/remote-control.json")
        )
    }

    func load() -> RemoteControlRecord {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(RemoteControlRecord.self, from: data) else {
            return .empty
        }
        return record
    }

    func save(_ record: RemoteControlRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}
