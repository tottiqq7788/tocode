import AppKit
import CoreAudio
import Darwin
import IOKit
import IOKit.ps

/// 菜单栏唯一图标当前打开的菜单。右键按这个顺序循环。不进入可分享配置。
enum StatusMenuKind: String, Equatable, CaseIterable {
    case files
    case windows
    case bookmarks

    var title: String {
        switch self {
        case .files: return "文件"
        case .windows: return "窗口"
        case .bookmarks: return "书签"
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder.fill"
        case .windows: return "macwindow.on.rectangle"
        case .bookmarks: return "bookmark.fill"
        }
    }

    var next: StatusMenuKind {
        switch self {
        case .files: return .windows
        case .windows: return .bookmarks
        case .bookmarks: return .files
        }
    }

    static func resolved(_ raw: String?) -> StatusMenuKind {
        guard let raw, let kind = StatusMenuKind(rawValue: raw) else { return .files }
        return kind
    }
}

struct StatusMenuKindStore {
    static let key = "tocode.statusIcon.menuKind"
    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func kind() -> StatusMenuKind {
        StatusMenuKind.resolved(defaults.string(forKey: Self.key))
    }

    func set(_ kind: StatusMenuKind) {
        defaults.set(kind.rawValue, forKey: Self.key)
    }

    @discardableResult
    func cycle() -> StatusMenuKind {
        let next = kind().next
        set(next)
        return next
    }
}

/// 圆环上的一段。角度用 AppKit 约定：0 在右侧，逆时针增加。
struct StatusRingArc: Equatable {
    var start: CGFloat
    var sweep: CGFloat
    var clockwise: Bool

    var end: CGFloat { clockwise ? start - sweep : start + sweep }

    func fillEnd(_ fraction: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, fraction))
        return clockwise ? start - sweep * clamped : start + sweep * clamped
    }

    /// 没有读数，或读数不大于 0 时，只留底轨。
    func drawsFill(level: CGFloat?) -> Bool {
        guard let level else { return false }
        return level > 0
    }
}

enum StatusRingGeometry {
    static let gap: CGFloat = 16
    static let sweep: CGFloat = 104
    /// 底部，从左向右穿过正下方。
    static let battery = StatusRingArc(start: 218, sweep: sweep, clockwise: false)
    /// 左上，从靠近底部的一端向上画。
    static let brightness = StatusRingArc(start: 202, sweep: sweep, clockwise: true)
    /// 右上，从靠近底部的一端向上画。
    static let volume = StatusRingArc(start: 338, sweep: sweep, clockwise: false)
    static let hasDots = false
}

enum StatusRingBatteryRole: String, Equatable {
    case label
    case red
    case yellow
    case green
}

struct StatusRingBattery: Equatable {
    var present = false
    var percent: Int?
    var charging = false
    var connectedToPower = false
    var lowPowerMode = false
}

enum StatusRingBatteryPaint {
    static let lowThreshold = 20

    static func role(_ battery: StatusRingBattery) -> StatusRingBatteryRole {
        guard battery.present, let percent = battery.percent else { return .label }
        if percent < lowThreshold && !battery.connectedToPower { return .red }
        if battery.lowPowerMode { return .yellow }
        if battery.connectedToPower { return .green }
        return .label
    }
}

enum StatusRingLevels {
    /// 静音或没有音量时为 0。
    static func volumeFraction(percent: Int?, muted: Bool) -> CGFloat {
        if muted { return 0 }
        guard let percent else { return 0 }
        return CGFloat(max(0, min(100, percent))) / 100
    }

    static func unit(_ value: CGFloat?) -> CGFloat? {
        guard let value else { return nil }
        return max(0, min(1, value))
    }
}

struct StatusRingSample: Equatable {
    var battery = StatusRingBattery()
    var brightness: CGFloat?
    var volume: CGFloat = 0

    var batteryLevel: CGFloat? {
        guard battery.present, let percent = battery.percent else { return nil }
        return CGFloat(max(0, min(100, percent))) / 100
    }
}

