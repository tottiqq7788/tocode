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
        case save(ProviderDraft, tested: ModelRelayProviderConnectionTest?)
        case delete(ProviderDraft)
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
        tested initialTested: ModelRelayProviderConnectionTest? = nil,
        status initialStatus: String? = nil,
        performTest: @escaping (
            ProviderDraft,
            @escaping (Result<ModelRelayProviderConnectionTest, Error>) -> Void
        ) -> (() -> Void),
        performRefresh: ((
            @escaping (Result<ModelRelayCapabilitySummary, Error>) -> Void
        ) -> (() -> Void))? = nil
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

        let modelHint: String
        if let existing {
            modelHint = existing.models.isEmpty
                ? "已保存厂家。修改地址或 Key 后需重新测试；也可刷新上游模型目录。"
                : "已保存厂家，\(ModelRelayCapabilitySummary(routes: existing.models).displayText)。修改地址或 Key 后需重新测试。"
        } else {
            modelHint = "选择预设或自定义地址，连接测试通过后才能保存。"
        }
        let statusLabel = NSTextField(wrappingLabelWithString: initialStatus ?? modelHint)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 418

        let saveButton = formActionButton("保存")
        saveButton.keyEquivalent = "\r"
        let testButton = formActionButton("测试连接")
        let refreshButton = existing == nil ? nil : formActionButton("刷新模型")
        let deleteButton = existing == nil ? nil : formActionButton("删除…")
        let cancelButton = formActionButton("取消")

        var actionButtons = [saveButton, testButton]
        if let refreshButton { actionButtons.append(refreshButton) }
        if let deleteButton { actionButtons.append(deleteButton) }
        actionButtons.append(cancelButton)
        let buttonRow = formButtonRow(actionButtons)

        let fields = formAccessory(controls: [
            ("名称", name),
            ("厂商", provider),
            ("自定义 URL", url),
            ("API Key", secret)
        ])
        guard let fieldStack = fields as? NSStackView else { return .cancel }

        let contentWidth = max(fieldStack.frame.width, 418)
        let statusHeight: CGFloat = 42
        let content = NSStackView(frame: NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: fieldStack.frame.height + 10 + statusHeight + 10 + 28
        ))
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [fieldStack, statusLabel, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            fieldStack.widthAnchor.constraint(equalToConstant: contentWidth),
            statusLabel.widthAnchor.constraint(equalToConstant: contentWidth),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: statusHeight),
            buttonRow.widthAnchor.constraint(equalToConstant: contentWidth),
            buttonRow.heightAnchor.constraint(equalToConstant: 28)
        ])
        content.layoutSubtreeIfNeeded()
        content.frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: fieldStack.frame.height + 10 + statusHeight + 10 + 28
        )

        let alert = NSAlert()
        alert.messageText = existing == nil ? "新增厂家" : "编辑厂家"
        alert.informativeText = ""
        // NSAlert 至少要有一个按钮；动作全部改由 accessory 横向按钮驱动，避免竖排与重开闪烁。
        // Escape 落到这个隐藏取消按钮，避免误触保存。
        alert.addButton(withTitle: "取消")
        alert.buttons[0].isHidden = true
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.accessoryView = content

        let bridge = ModelRelayProviderFormBridge(
            alert: alert,
            fieldStack: fieldStack,
            statusLabel: statusLabel,
            content: content,
            name: name,
            provider: provider,
            customURL: url,
            secret: secret,
            saveButton: saveButton,
            testButton: testButton,
            refreshButton: refreshButton,
            deleteButton: deleteButton,
            cancelButton: cancelButton,
            initial: draft,
            tested: initialTested,
            presetCount: providerPresets.count,
            defaultStatus: modelHint,
            performTest: performTest,
            performRefresh: performRefresh
        )
        bridge.refresh()
        let response = withExtendedLifetime(bridge) {
            alert.runModalFocusingFirstTextField()
        }
        let result = bridge.makeDraft()
        let tested = bridge.currentTest
        bridge.detach()
        secret.stringValue = ""
        switch response.rawValue {
        case ModelRelayProviderFormBridge.saveCode:
            return result.canSave(using: tested) ? .save(result, tested: tested) : .cancel
        case ModelRelayProviderFormBridge.deleteCode:
            return .delete(result)
        default:
            return .cancel
        }
    }

    static func formActionButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func formButtonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        return row
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
    static let saveCode = 1_000
    static let deleteCode = 1_001

    private let alert: NSAlert
    private let fieldStack: NSStackView
    private let statusLabel: NSTextField
    private let content: NSStackView
    private let name: NSTextField
    private let provider: NSPopUpButton
    private let customURL: NSTextField
    private let secret: NSSecureTextField
    private let saveButton: NSButton
    private let testButton: NSButton
    private let refreshButton: NSButton?
    private let deleteButton: NSButton?
    private let cancelButton: NSButton
    private let initial: ModelRelayPrompts.ProviderDraft
    private(set) var currentTest: ModelRelayProviderConnectionTest?
    private let presetCount: Int
    private let defaultStatus: String
    private let performTest: (
        ModelRelayPrompts.ProviderDraft,
        @escaping (Result<ModelRelayProviderConnectionTest, Error>) -> Void
    ) -> (() -> Void)
    private let performRefresh: ((
        @escaping (Result<ModelRelayCapabilitySummary, Error>) -> Void
    ) -> (() -> Void))?
    private var isBusy = false
    private var activeOperationID: UUID?
    private var activeCancellation: (() -> Void)?

    init(
        alert: NSAlert,
        fieldStack: NSStackView,
        statusLabel: NSTextField,
        content: NSStackView,
        name: NSTextField,
        provider: NSPopUpButton,
        customURL: NSTextField,
        secret: NSSecureTextField,
        saveButton: NSButton,
        testButton: NSButton,
        refreshButton: NSButton?,
        deleteButton: NSButton?,
        cancelButton: NSButton,
        initial: ModelRelayPrompts.ProviderDraft,
        tested: ModelRelayProviderConnectionTest?,
        presetCount: Int,
        defaultStatus: String,
        performTest: @escaping (
            ModelRelayPrompts.ProviderDraft,
            @escaping (Result<ModelRelayProviderConnectionTest, Error>) -> Void
        ) -> (() -> Void),
        performRefresh: ((
            @escaping (Result<ModelRelayCapabilitySummary, Error>) -> Void
        ) -> (() -> Void))?
    ) {
        self.alert = alert
        self.fieldStack = fieldStack
        self.statusLabel = statusLabel
        self.content = content
        self.name = name
        self.provider = provider
        self.customURL = customURL
        self.secret = secret
        self.saveButton = saveButton
        self.testButton = testButton
        self.refreshButton = refreshButton
        self.deleteButton = deleteButton
        self.cancelButton = cancelButton
        self.initial = initial
        self.currentTest = tested
        self.presetCount = presetCount
        self.defaultStatus = defaultStatus
        self.performTest = performTest
        self.performRefresh = performRefresh
        super.init()
        name.delegate = self
        customURL.delegate = self
        secret.delegate = self
        provider.target = self
        provider.action = #selector(selectionChanged(_:))
        saveButton.target = self
        saveButton.action = #selector(saveTapped(_:))
        testButton.target = self
        testButton.action = #selector(testTapped(_:))
        refreshButton?.target = self
        refreshButton?.action = #selector(refreshTapped(_:))
        deleteButton?.target = self
        deleteButton?.action = #selector(deleteTapped(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
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
        customURL.isEnabled = !isBusy && isCustom
        fieldStack.arrangedSubviews[2].isHidden = !isCustom
        var fieldFrame = fieldStack.frame
        fieldFrame.size.height = isCustom ? 136 : 100
        fieldStack.frame = fieldFrame
        let contentWidth = max(content.frame.width, fieldFrame.width)
        content.frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: fieldFrame.height + 10 + 42 + 10 + 28
        )

        let draft = makeDraft()
        let validName = (try? ModelRelayValidation.normalizedName(draft.name)) != nil
        saveButton.isEnabled = !isBusy && draft.canSave(using: currentTest)
        testButton.isEnabled = !isBusy && validName && draft.isReadyToTest()
        testButton.title = draft.canSave(using: currentTest) && draft.requiresConnectionTest()
            ? "重新测试"
            : "测试连接"
        refreshButton?.isEnabled = !isBusy
            && initial.hasStoredKey
            && !draft.requiresConnectionTest()
        deleteButton?.isEnabled = !isBusy
        cancelButton.isEnabled = true
        name.isEnabled = !isBusy
        provider.isEnabled = !isBusy
        secret.isEnabled = !isBusy
        alert.layout()
        alert.window.layoutIfNeeded()
    }

    func detach() {
        activeCancellation?()
        activeCancellation = nil
        activeOperationID = nil
        name.delegate = nil
        customURL.delegate = nil
        secret.delegate = nil
        provider.target = nil
        provider.action = nil
        saveButton.target = nil
        testButton.target = nil
        refreshButton?.target = nil
        deleteButton?.target = nil
        cancelButton.target = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        if currentTest != nil {
            let draft = makeDraft()
            if draft.requiresConnectionTest() {
                currentTest = nil
                if statusLabel.stringValue.hasPrefix("连接成功") {
                    statusLabel.stringValue = defaultStatus
                }
            }
        }
        refresh()
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        currentTest = nil
        statusLabel.stringValue = defaultStatus
        refresh()
    }

    @objc private func saveTapped(_ sender: NSButton) {
        let draft = makeDraft()
        guard draft.canSave(using: currentTest) else { return }
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Self.saveCode))
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        activeCancellation?()
        activeCancellation = nil
        activeOperationID = nil
        isBusy = false
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Self.deleteCode))
    }

    @objc private func testTapped(_ sender: NSButton) {
        let draft = makeDraft()
        guard draft.isReadyToTest() else { return }
        isBusy = true
        statusLabel.stringValue = "正在测试连接…"
        refresh()
        let operationID = UUID()
        activeOperationID = operationID
        let cancellation = performTest(draft) { [weak self] result in
            guard let self, self.activeOperationID == operationID else { return }
            self.activeOperationID = nil
            self.activeCancellation = nil
            self.isBusy = false
            switch result {
            case .success(let test):
                self.currentTest = test
                self.statusLabel.stringValue = "连接成功，\(test.capabilitySummary.displayText)，可以保存。能力未知可能由限流、超时、服务错误或识图答案不符导致。"
            case .failure(let error):
                self.currentTest = nil
                self.statusLabel.stringValue = "连接失败：\(error.localizedDescription)"
            }
            self.refresh()
        }
        if activeOperationID == operationID {
            activeCancellation = cancellation
        }
    }

    @objc private func refreshTapped(_ sender: NSButton) {
        guard let performRefresh else { return }
        isBusy = true
        statusLabel.stringValue = "正在刷新模型…"
        refresh()
        let operationID = UUID()
        activeOperationID = operationID
        let cancellation = performRefresh { [weak self] result in
            guard let self, self.activeOperationID == operationID else { return }
            self.activeOperationID = nil
            self.activeCancellation = nil
            self.isBusy = false
            switch result {
            case .success(let summary):
                self.statusLabel.stringValue = "已刷新，\(summary.displayText)。能力未知可能由限流、超时、服务错误或识图答案不符导致。"
            case .failure(let error):
                self.statusLabel.stringValue = "刷新失败：\(error.localizedDescription)"
            }
            self.refresh()
        }
        if activeOperationID == operationID {
            activeCancellation = cancellation
        }
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
