import Foundation

struct ModelAutomation: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var prompt: String
    var modelAlias: String
}

struct ModelAutomationDraft: Equatable {
    var id: UUID?
    var name: String
    var prompt: String
    var modelAlias: String?

    init(
        id: UUID? = nil,
        name: String = "",
        prompt: String = "",
        modelAlias: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.modelAlias = modelAlias
    }

    init(automation: ModelAutomation) {
        id = automation.id
        name = automation.name
        prompt = automation.prompt
        modelAlias = automation.modelAlias
    }
}

enum ModelAutomationValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName
    case emptyPrompt
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入名称。"
        case .duplicateName:
            return "该名称已存在，请使用其他名称。"
        case .emptyPrompt:
            return "请输入提示词。"
        case .modelUnavailable:
            return "请先在「厂家」里配置可用模型。"
        }
    }
}

enum ModelAutomationError: Error, Equatable, LocalizedError {
    case emptyResponse
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "模型没有返回可粘贴的正文。"
        case .modelUnavailable:
            return "所选模型当前不可用。"
        }
    }
}

enum ModelAutomationLookup {
    static var name: (UUID) -> String? = { id in
        ModelAutomationStore().automation(id: id)?.name
    }
}

enum ModelAutomationResponse {
    /// 只取助手正文。不读取思考字段，也不把原始响应交给调用方。
    static func assistantText(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            return nil
        }
        return text(from: message["content"])
    }

    private static func text(from content: Any?) -> String? {
        if let string = content as? String {
            return nonempty(string)
        }
        guard let parts = content as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return nonempty(joined)
    }

    private static func nonempty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ModelAutomationStore {
    static let defaultsKey = "tocode.modelAutomations"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func all() -> [ModelAutomation] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ModelAutomation].self, from: data)) ?? []
    }

    func automation(id: UUID) -> ModelAutomation? {
        all().first { $0.id == id }
    }

    func save(
        _ draft: ModelAutomationDraft,
        availableAliases: Set<String>
    ) -> Result<ModelAutomation, ModelAutomationValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !prompt.isEmpty else { return .failure(.emptyPrompt) }
        let alias = draft.modelAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !alias.isEmpty else { return .failure(.modelUnavailable) }

        var items = all()
        let existing = items.first { $0.id == draft.id }
        let modelAllowed = availableAliases.contains(alias) || existing?.modelAlias == alias
        guard modelAllowed else { return .failure(.modelUnavailable) }

        let others = items.filter { $0.id != draft.id }
        if others.contains(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .failure(.duplicateName)
        }

        let saved = ModelAutomation(
            id: draft.id ?? UUID(),
            name: name,
            prompt: prompt,
            modelAlias: alias
        )
        if let index = items.firstIndex(where: { $0.id == saved.id }) {
            items[index] = saved
        } else {
            items.append(saved)
        }
        persist(items)
        return .success(saved)
    }

    func delete(id: UUID) {
        persist(all().filter { $0.id != id })
    }

    private func persist(_ items: [ModelAutomation]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
