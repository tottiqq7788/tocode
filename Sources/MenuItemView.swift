import AppKit

/// 菜单项自定义视图：统一处理「点击复制」，文件夹额外在右侧画展开箭头。
/// 自定义 view 接管了菜单项的事件，因此高亮与点击都自行管理。
final class MenuItemView: NSView {
    private let name: String
    private let isFolder: Bool
    private let highlightView = NSVisualEffectView()
    var onClick: (() -> Void)?

    private var highlighted = false {
        didSet {
            if highlighted != oldValue { needsDisplay = true }
        }
    }

    init(name: String, isFolder: Bool, onClick: @escaping () -> Void) {
        self.name = name
        self.isFolder = isFolder
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 22))

        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.blendingMode = .behindWindow
        highlightView.isHidden = true
        addSubview(highlightView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        highlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        highlightView.frame = bounds
        highlightView.isHidden = !highlighted

        let font = NSFont.menuFont(ofSize: 13)
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        let nameStr = name as NSString
        let nameX: CGFloat = isFolder ? 20 : 8
        nameStr.draw(
            at: NSPoint(x: nameX, y: (bounds.height - nameStr.size(withAttributes: attrs).height) / 2),
            withAttributes: attrs
        )

        if isFolder {
            let iconStr = "▸" as NSString
            iconStr.draw(
                at: NSPoint(x: 6, y: (bounds.height - iconStr.size(withAttributes: attrs).height) / 2),
                withAttributes: attrs
            )
            let arrow = "›" as NSString
            let arrowSize = arrow.size(withAttributes: attrs)
            arrow.draw(
                at: NSPoint(x: bounds.width - arrowSize.width - 8, y: (bounds.height - arrowSize.height) / 2),
                withAttributes: attrs
            )
        }
    }
}
