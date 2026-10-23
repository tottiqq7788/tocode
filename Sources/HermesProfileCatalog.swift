import Foundation

/// 只列出本机已经存在的 Hermes 档案。不新建、不删除。
enum HermesProfileCatalog {
    static let idPattern = #"^[a-z0-9][a-z0-9_-]{0,63}$"#
    static let markers = ["config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db"]

    static func names(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [String] {
        names(
            home: home,
            isDirectory: { path in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            fileExists: { fileManager.fileExists(atPath: $0) },
            childNames: { path in
                (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            }
        )
    }

    static func names(
        home: String,
        isDirectory: (String) -> Bool,
        fileExists: (String) -> Bool,
        childNames: (String) -> [String]
    ) -> [String] {
        let root = (home as NSString).appendingPathComponent(".hermes")
        var result: [String] = []
        if isDirectory(root) { result.append("default") }
        let profiles = (root as NSString).appendingPathComponent("profiles")
        guard isDirectory(profiles) else { return result }
        let deleted = (profiles as NSString).appendingPathComponent(".deleted")
        let named = childNames(profiles).filter { name in
            guard isSafe(name), name != "default", isDirectory((profiles as NSString).appendingPathComponent(name)) else {
                return false
            }
            if fileExists((deleted as NSString).appendingPathComponent(name)) { return false }
            return markers.contains { marker in
                fileExists((profiles as NSString).appendingPathComponent("\(name)/\(marker)"))
            }
        }.sorted()
        result.append(contentsOf: named)
        return result
    }

    static func isSafe(_ name: String) -> Bool {
        name == "default" || name.range(of: idPattern, options: .regularExpression) != nil
    }

    /// 不在清单里、或名字不能安全放进路径时，回到 default。
    static func accepted(_ raw: String, among names: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "default" : trimmed
        let pool = names.isEmpty ? ["default"] : names
        guard pool.contains(candidate), isSafe(candidate) else { return "default" }
        return candidate
    }

    /// default 保持现有无前缀接口。非法名字返回空，避免被拼进 URL。
    static func prefix(for name: String) -> String {
        guard name != "default", isSafe(name), !name.contains("/"), !name.contains("..") else { return "" }
        return "/p/\(name)"
    }

    static func home(userHome: String, profile: String) -> String {
        let root = (userHome as NSString).appendingPathComponent(".hermes")
        guard profile != "default", isSafe(profile) else { return root }
        return (root as NSString).appendingPathComponent("profiles/\(profile)")
    }

    static func envURL(userHome: String, profile: String) -> URL {
        URL(fileURLWithPath: (home(userHome: userHome, profile: profile) as NSString).appendingPathComponent(".env"))
    }

    static let modelValuePattern = #"^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,199}$"#
    static let providerValuePattern = #"^[a-z0-9][a-z0-9_-]{0,63}$"#

    /// 只读这个档案 config.yaml 里 model.default。读不到、写了不止一处、或内容不像模型名时返回空。不返回密钥。
    static func configuredModel(userHome: String, profile: String, read: (String) -> String = { path in
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }) -> String {
        let path = (home(userHome: userHome, profile: profile) as NSString).appendingPathComponent("config.yaml")
        return modelName(in: read(path))
    }

    static func configuredProvider(userHome: String, profile: String, read: (String) -> String = { path in
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }) -> String {
        let path = (home(userHome: userHome, profile: profile) as NSString).appendingPathComponent("config.yaml")
        return providerName(in: read(path))
    }

    static func modelName(in yaml: String) -> String {
        modelField(named: "default", in: yaml, pattern: modelValuePattern)
    }

    static func providerName(in yaml: String) -> String {
        modelField(named: "provider", in: yaml, pattern: providerValuePattern)
    }

    /// 只改 model.default 与 model.provider；换 provider 时去掉自定义 base_url，让 Hermes 用该 provider 默认地址。不碰密钥行。
    static func setConfiguredModel(
        userHome: String,
        profile: String,
        model: String,
        provider: String,
        read: (String) -> String = { path in
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        },
        write: (String, String) throws -> Void = { path, text in
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    ) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.range(of: modelValuePattern, options: .regularExpression) != nil else {
            throw PhoneHermesModelConfigError.invalidModel
        }
        guard trimmedProvider.range(of: providerValuePattern, options: .regularExpression) != nil else {
            throw PhoneHermesModelConfigError.invalidProvider
        }
        let path = (home(userHome: userHome, profile: profile) as NSString).appendingPathComponent("config.yaml")
        let raw = read(path)
        guard !raw.isEmpty else { throw PhoneHermesModelConfigError.missingConfig }
        let updated = try applyingModel(model: trimmedModel, provider: trimmedProvider, to: raw)
        try write(path, updated)
    }

    static func applyingModel(model: String, provider: String, to yaml: String) throws -> String {
        var lines = yaml.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].range(of: #"^model\s*:"#, options: .regularExpression) != nil }
        guard starts.count == 1, let start = starts.first,
              lines[start].range(of: #"^model:\s*(?:#.*)?$"#, options: .regularExpression) != nil else {
            throw PhoneHermesModelConfigError.ambiguousModelBlock
        }
        let end = ((start + 1)..<lines.count).first { line in
            let text = lines[line]
            return !text.isEmpty && !text.hasPrefix(" ") && !text.hasPrefix("\t") && !text.hasPrefix("#")
        } ?? lines.count
        var defaultAt: Int?
        var providerAt: Int?
        var baseURLAt: Int?
        for index in (start + 1)..<end {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.range(of: #"^  default:"#, options: .regularExpression) != nil {
                if defaultAt != nil { throw PhoneHermesModelConfigError.ambiguousModelBlock }
                defaultAt = index
            } else if line.range(of: #"^  provider:"#, options: .regularExpression) != nil {
                if providerAt != nil { throw PhoneHermesModelConfigError.ambiguousModelBlock }
                providerAt = index
            } else if line.range(of: #"^  base_url:"#, options: .regularExpression) != nil {
                baseURLAt = index
            }
        }
        let previousProvider = providerAt.flatMap { fieldValue(in: lines[$0]) } ?? ""
        if let defaultAt {
            lines[defaultAt] = "  default: \(model)"
        } else {
            lines.insert("  default: \(model)", at: start + 1)
        }
        // Re-scan after possible insert.
        let starts2 = lines.indices.filter { lines[$0].range(of: #"^model\s*:"#, options: .regularExpression) != nil }
        guard let start2 = starts2.first else { throw PhoneHermesModelConfigError.ambiguousModelBlock }
        let end2 = ((start2 + 1)..<lines.count).first { line in
            let text = lines[line]
            return !text.isEmpty && !text.hasPrefix(" ") && !text.hasPrefix("\t") && !text.hasPrefix("#")
        } ?? lines.count
        defaultAt = nil
        providerAt = nil
        baseURLAt = nil
        for index in (start2 + 1)..<end2 {
            let line = lines[index]
            if line.range(of: #"^  default:"#, options: .regularExpression) != nil { defaultAt = index }
            else if line.range(of: #"^  provider:"#, options: .regularExpression) != nil { providerAt = index }
            else if line.range(of: #"^  base_url:"#, options: .regularExpression) != nil { baseURLAt = index }
        }
        if let providerAt {
            lines[providerAt] = "  provider: \(provider)"
        } else {
            let insertAt = (defaultAt ?? start2) + 1
            lines.insert("  provider: \(provider)", at: insertAt)
            if let base = baseURLAt, base >= insertAt { baseURLAt = base + 1 }
        }
        if previousProvider != provider, let baseURLAt {
            lines.remove(at: baseURLAt)
        }
        return lines.joined(separator: "\n")
    }

    private static func modelField(named name: String, in yaml: String, pattern: String) -> String {
        let lines = yaml.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].range(of: #"^model\s*:"#, options: .regularExpression) != nil }
        guard starts.count == 1, let start = starts.first,
              lines[start].range(of: #"^model:\s*(?:#.*)?$"#, options: .regularExpression) != nil else { return "" }
        let end = ((start + 1)..<lines.count).first { line in
            let text = lines[line]
            return !text.isEmpty && !text.hasPrefix(" ") && !text.hasPrefix("\t") && !text.hasPrefix("#")
        } ?? lines.count
        var found: Int?
        for index in (start + 1)..<end {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard line.range(of: "^  \(name):", options: .regularExpression) != nil else { continue }
            if found != nil { return "" }
            found = index
        }
        guard let found else { return "" }
        let value = fieldValue(in: lines[found])
        guard value.range(of: pattern, options: .regularExpression) != nil else { return "" }
        return value
    }

    private static func fieldValue(in line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") || value.hasPrefix("'") {
            let mark = value.first!
            guard value.count >= 2, value.hasSuffix(String(mark)) else { return "" }
            value = String(value.dropFirst().dropLast())
        } else if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}

enum PhoneHermesModelConfigError: Error {
    case invalidModel
    case invalidProvider
    case missingConfig
    case ambiguousModelBlock
}
