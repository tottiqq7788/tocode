import AppKit

@MainActor
enum ModelRelayPrompts {
    struct ProviderPreset: Equatable, Sendable {
        let title: String
        let baseURL: String
    }

    struct ProviderDraft: Equatable {
        let providerID: UUID?
        let originalBaseURL: String?
        let hasStoredKey: Bool
        var name: String
        var presetIndex: Int?
        var customBaseURL: String
        var secret: String

        func resolvedBaseURL() throws -> String {
            let raw: String
            if let presetIndex,
               ModelRelayPrompts.providerPresets.indices.contains(presetIndex) {
                raw = ModelRelayPrompts.providerPresets[presetIndex].baseURL
            } else {
                raw = customBaseURL
            }
            return try ModelRelayValidation.normalizedBaseURL(raw)
        }

        func requiresConnectionTest() -> Bool {
            guard let resolved = try? resolvedBaseURL() else { return true }
            return providerID == nil
                || !hasStoredKey
                || !secret.isEmpty
                || resolved != originalBaseURL
        }

        func isReadyToTest() -> Bool {
            guard (try? resolvedBaseURL()) != nil else { return false }
            if providerID == nil || !hasStoredKey {
                return Self.isValidSecret(secret)
            }
            return secret.isEmpty || Self.isValidSecret(secret)
        }

        func canSave(using test: ModelRelayProviderConnectionTest?) -> Bool {
            guard (try? ModelRelayValidation.normalizedName(name)) != nil else {
                return false
            }
            guard requiresConnectionTest() else { return true }
            guard let test,
                  test.providerID == providerID,
                  test.baseURL == (try? resolvedBaseURL()) else {
                return false
            }
            if secret.isEmpty {
                return !test.replacesKey && providerID != nil && hasStoredKey
            }
            return test.replacesKey && test.secret == secret
        }

        private static func isValidSecret(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed == value
        }
    }

    enum ProviderFormAction {
        case test(ProviderDraft)
        case save(ProviderDraft)
        case cancel
    }

    enum ProviderManagementAction {
        case edit
        case refresh
        case models
        case delete
        case cancel
    }

    struct LocalKeyInput {
        let name: String
        let password: String
    }

    enum LocalKeyAction {
        case copy(password: String)
        case delete
    }