enum StatusMeters {
    static func current() -> StatusRingSample {
        StatusRingSample(
            battery: battery(),
            brightness: brightness(),
            volume: volumeFraction()
        )
    }

    static func battery() -> StatusRingBattery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return StatusRingBattery()
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let percent: Int? = {
                guard let current, let maximum, maximum > 0 else { return nil }
                return max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
            }()
            return StatusRingBattery(
                present: true,
                percent: percent,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                connectedToPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return StatusRingBattery()
    }

    /// 内置显示器亮度，0…1。公开 IODisplay 读不到时用显示器服务；仍然读不到则返回 nil。
    static func brightness() -> CGFloat? {
        if let value = iokitBrightness() { return value }
        return BuiltinDisplayBrightness.fraction()
    }

    static func volumeFraction() -> CGFloat {
        let reading = outputVolume()
        return StatusRingLevels.volumeFraction(percent: reading.percent, muted: reading.muted)
    }

    private static func iokitBrightness() -> CGFloat? {
        for name in ["IODisplayConnect", "AppleBacklightDisplay"] {
            if let value = displayBrightness(serviceName: name) { return value }
        }
        return nil
    }

    private static func displayBrightness(serviceName: String) -> CGFloat? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(serviceName) as CFDictionary?,
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var value: Float = 0
            let key = "brightness" as CFString
            if IODisplayGetFloatParameter(service, 0, key, &value) == KERN_SUCCESS {
                return StatusRingLevels.unit(CGFloat(value))
            }
        }
        return nil
    }

    private static func outputVolume() -> (percent: Int?, muted: Bool) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioDeviceID = audioValue(system, kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return (nil, false) }
        let mute: UInt32? = audioValue(
            device,
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        )
        var muted = mute.map { $0 != 0 } ?? false
        let master: Float32? = audioValue(
            device,
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput
        )
        let scalar = master ?? {
            let left: Float32? = audioValue(
                device,
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: 1
            )
            let right: Float32? = audioValue(
                device,
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: 2
            )
            let channels = [left, right].compactMap { $0 }
            return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
        }()
        if scalar == 0 { muted = true }
        let percent = scalar.map { max(0, min(100, Int(($0 * 100).rounded()))) }
        return (percent, muted)
    }

    fileprivate static func audioValue<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }
}

/// 公开 IODisplay 在 Apple Silicon 上没有亮度服务。内置屏改问显示器服务，外接屏读不到就留空。
private enum BuiltinDisplayBrightness {
    private typealias Read = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias CanChange = @convention(c) (UInt32) -> Bool

    private static let read: Read? = load("DisplayServicesGetBrightness")
    private static let canChange: CanChange? = load("DisplayServicesCanChangeBrightness")

    static func fraction() -> CGFloat? {
        guard let read, let display = preferredDisplay() else { return nil }
        var value: Float = 0
        guard read(display, &value) == 0 else { return nil }
        return StatusRingLevels.unit(CGFloat(value))
    }

    private static func preferredDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let online = ids.prefix(Int(count))
        if let builtin = online.first(where: { CGDisplayIsBuiltin($0) != 0 && canChange?($0) != false }) {
            return builtin
        }
        return online.first { canChange?($0) == true }
    }

    private static func load<T>(_ name: String) -> T? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ), let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// 默认输出设备的音量和静音一变就通知。不靠两秒轮询。
final class StatusOutputLevelWatch {
    var onChange: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watching: AudioDeviceID?

    func start() {
        listen(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            self?.bindDevice()
            self?.onChange?()
        }
        bindDevice()
    }

    func stop() {
        remove(where: { _ in true })
        watching = nil
    }

