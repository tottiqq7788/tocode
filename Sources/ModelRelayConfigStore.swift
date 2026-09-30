import Foundation

protocol ModelRelayConfigStoring: AnyObject {
    func load() throws -> ModelRelayConfiguration
    func save(_ configuration: ModelRelayConfiguration) throws
}

final class FileModelRelayConfigStore: ModelRelayConfigStoring {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.tocode.app", isDirectory: true)
            .appendingPathComponent("model-relay.json", isDirectory: false)
    }

    func load() throws -> ModelRelayConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ModelRelayConfiguration()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let configuration = try Self.decoder.decode(ModelRelayConfiguration.self, from: data)
            guard configuration.version == ModelRelayConfiguration.currentVersion else {
                throw ModelRelayError.configurationVersion
            }
            return configuration
        } catch let error as ModelRelayError {
            throw error
        } catch {
            throw ModelRelayError.configurationCorrupt
        }
    }

    func save(_ configuration: ModelRelayConfiguration) throws {
        guard configuration.version == ModelRelayConfiguration.currentVersion else {
            throw ModelRelayError.configurationVersion
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let data = try Self.encoder.encode(configuration)
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tocode-\(UUID().uuidString)",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw ModelRelayError.configurationCorrupt
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