    nonisolated static let providerPresets: [ProviderPreset] = [
        ProviderPreset(title: "OpenAI", baseURL: "https://api.openai.com/v1"),
        ProviderPreset(title: "DeepSeek（深度求索）", baseURL: "https://api.deepseek.com/v1"),
        ProviderPreset(title: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1"),
        ProviderPreset(title: "SiliconFlow（硅基流动）", baseURL: "https://api.siliconflow.cn/v1"),
        ProviderPreset(title: "智谱 BigModel", baseURL: "https://open.bigmodel.cn/api/paas/v4"),
        ProviderPreset(
            title: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
        ),
        ProviderPreset(title: "xAI", baseURL: "https://api.x.ai/v1"),
        ProviderPreset(title: "Groq", baseURL: "https://api.groq.com/openai/v1"),
        ProviderPreset(title: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        ProviderPreset(title: "Mistral AI", baseURL: "https://api.mistral.ai/v1")
    ]

    static func initialProviderDraft(existing: ModelRelayProvider? = nil) -> ProviderDraft {
        let presetIndex = existing.flatMap { provider in
            providerPresets.firstIndex { $0.baseURL == provider.baseURL }
        }
        return ProviderDraft(
            providerID: existing?.id,
            originalBaseURL: existing?.baseURL,
            hasStoredKey: existing?.upstreamKey != nil,
            name: existing?.name ?? "",
            presetIndex: existing == nil ? 0 : presetIndex,
            customBaseURL: existing?.baseURL ?? "https://",
            secret: ""
        )
    }

    static func providerForm(
        existing: ModelRelayProvider?,
        draft initialDraft: ProviderDraft? = nil,
        tested: ModelRelayProviderConnectionTest? = nil,
        status: String? = nil
    ) -> ProviderFormAction {
        let draft = initialDraft ?? initialProviderDraft(existing: existing)
        let name = NSTextField(string: draft.name)
        name.placeholderString = "唯一厂家名称"
        let provider = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
        provider.addItems(withTitles: providerPresets.map(\.title) + ["自定义…"])
        provider.selectItem(at: draft.presetIndex ?? providerPresets.count)
        let url = NSTextField(string: draft.customBaseURL)
        url.placeholderString = "https://api.example.com/v1"
        let secret = ModelRelaySecureTextField(
            frame: NSRect(x: 0, y: 0, width: 330, height: 24)
        )
        secret.stringValue = draft.secret
        secret.placeholderString = existing == nil ? "上游 API Key" : "留空则保留现有 Key"
        let alert = NSAlert()
        alert.messageText = existing == nil ? "新增厂家" : "编辑厂家"
        alert.informativeText = status ?? "选择预设或自定义地址，连接测试通过后才能保存。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "测试连接")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = formAccessory(controls: [
            ("名称", name),
            ("厂商", provider),
            ("自定义 URL", url),
            ("API Key", secret)
        ])
        guard let accessory = alert.accessoryView as? NSStackView,
              accessory.arrangedSubviews.count == 4 else {
            return .cancel
        }
        let bridge = ModelRelayProviderFormBridge(
            alert: alert,
            accessory: accessory,
            name: name,
            provider: provider,
            customURL: url,
            secret: secret,
            initial: draft,
            tested: tested,
            presetCount: providerPresets.count
        )
        bridge.refresh()
        let response = withExtendedLifetime(bridge) {
            alert.runModalFocusingFirstTextField()
        }
        let result = bridge.makeDraft()
        bridge.detach()
        secret.stringValue = ""
        switch response {
        case .alertFirstButtonReturn:
            return result.canSave(using: tested) ? .save(result) : .cancel
        case .alertSecondButtonReturn:
            return result.isReadyToTest() ? .test(result) : .cancel
        default:
            return .cancel
        }
    }