    private func bindDevice() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let next: AudioDeviceID? = StatusMeters.audioValue(system, kAudioHardwarePropertyDefaultOutputDevice)
        guard let next, next != kAudioObjectUnknown else {
            remove(where: { $0 == watching })
            watching = nil
            return
        }
        guard next != watching else { return }
        remove(where: { $0 == watching })
        watching = next
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                listen(next, selector: selector, scope: kAudioDevicePropertyScopeOutput, element: element) { [weak self] in
                    self?.onChange?()
                }
            }
        }
    }

    private func listen(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        handler: @escaping () -> Void
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return }
        listeners.append((object, address, block))
    }

    private func remove(where matches: (AudioObjectID) -> Bool) {
        for (object, address, block) in listeners where matches(object) {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll { matches($0.0) }
    }
}

enum StatusRingIcon {
    /// 与 DuoBar 菜单栏图标同一组尺寸：画布 32×28，圆环直径 26，线宽 2.47。
    static let canvas = NSSize(width: 32, height: 28)
    static let outerDiameter: CGFloat = 26
    static let strokeWidth: CGFloat = 2.47
    static let symbolPointSize: CGFloat = 13
    /// 三个符号都收进同一方框，避免书签细、文件夹宽。
    static let symbolBox: CGFloat = 13
    static var radius: CGFloat { (outerDiameter - strokeWidth) / 2 }
    static var center: NSPoint { NSPoint(x: canvas.width / 2, y: canvas.height / 2) }

    static func image(sample: StatusRingSample, symbol: String, title: String) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            draw(sample: sample, symbol: symbol, title: title, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(sample: StatusRingSample, symbol: String, title: String, in rect: NSRect, color: NSColor = .labelColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = min(rect.width / canvas.width, rect.height / canvas.height)
        ctx.translateBy(x: rect.midX - canvas.width * scale / 2, y: rect.midY - canvas.height * scale / 2)
        ctx.scaleBy(x: scale, y: scale)
        let base = color.usingColorSpace(.deviceRGB) ?? color
        let batteryColor = paint(StatusRingBatteryPaint.role(sample.battery), base: base)
        stroke(StatusRingGeometry.battery, color: batteryColor, alpha: 0.20, end: StatusRingGeometry.battery.end)
        stroke(StatusRingGeometry.brightness, color: base, alpha: 0.20, end: StatusRingGeometry.brightness.end)
        stroke(StatusRingGeometry.volume, color: base, alpha: 0.20, end: StatusRingGeometry.volume.end)
        if let level = sample.batteryLevel, StatusRingGeometry.battery.drawsFill(level: level) {
            stroke(StatusRingGeometry.battery, color: batteryColor, alpha: 1, end: StatusRingGeometry.battery.fillEnd(level))
        }
        if let level = sample.brightness, StatusRingGeometry.brightness.drawsFill(level: level) {
            stroke(StatusRingGeometry.brightness, color: base, alpha: 1, end: StatusRingGeometry.brightness.fillEnd(level))
        }
        if StatusRingGeometry.volume.drawsFill(level: sample.volume) {
            stroke(StatusRingGeometry.volume, color: base, alpha: 1, end: StatusRingGeometry.volume.fillEnd(sample.volume))
        }
        drawSymbol(symbol, title: title, color: base)
    }

    private static func paint(_ role: StatusRingBatteryRole, base: NSColor) -> NSColor {
        switch role {
        case .label:
            return base
        case .red:
            return NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow:
            return .systemYellow
        case .green:
            let green = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.38, alpha: 1)
            return base.blended(withFraction: 0.72, of: green) ?? green
        }
    }

    private static func stroke(_ arc: StatusRingArc, color: NSColor, alpha: CGFloat, end: CGFloat) {
        color.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: arc.start,
            endAngle: end,
            clockwise: arc.clockwise
        )
        path.stroke()
    }

    private static func drawSymbol(_ name: String, title: String, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let scale = min(symbolBox / tinted.size.width, symbolBox / tinted.size.height, 1)
        let width = tinted.size.width * scale
        let height = tinted.size.height * scale
        tinted.draw(in: NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }
}
