import AppKit

@MainActor
enum BookmarkSyncPrompt {
    enum Action {
        case save(String, enable: Bool)
        case setEnabled(Bool)
        case delete
        case cancel
    }

    static func present(
        hasKey: Bool,
        isEnabled: Bool,
        revealKey: () async throws -> String?
    ) async -> Action {
        if !hasKey {
            return presentCreate()
        }
        return await presentManage(isEnabled: isEnabled, revealKey: revealKey)
    }

    private static func presentCreate() -> Action {
        let field = PromptTextFields.secure(
            string: BookmarkSyncKeyFactory.generate(),
            placeholder: "至少 32 个字符，或粘贴已有密钥"
        )
        let stack = PromptTextFields.accessoryStack([
            PromptTextFields.labeled("远程同步密钥", field)
        ])

        let alert = NSAlert()
        alert.messageText = "远程同步"
        alert.informativeText = "可重新生成，或粘贴其它 Mac 上的密钥。密钥明文只保存在本机钥匙串；查看须通过 Touch ID 或设备密码。"
        alert.addButton(withTitle: "保存并开启")
        alert.addButton(withTitle: "重新生成")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = stack

        defer { field.stringValue = "" }
        while true {
            let response = alert.runModalFocusingFirstTextField()
            if response == .alertSecondButtonReturn {
                field.stringValue = BookmarkSyncKeyFactory.generate()
                continue
            }
            guard response == .alertFirstButtonReturn else {
                return .cancel
            }
            let value = field.stringValue
            if value.count < KeychainBookmarkSyncKeyStore.minimumLength
                || value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                alert.informativeText = BookmarkSyncKeyError.invalidSecret.localizedDescription
                continue
            }
            return .save(value, enable: true)
        }
    }

    private static func presentManage(
        isEnabled: Bool,
        revealKey: () async throws -> String?
    ) async -> Action {
        let alert = NSAlert()
        alert.messageText = "远程同步"
        alert.informativeText = isEnabled
            ? "远程同步已开启。可管理密钥，或暂时关闭远程同步。"
            : "远程同步已关闭，密钥仍保留。可管理密钥，或重新开启。"
        alert.addButton(withTitle: "管理密钥…")
        alert.addButton(withTitle: isEnabled ? "关闭同步" : "开启同步")
        alert.addButton(withTitle: "关闭")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try await DeviceOwnerAuth.evaluate(reason: "管理书签远程同步密钥")
                guard let revealed = try await revealKey() else { return .cancel }
                return presentRevealed(revealed)
            } catch {
                presentError(error.localizedDescription)
                return .cancel
            }
        case .alertSecondButtonReturn:
            return .setEnabled(!isEnabled)
        default:
            return .cancel
        }
    }

    private static func presentRevealed(_ revealed: String) -> Action {
        let alert = NSAlert()
        alert.messageText = "远程同步密钥"
        alert.informativeText = "当前密钥：\n\(revealed)"
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "编辑…")
        alert.addButton(withTitle: "删除…")
        alert.addButton(withTitle: "关闭")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(revealed, forType: .string)
            return .cancel
        case .alertSecondButtonReturn:
            return presentCreate()
        case .alertThirdButtonReturn:
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "删除本机远程同步密钥？"
            confirm.informativeText = "只清除这台 Mac 的密钥并停止远程同步。服务器房间与其它 Mac 的书签会保留。"
            confirm.addButton(withTitle: "删除")
            confirm.addButton(withTitle: "取消")
            return confirm.runModal() == .alertFirstButtonReturn ? .delete : .cancel
        default:
            return .cancel
        }
    }

    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法继续"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