    static func providerManagementAction(
        _ provider: ModelRelayProvider
    ) -> ProviderManagementAction {
        let source = providerPresets.first(where: { $0.baseURL == provider.baseURL })?.title
            ?? "自定义"
        let alert = NSAlert()
        alert.messageText = provider.name
        alert.informativeText = """
        厂商：\(source)
        Base URL：\(provider.baseURL)
        Key：\(provider.upstreamKey == nil ? "未配置" : "已配置")
        模型：\(provider.models.count)
        """
        alert.addButton(withTitle: "编辑…")
        alert.addButton(withTitle: "测试并刷新")
        alert.addButton(withTitle: "模型别名…")
        alert.addButton(withTitle: "删除…")
        alert.addButton(withTitle: "关闭")
        alert.buttons[1].isEnabled = provider.upstreamKey != nil
        alert.buttons[2].isEnabled = !provider.models.isEmpty
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
        case 0: return .edit
        case 1: return .refresh
        case 2: return .models
        case 3: return .delete
        default: return .cancel
        }
    }

    static func modelRoute(in provider: ModelRelayProvider) -> ModelRelayModelRoute? {
        guard !provider.models.isEmpty else { return nil }
        let routes = provider.models.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
        let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        selector.addItems(withTitles: routes.map(\.alias))
        let alert = NSAlert()
        alert.messageText = "模型别名"
        alert.informativeText = "选择模型后修改它的本地唯一别名。"
        alert.addButton(withTitle: "修改…")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = selector
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              routes.indices.contains(selector.indexOfSelectedItem) else {
            return nil
        }
        return routes[selector.indexOfSelectedItem]
    }

    static func providerMenuItem(
        _ provider: ModelRelayProvider,
        busy: Bool,
        target: AnyObject?,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: provider.name, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = provider.id.uuidString
        item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        item.isEnabled = !busy
        return item
    }

    static func localKeyMenuItem(
        _ key: ModelRelayLocalKeyRecord,
        target: AnyObject?,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: key.name, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = key.id.uuidString
        item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        return item
    }

    static func localKey() -> LocalKeyInput? {
        let name = NSTextField()
        name.placeholderString = "唯一显示名称"
        let password = ModelRelaySecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        password.placeholderString = "至少 8 个字符"
        let confirmation = ModelRelaySecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        confirmation.placeholderString = "再次输入查看密码"
        let alert = formAlert(
            title: "新增本地 Key",
            information: "将自动生成 tc_ 前缀的随机 Key。查看密码不会保存；忘记后只能删除并重建。",
            fields: [("名称", name), ("查看密码", password), ("确认密码", confirmation)],
            primary: "生成"
        )
        defer {
            password.stringValue = ""
            confirmation.stringValue = ""
        }
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            do {
                let normalizedName = try ModelRelayValidation.normalizedName(name.stringValue)
                guard password.stringValue.count >= 8 else {
                    throw ModelRelayError.invalidViewingPassword
                }
                guard password.stringValue == confirmation.stringValue else {
                    alert.informativeText = "两次输入的查看密码不一致。"
                    alert.window.makeFirstResponder(password)
                    continue
                }
                return LocalKeyInput(name: normalizedName, password: password.stringValue)
            } catch {
                alert.informativeText = error.localizedDescription
                alert.window.makeFirstResponder(name)
            }
        }
        return nil
    }

    static func localKeyAction(name: String) -> LocalKeyAction? {
        let password = ModelRelaySecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        password.placeholderString = "查看密码"
        let alert = NSAlert()
        alert.messageText = name
        alert.informativeText = "验证成功后可复制 Base URL、API Key 和可用模型；也可删除此 Key。"
        alert.addButton(withTitle: "验证并复制")
        alert.addButton(withTitle: "删除…")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = password
        defer { password.stringValue = "" }
        let response = alert.runModalFocusingFirstTextField()
        if response == .alertFirstButtonReturn {
            guard !password.stringValue.isEmpty else { return nil }
            return .copy(password: password.stringValue)
        }
        if response == .alertSecondButtonReturn,
           confirm(title: "删除本地 Key“\(name)”？", detail: "删除后无法恢复，使用此 Key 的客户端将立即失去访问权限。") {
            return .delete
        }
        return nil
    }

    static func alias(current: String, upstreamModelID: String) -> String? {
        let field = NSTextField(string: current)
        field.placeholderString = "全局唯一别名"
        let alert = formAlert(
            title: "修改模型别名",
            information: "上游模型：\(upstreamModelID)",
            fields: [("本地别名", field)],
            primary: "保存"
        )
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            do {
                return try ModelRelayValidation.normalizedName(field.stringValue)
            } catch {
                alert.informativeText = error.localizedDescription
            }
        }
        return nil
    }

    static func port(current: UInt16) -> Int? {
        let field = NSTextField(string: String(current))
        field.placeholderString = "1024…65535"
        let alert = formAlert(
            title: "修改本地中转端口",
            information: "服务只绑定 127.0.0.1。修改后将原子重启中转服务。",
            fields: [("端口", field)],
            primary: "应用"
        )
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            if let value = Int(field.stringValue), (1024...65_535).contains(value) {
                return value
            }
            alert.informativeText = ModelRelayError.invalidPort.localizedDescription
            alert.window.makeFirstResponder(field)
        }
        return nil
    }

    static func confirm(title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showError(_ error: Error, title: String = "操作未完成") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func showMessage(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func formAlert(
        title: String,
        information: String,
        fields: [(String, NSTextField)],
        primary: String
    ) -> NSAlert {
        formAlert(
            title: title,
            information: information,
            controls: fields.map { ($0.0, $0.1 as NSView) },
            primary: primary
        )
    }

    private static func formAlert(
        title: String,
        information: String,
        controls: [(String, NSView)],
        primary: String
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = information
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: "取消")

        alert.accessoryView = formAccessory(controls: controls)
        return alert
    }

    static func formAccessory(fields: [(String, NSTextField)]) -> NSView {
        formAccessory(controls: fields.map { ($0.0, $0.1 as NSView) })
    }

    static func formAccessory(controls: [(String, NSView)]) -> NSView {
        let fieldWidth: CGFloat = 330
        let labelWidth: CGFloat = 78
        let rowHeight: CGFloat = 28
        let spacing: CGFloat = 8
        let totalWidth = labelWidth + 10 + fieldWidth
        let totalHeight = CGFloat(controls.count) * rowHeight
            + CGFloat(max(0, controls.count - 1)) * spacing

        let form = NSStackView(frame: NSRect(
            x: 0,
            y: 0,
            width: totalWidth,
            height: totalHeight
        ))
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = spacing

        for (label, control) in controls {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            control.setAccessibilityLabel(label)
            control.translatesAutoresizingMaskIntoConstraints = false
            if let field = control as? NSTextField {
                field.isEditable = true
                field.isSelectable = true
                field.isEnabled = true
            }

            let row = NSStackView(frame: NSRect(
                x: 0,
                y: 0,
                width: totalWidth,
                height: rowHeight
            ))
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(text)
            row.addArrangedSubview(control)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: totalWidth),
                row.heightAnchor.constraint(equalToConstant: rowHeight),
                text.widthAnchor.constraint(equalToConstant: labelWidth),
                control.widthAnchor.constraint(equalToConstant: fieldWidth),
                control.heightAnchor.constraint(
                    equalToConstant: control is NSPopUpButton ? 26 : 24
                )
            ])
            form.addArrangedSubview(row)
        }
        form.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        form.layoutSubtreeIfNeeded()
        return form
    }
}

