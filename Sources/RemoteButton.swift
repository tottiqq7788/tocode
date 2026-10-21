import AppKit
import Foundation

struct RemoteButtonIcon: Equatable {
    let id: String
    let symbol: String
    let title: String
}

enum RemoteButtonIcons {
    static let all: [RemoteButtonIcon] = [
        .init(id: "moon", symbol: "moon.fill", title: "月亮"),
        .init(id: "sun", symbol: "sun.max.fill", title: "太阳"),
        .init(id: "lock", symbol: "lock.fill", title: "锁"),
        .init(id: "heart", symbol: "heart.fill", title: "心"),
        .init(id: "display", symbol: "display", title: "屏幕"),
        .init(id: "keyboard", symbol: "keyboard", title: "键盘"),
        .init(id: "terminal", symbol: "terminal", title: "终端"),
        .init(id: "folder", symbol: "folder.fill", title: "文件夹"),
        .init(id: "document", symbol: "doc.fill", title: "文档"),
        .init(id: "bolt", symbol: "bolt.fill", title: "闪电"),
        .init(id: "bell", symbol: "bell.fill", title: "铃铛"),
        .init(id: "camera", symbol: "camera.fill", title: "相机"),
        .init(id: "wifi", symbol: "wifi", title: "无线"),
        .init(id: "speaker", symbol: "speaker.wave.2.fill", title: "声音"),
        .init(id: "play", symbol: "play.fill", title: "播放"),
        .init(id: "pause", symbol: "pause.fill", title: "暂停"),
        .init(id: "stop", symbol: "stop.fill", title: "停止"),
        .init(id: "trash", symbol: "trash.fill", title: "删除"),
        .init(id: "star", symbol: "star.fill", title: "星星"),
        .init(id: "flag", symbol: "flag.fill", title: "旗帜"),
        .init(id: "tag", symbol: "tag.fill", title: "标签"),
        .init(id: "bookmark", symbol: "bookmark.fill", title: "书签"),
        .init(id: "clock", symbol: "clock.fill", title: "时钟"),
        .init(id: "calendar", symbol: "calendar", title: "日历"),
        .init(id: "map", symbol: "map.fill", title: "地图"),
        .init(id: "house", symbol: "house.fill", title: "房子"),
        .init(id: "gear", symbol: "gearshape.fill", title: "齿轮"),
        .init(id: "info", symbol: "info.circle.fill", title: "信息"),
        .init(id: "checkmark", symbol: "checkmark.circle.fill", title: "完成"),
        .init(id: "xmark", symbol: "xmark.circle.fill", title: "关闭"),
        .init(id: "plus", symbol: "plus.circle.fill", title: "添加"),
        .init(id: "person", symbol: "person.fill", title: "人"),
        .init(id: "message", symbol: "message.fill", title: "消息"),
        .init(id: "phone", symbol: "phone.fill", title: "电话"),
        .init(id: "mail", symbol: "envelope.fill", title: "邮件"),
        .init(id: "link", symbol: "link", title: "链接"),
        .init(id: "eye", symbol: "eye.fill", title: "眼睛"),
        .init(id: "hammer", symbol: "hammer.fill", title: "锤子"),
        .init(id: "wrench", symbol: "wrench.and.screwdriver.fill", title: "扳手"),
        .init(id: "paintbrush", symbol: "paintbrush.fill", title: "画笔"),
        .init(id: "photo", symbol: "photo.fill", title: "照片"),
        .init(id: "music", symbol: "music.note", title: "音乐"),
        .init(id: "microphone", symbol: "mic.fill", title: "麦克风"),
        .init(id: "video", symbol: "video.fill", title: "视频"),
        .init(id: "globe", symbol: "globe", title: "地球"),
        .init(id: "shield", symbol: "shield.fill", title: "盾牌"),
        .init(id: "key", symbol: "key.fill", title: "钥匙"),
    ]

    static func contains(_ id: String) -> Bool {
        all.contains { $0.id == id }
    }

    static func symbol(for id: String) -> String {
        all.first { $0.id == id }?.symbol ?? "square.dashed"
    }
}

struct RemoteMappingExtra: Equatable {
    let id: String
    let title: String
    let symbol: String
}

enum RemoteButtonExtras {
    static let all: [RemoteMappingExtra] = [
        .init(id: "status", title: "设备状态", symbol: "chart.bar.fill"),
        .init(id: "blackout-dismiss", title: "取消黑屏", symbol: "sun.max"),
        .init(id: "lock", title: "锁定屏幕", symbol: "lock.fill"),
    ]

    static func target(for id: String) -> RemoteButtonTarget? {
        switch id {
        case "status":
            return .status
        case "blackout-dismiss":
            return .dismissBlackout
        case "lock":
            return .lock
        default:
            return nil
        }
    }

