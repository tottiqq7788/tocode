import AppKit

@MainActor
enum ModelRelayPrompts {
    struct ProviderPreset: Equatable {
        let title: String
        let baseURL: String
    }

    struct ProviderInput {
        let name: String
        let baseURL: String
    }

    struct UpstreamKeyInput {
        let name: String
        let secret: String
    }

    struct LocalKeyInput {
        let name: String
        let password: String
    }

    enum LocalKeyAction {
        case copy(password: String)
        case delete
    }

    static let providerPresets: [ProviderPreset] = [
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

    static func provider(existing: ModelRelayProvider? = nil) -> ProviderInput? {
        let name = NSTextField(string: existing?.name ?? "")
        name.placeholderString = "唯一厂商名称"
        let choices = providerChoices(existingBaseURL: existing?.baseURL)
        let provider = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
        provider.addItems(withTitles: choices.map(\.title))
        if let existing,
           let selected = choices.firstIndex(where: { $0.baseURL == existing.baseURL }) {
            provider.selectItem(at: selected)
        }
        let alert = formAlert(
            title: existing == nil ? "新增模型厂商" : "编辑模型厂商",
            information: "选择 OpenAI-compatible 上游并填写唯一名称，Base URL 会自动配置。",
            controls: [("厂商", provider), ("名称", name)],
            primary: existing == nil ? "新增" : "保存"
        )
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            do {
                let normalizedName = try ModelRelayValidation.normalizedName(name.stringValue)
                guard choices.indices.contains(provider.indexOfSelectedItem) else {
                    throw ModelRelayError.invalidBaseURL
                }
                let normalizedURL = try ModelRelayValidation.normalizedBaseURL(
                    choices[provider.indexOfSelectedItem].baseURL
                )
                return ProviderInput(name: normalizedName, baseURL: normalizedURL)
            } catch {
                alert.informativeText = error.localizedDescription
                alert.window.makeFirstResponder(name)
            }
        }
        return nil
    }

    static func providerChoices(existingBaseURL: String?) -> [ProviderPreset] {
        guard let existingBaseURL,
              !providerPresets.contains(where: { $0.baseURL == existingBaseURL }) else {
            return providerPresets
        }
        return providerPresets + [
            ProviderPreset(title: "现有自定义地址（保留）", baseURL: existingBaseURL)
        ]
    }

    static func upstreamKey(existingName: String? = nil) -> UpstreamKeyInput? {
        let name = NSTextField(string: existingName ?? "")
        name.placeholderString = "唯一显示名称"
        let secret = ModelRelaySecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        secret.placeholderString = existingName == nil ? "上游 API Key" : "输入新的上游 API Key"
        let alert = formAlert(
            title: existingName == nil ? "新增上游 Key" : "替换上游 Key",
            information: "保存前会请求 /v1/models 校验。明文只写入 macOS 钥匙串，之后不提供查看。",
            fields: [("名称", name), ("API Key", secret)],
            primary: existingName == nil ? "校验并新增" : "校验并替换"
        )
        defer { secret.stringValue = "" }
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            do {
                let normalizedName = try ModelRelayValidation.normalizedName(name.stringValue)
                guard !secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      secret.stringValue == secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw ModelRelayError.keyNotFound
                }
                return UpstreamKeyInput(name: normalizedName, secret: secret.stringValue)
            } catch {
                alert.informativeText = error.localizedDescription
                alert.window.makeFirstResponder(name)
            }
        }
        return nil
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
