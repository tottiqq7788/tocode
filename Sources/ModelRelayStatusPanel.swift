import AppKit

enum ModelRelayStatusPanel {
    private static var retainedPanels: [NSPanel] = []

    static func present(
        port: UInt16,
        runState: ModelRelayRunState,
        providers: [ModelRelayProvider],
        metrics: ModelRelayCallMetricsRecording
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "模型中转状态"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let controller = ModelRelayStatusViewController(
            port: port,
            runState: runState,
            providers: providers,
            metrics: metrics
        )
        panel.contentViewController = controller
        retainedPanels.append(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class ModelRelayStatusViewController: NSViewController {
    private let port: UInt16
    private let runState: ModelRelayRunState
    private let providers: [ModelRelayProvider]
    private let metrics: ModelRelayCallMetricsRecording
    private var selectedProviderID: UUID?
    private var range: ModelRelayMetricsRange = .sixHours

    private let urlField = NSTextField(labelWithString: "")
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rangeControl = NSSegmentedControl(
        labels: ModelRelayMetricsRange.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let chartView = ModelRelayCallChartView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "暂无厂家，无法展示调用次数。")

    init(
        port: UInt16,
        runState: ModelRelayRunState,
        providers: [ModelRelayProvider],
        metrics: ModelRelayCallMetricsRecording
    ) {
        self.port = port
        self.runState = runState
        self.providers = providers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.metrics = metrics
        if let last = metrics.lastUsedProviderID,
           providers.contains(where: { $0.id == last }) {
            selectedProviderID = last
        } else {
            selectedProviderID = self.providers.first?.id
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        root.wantsLayer = true
        view = root

        urlField.stringValue = "当前 URL：http://127.0.0.1:\(port)/v1"
        urlField.font = .systemFont(ofSize: 13, weight: .medium)
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.toolTip = runState.menuText

        let stateLabel = NSTextField(labelWithString: runState.menuText)
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor

        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.removeAllItems()
        for provider in providers {
            providerPopup.addItem(withTitle: provider.name)
            providerPopup.lastItem?.representedObject = provider.id
        }
        if let selectedProviderID,
           let index = providers.firstIndex(where: { $0.id == selectedProviderID }) {
            providerPopup.selectItem(at: index)
        }
        providerPopup.isEnabled = !providers.isEmpty

        rangeControl.selectedSegment = 0
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)

        let openLog = NSButton(
            title: "打开今日日志文件",
            target: self,
            action: #selector(openTodayLog)
        )
        openLog.bezelStyle = .rounded

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = !providers.isEmpty
        chartView.isHidden = providers.isEmpty

        let stack = NSStackView(views: [
            urlField,
            stateLabel,
            labeled("厂家", providerPopup),
            labeled("时间范围", rangeControl),
            chartView,
            emptyLabel,
            openLog
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        chartView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            chartView.heightAnchor.constraint(equalToConstant: 180),
            chartView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            rangeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        reloadChart()
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func providerChanged() {
        selectedProviderID = providerPopup.selectedItem?.representedObject as? UUID
        reloadChart()
    }

    @objc private func rangeChanged() {
        let index = rangeControl.selectedSegment
        guard ModelRelayMetricsRange.allCases.indices.contains(index) else { return }
        range = ModelRelayMetricsRange.allCases[index]
        reloadChart()
    }

    @objc private func openTodayLog() {
        do {
            let url = try metrics.ensureTodayLogFile()
            NSWorkspace.shared.open(url)
        } catch {
            ModelRelayPrompts.showError(error, title: "无法打开今日日志")
        }
    }

    private func reloadChart() {
        guard let selectedProviderID else {
            chartView.points = []
            return
        }
        chartView.points = metrics.series(providerID: selectedProviderID, range: range, now: Date())
        chartView.needsDisplay = true
    }
}

private final class ModelRelayCallChartView: NSView {
    var points: [ModelRelayChartPoint] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 8, dy: 8)
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        guard points.count >= 2 else {
            let text = "暂无调用记录"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(
                    x: bounds.midX - size.width / 2,
                    y: bounds.midY - size.height / 2
                ),
                withAttributes: attrs
            )
            return
        }

        let maxCount = max(points.map(\.count).max() ?? 1, 1)
        let plot = bounds.insetBy(dx: 28, dy: 20)
        let path = NSBezierPath()
        path.lineWidth = 2
        for (index, point) in points.enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = plot.maxY - plot.height * CGFloat(point.count) / CGFloat(maxCount)
            let location = NSPoint(x: x, y: y)
            if index == 0 {
                path.move(to: location)
            } else {
                path.line(to: location)
            }
        }
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        "0".draw(at: NSPoint(x: bounds.minX + 4, y: plot.maxY - 8), withAttributes: axisAttrs)
        "\(maxCount)".draw(at: NSPoint(x: bounds.minX + 4, y: plot.minY), withAttributes: axisAttrs)
        "调用次数".draw(at: NSPoint(x: bounds.minX + 4, y: bounds.minY + 2), withAttributes: axisAttrs)
    }
}