    static func id(for target: RemoteButtonTarget) -> String? {
        switch target {
        case .status:
            return "status"
        case .dismissBlackout:
            return "blackout-dismiss"
        case .lock:
            return "lock"
        case .mapped:
            return nil
        }
    }
}

struct RemoteButton: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var detail: String
    var icon: String
    var target: RemoteButtonTarget
}

struct RemoteButtonDraft: Equatable {
    var id: UUID?
    var name: String
    var detail: String
    var icon: String
    var target: RemoteButtonTarget?

    init(
        id: UUID? = nil,
        name: String = "",
        detail: String = "",
        icon: String = "moon",
        target: RemoteButtonTarget? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.icon = icon
        self.target = target
    }

    init(button: RemoteButton) {
        id = button.id
        name = button.name
        detail = button.detail
        icon = button.icon
        target = button.target
    }
}

enum RemoteButtonTarget: Equatable, Codable {
    case mapped(KeyboardShortcutMappingTarget)
    case status
    case dismissBlackout
    case lock

    private enum CodingKeys: String, CodingKey {
        case kind
        case mapped
    }

    private enum Kind: String, Codable {
        case mapped
        case status
        case dismissBlackout = "blackout-dismiss"
        case lock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mapped:
            self = .mapped(try container.decode(KeyboardShortcutMappingTarget.self, forKey: .mapped))
        case .status:
            self = .status
        case .dismissBlackout:
            self = .dismissBlackout
        case .lock:
            self = .lock
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mapped(let target):
            try container.encode(Kind.mapped, forKey: .kind)
            try container.encode(target, forKey: .mapped)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        case .dismissBlackout:
            try container.encode(Kind.dismissBlackout, forKey: .kind)
        case .lock:
            try container.encode(Kind.lock, forKey: .kind)
        }
    }
}

enum RemoteButtonValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName
    case missingIcon
    case missingTarget
    case tottiNotEmittable
    case buttonNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入名称。"
        case .duplicateName:
            return "该名称已存在，请使用其他名称。"
        case .missingIcon:
            return "请选择图标。"
        case .missingTarget:
            return "请指定要执行的动作。"
        case .tottiNotEmittable:
            return "目标快捷键不能包含 totti。"
        case .buttonNotFound:
            return "该按钮已不存在，请重新打开遥控菜单。"
        }
    }
}

