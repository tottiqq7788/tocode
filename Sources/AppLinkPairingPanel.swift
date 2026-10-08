import AppKit
import CoreImage

enum AppLinkDialog {
    struct Draft {
        var role: TogentRole
        var displayName: String
        var relayURL: String
    }

    static func add(roles: [TogentRole], relayURL: String) -> Draft? {
        guard let first = roles.first else { return nil }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24), pullsDown: false)
        for role in roles {
            popup.addItem(withTitle: role.name)
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.stringValue = first.name
        let relayField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        relayField.placeholderString = "https://中转地址"
        relayField.stringValue = relayURL
        let stack = formStack([
            ("角色", popup),
            ("显示名", nameField),
            ("中转地址", relayField)
        ])
        let alert = NSAlert()
        alert.messageText = "新增应用关联"
        alert.informativeText = "只选择已有角色。保存后会显示一次性配对二维码。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        let role = roles.indices.contains(index) ? roles[index] : first
        return Draft(
            role: role,
            displayName: nameField.stringValue,
            relayURL: relayField.stringValue
        )
    }

    static func edit(link: AppAssociation, roles: [TogentRole]) -> (draft: Draft, delete: Bool)? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24), pullsDown: false)
        for role in roles {
            popup.addItem(withTitle: role.name)
            if role.id == link.roleID {
                popup.selectItem(at: popup.numberOfItems - 1)
            }
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.stringValue = link.displayName
        let stack = formStack([
            ("角色", popup),
            ("显示名", nameField)
        ])
        let alert = NSAlert()
        alert.messageText = "编辑应用关联"
        alert.informativeText = "删除后这条关联不再转发，两边已经留下的消息还在。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { return nil }
        let index = popup.indexOfSelectedItem
        let role = roles.indices.contains(index) ? roles[index] : roles.first
        guard let role else { return nil }
        return (
            Draft(role: role, displayName: nameField.stringValue, relayURL: ""),
            response == .alertSecondButtonReturn
        )
    }

    private static func formStack(_ rows: [(String, NSView)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, field) in rows {
            let label = NSTextField(labelWithString: title)
            stack.addArrangedSubview(label)
            field.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(rows.count) * 52)
        return stack
    }
}

enum AppLinkPairingPanel {
    private static var panel: NSPanel?

    static func show(payload: String) {
        close()
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "应用关联"
        window.isFloatingPanel = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        let image = NSImageView(frame: NSRect(x: 30, y: 90, width: 220, height: 220))
        image.image = qrImage(payload)
        let label = NSTextField(wrappingLabelWithString: "用安卓 Tocode 扫描。二维码里只有中转地址和一次性配对码。")
        label.frame = NSRect(x: 20, y: 20, width: 240, height: 60)
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.addSubview(image)
        content.addSubview(label)
        window.contentView = content
        window.center()
        panel = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        panel?.close()
        panel = nil
    }

    static func qrImage(_ text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
