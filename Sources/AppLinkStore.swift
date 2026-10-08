import Foundation

final class AppLinkStore {
    let directory: URL
    private let fileManager: FileManager
    private let configURL: URL
    private let linksURL: URL
    private let historyDirectory: URL

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent("com.tocode.app", isDirectory: true)
        }
        configURL = self.directory.appendingPathComponent("app-relay.json")
        linksURL = self.directory.appendingPathComponent("app-links.json")
        historyDirectory = self.directory.appendingPathComponent("app-link-history", isDirectory: true)
    }

    func loadConfig() -> AppRelayConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppRelayConfig.self, from: data) else {
            return AppRelayConfig()
        }
        return config
    }

    func saveConfig(_ config: AppRelayConfig) throws {
        try write(config, to: configURL)
    }

    func loadFile() -> AppLinkFile {
        guard let data = try? Data(contentsOf: linksURL),
              let file = try? JSONDecoder().decode(AppLinkFile.self, from: data) else {
            return AppLinkFile()
        }
        return file
    }

    func saveFile(_ file: AppLinkFile) throws {
        try write(file, to: linksURL)
    }

    func appendHistory(linkID: String, text: String, outgoing: Bool) {
        let safe = linkID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safe.isEmpty else { return }
        do {
            try fileManager.createDirectory(
                at: historyDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let url = historyDirectory.appendingPathComponent("\(safe).jsonl")
            let line = #"{"outgoing":\#(outgoing),"text":\#(jsonString(text))}"# + "\n"
            if fileManager.fileExists(atPath: url.path),
               let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else if let data = line.data(using: .utf8) {
                try data.write(to: url, options: .atomic)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("Tocode 应用关联历史写入失败")
        }
    }

    func historyURL(linkID: String) -> URL {
        let safe = linkID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return historyDirectory.appendingPathComponent("\(safe).jsonl")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func jsonString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        guard let data, let wrapped = String(data: data, encoding: .utf8), wrapped.count >= 2 else {
            return "\"\""
        }
        return String(wrapped.dropFirst().dropLast())
    }
}