struct RemoteButtonStore {
    static let defaultsKey = "tocode.remoteButtons"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func all() -> [RemoteButton] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteButton].self, from: data)) ?? []
    }

    func save(_ draft: RemoteButtonDraft) -> Result<RemoteButton, RemoteButtonValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard RemoteButtonIcons.contains(draft.icon) else { return .failure(.missingIcon) }
        guard var target = draft.target else { return .failure(.missingTarget) }
        if case .mapped(let mapped) = target {
            if mapped.emitsTotti { return .failure(.tottiNotEmittable) }
            if case .openURL(let raw) = mapped {
                guard let url = MappedURL.normalized(raw) else { return .failure(.missingTarget) }
                target = .mapped(.openURL(url))
            }
        }

        var buttons = all()
        let others = buttons.filter { $0.id != draft.id }
        if others.contains(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .failure(.duplicateName)
        }

        let detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let button: RemoteButton
        if let id = draft.id {
            guard let index = buttons.firstIndex(where: { $0.id == id }) else {
                return .failure(.buttonNotFound)
            }
            button = RemoteButton(id: id, name: name, detail: detail, icon: draft.icon, target: target)
            buttons[index] = button
        } else {
            button = RemoteButton(id: UUID(), name: name, detail: detail, icon: draft.icon, target: target)
            buttons.append(button)
        }
        persist(buttons)
        return .success(button)
    }

    func delete(id: UUID) {
        var buttons = all()
        buttons.removeAll { $0.id == id }
        persist(buttons)
    }

    private func persist(_ buttons: [RemoteButton]) {
        guard let data = try? JSONEncoder().encode(buttons) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

enum RemoteButtonCatalog {
    static func body(_ buttons: [RemoteButton]) -> [String: Any] {
        [
            "buttons": buttons.map { button in
                [
                    "id": button.id.uuidString,
                    "name": button.name,
                    "detail": button.detail,
                    "icon": button.icon,
                ]
            },
        ]
    }

    static func resolve(_ buttons: [RemoteButton], target: [String: Any]?) -> RemoteButton? {
        guard let target, target.count == 1, let raw = target["button_id"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = UUID(uuidString: trimmed) else { return nil }
        return buttons.first { $0.id == id }
    }
}

enum RemoteButtonPromptResult {
    case save(RemoteButtonDraft)
    case delete
    case cancel
}

@MainActor
enum RemoteButtonPrompt {
    static func prompt(
        draft: RemoteButtonDraft,
        isEditing: Bool,
        automations: [ModelAutomation] = []
    ) -> RemoteButtonPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isEditing ? "编辑遥控按钮" : "新增遥控按钮"
        alert.informativeText = "选一个图标并填写名称。手机点一下，这台 Mac 按这里的目标执行一次。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if isEditing {
            let deleteButton = alert.addButton(withTitle: "删除")
            deleteButton.contentTintColor = .systemRed
        }

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：锁定屏幕"
        let detailLabel = NSTextField(labelWithString: "描述")
        let detailField = NSTextField(string: draft.detail)
        detailField.placeholderString = "显示在手机按钮上，可以留空"
        let iconLabel = NSTextField(labelWithString: "图标")
        let iconPicker = RemoteIconPicker(selected: draft.icon)
        let targetLabel = NSTextField(labelWithString: "映射")
        let mappedTarget: KeyboardShortcutMappingTarget?
        let selectedExtra: String?
        if case .mapped(let target) = draft.target {
            mappedTarget = target
            selectedExtra = nil
        } else if let target = draft.target {
            mappedTarget = nil
            selectedExtra = RemoteButtonExtras.id(for: target)
        } else {
            mappedTarget = nil
            selectedExtra = nil
        }
        let targetEditor = KeyboardMappingTargetEditor(
            target: mappedTarget,
            actionTriggerPhrase: "点一下后",
            automations: automations,
            extraActions: RemoteButtonExtras.all,
            selectedExtra: selectedExtra
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        for view in [
            nameLabel, nameField, detailLabel, detailField, iconLabel, iconPicker.scroll,
            targetLabel, targetEditor.view,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            detailField.widthAnchor.constraint(equalToConstant: 320),
            iconPicker.scroll.widthAnchor.constraint(equalToConstant: 320),
            iconPicker.scroll.heightAnchor.constraint(equalToConstant: 120),
            targetEditor.view.widthAnchor.constraint(equalToConstant: KeyboardMappingTargetEditor.width),
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 430)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        func updateSaveButton() {
            let named = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            saveButton.isEnabled = named && (targetEditor.target != nil || targetEditor.selectedExtraID != nil)
        }
        let observer = RemoteButtonFieldObserver(onChange: updateSaveButton)
        nameField.delegate = observer
        detailField.delegate = observer
        iconPicker.onChange = updateSaveButton
        targetEditor.onChange = updateSaveButton
        updateSaveButton()

        let response = withExtendedLifetime(observer) {
            alert.runModalFocusingFirstTextField()
        }
        nameField.delegate = nil
        detailField.delegate = nil
        iconPicker.onChange = nil
        let mapped = targetEditor.target
        let extra = targetEditor.selectedExtraID
        targetEditor.detach()
        let target: RemoteButtonTarget?
        if let extra, let special = RemoteButtonExtras.target(for: extra) {
            target = special
        } else if let mapped {
            target = .mapped(mapped)
        } else {
            target = nil
        }
        switch response {
        case .alertFirstButtonReturn:
            return .save(
                RemoteButtonDraft(
                    id: draft.id,
                    name: nameField.stringValue,
                    detail: detailField.stringValue,
                    icon: iconPicker.selected,
                    target: target
                )
            )
        case .alertThirdButtonReturn where isEditing:
            return .delete
        default:
            return .cancel
        }
    }
}

@MainActor
private final class RemoteIconPicker: NSObject {
    let scroll = NSScrollView()
    private let document = NSView()
    private var buttons: [NSButton] = []
    private(set) var selected: String
    var onChange: (() -> Void)?

    init(selected: String) {
        self.selected = RemoteButtonIcons.contains(selected) ? selected : RemoteButtonIcons.all[0].id
        super.init()
        let icons = RemoteButtonIcons.all
        let columns = 8
        let side: CGFloat = 34
        let gap: CGFloat = 4
        let rows = (icons.count + columns - 1) / columns
        let width = CGFloat(columns) * side + CGFloat(columns - 1) * gap
        let height = CGFloat(rows) * side + CGFloat(max(rows - 1, 0)) * gap
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (index, icon) in icons.enumerated() {
            let column = index % columns
            let row = index / columns
            let button = NSButton()
            button.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.title)
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.bezelStyle = .smallSquare
            button.isBordered = icon.id == self.selected
            button.toolTip = icon.title
            button.identifier = NSUserInterfaceItemIdentifier(icon.id)
            button.target = self
            button.action = #selector(pick(_:))
            let x = CGFloat(column) * (side + gap)
            let y = height - CGFloat(row + 1) * side - CGFloat(row) * gap
            button.frame = NSRect(x: x, y: y, width: side, height: side)
            document.addSubview(button)
            buttons.append(button)
        }
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
    }

    @objc private func pick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, RemoteButtonIcons.contains(id) else { return }
        selected = id
        for button in buttons {
            button.isBordered = button.identifier?.rawValue == id
        }
        onChange?()
    }
}

@MainActor
private final class RemoteButtonFieldObserver: NSObject, NSTextFieldDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }
}