@MainActor
private final class ModelRelayProviderFormBridge: NSObject, NSTextFieldDelegate {
    private let alert: NSAlert
    private let accessory: NSStackView
    private let name: NSTextField
    private let provider: NSPopUpButton
    private let customURL: NSTextField
    private let secret: NSSecureTextField
    private let initial: ModelRelayPrompts.ProviderDraft
    private let tested: ModelRelayProviderConnectionTest?
    private let presetCount: Int

    init(
        alert: NSAlert,
        accessory: NSStackView,
        name: NSTextField,
        provider: NSPopUpButton,
        customURL: NSTextField,
        secret: NSSecureTextField,
        initial: ModelRelayPrompts.ProviderDraft,
        tested: ModelRelayProviderConnectionTest?,
        presetCount: Int
    ) {
        self.alert = alert
        self.accessory = accessory
        self.name = name
        self.provider = provider
        self.customURL = customURL
        self.secret = secret
        self.initial = initial
        self.tested = tested
        self.presetCount = presetCount
        super.init()
        name.delegate = self
        customURL.delegate = self
        secret.delegate = self
        provider.target = self
        provider.action = #selector(selectionChanged(_:))
    }

    func makeDraft() -> ModelRelayPrompts.ProviderDraft {
        ModelRelayPrompts.ProviderDraft(
            providerID: initial.providerID,
            originalBaseURL: initial.originalBaseURL,
            hasStoredKey: initial.hasStoredKey,
            name: name.stringValue,
            presetIndex: provider.indexOfSelectedItem < presetCount
                ? provider.indexOfSelectedItem
                : nil,
            customBaseURL: customURL.stringValue,
            secret: secret.stringValue
        )
    }

    func refresh() {
        let isCustom = provider.indexOfSelectedItem == presetCount
        customURL.isEnabled = isCustom
        accessory.arrangedSubviews[2].isHidden = !isCustom
        var frame = accessory.frame
        frame.size.height = isCustom ? 136 : 100
        accessory.frame = frame
        let draft = makeDraft()
        let validName = (try? ModelRelayValidation.normalizedName(draft.name)) != nil
        alert.buttons[0].isEnabled = draft.canSave(using: tested)
        alert.buttons[1].isEnabled = validName && draft.isReadyToTest()
        alert.buttons[1].title = draft.canSave(using: tested) && draft.requiresConnectionTest()
            ? "重新测试"
            : "测试连接"
        alert.layout()
    }

    func detach() {
        name.delegate = nil
        customURL.delegate = nil
        secret.delegate = nil
        provider.target = nil
        provider.action = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        refresh()
    }
}

/// 菜单栏应用没有 Edit 菜单，因此在安全输入框内显式支持粘贴和全选。
@MainActor
private final class ModelRelaySecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            guard let editor = currentEditor() else { return super.performKeyEquivalent(with: event) }
            editor.paste(self)
            return true
        case "a":
            selectText(self)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
