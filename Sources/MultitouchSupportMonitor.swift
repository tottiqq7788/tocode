import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

struct MultitouchContactFrame {
    let deviceID: UInt
    let touchCount: Int
    let timestamp: TimeInterval
    let firstPosition: CGPoint?
}

protocol MultitouchMonitoring: AnyObject {
    var isRunning: Bool { get }
    @discardableResult
    func start(handler: @escaping (MultitouchContactFrame) -> Void) -> Bool
    func stop()
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private func tocodeMultitouchCallback(
    _ device: MTDeviceRef?,
    _ contacts: UnsafeMutableRawPointer?,
    _ count: Int32,
    _ timestamp: Double,
    _ frame: Int32
) -> Int32 {
    MultitouchCallbackRouter.shared.route(device: device, contacts: contacts, count: count)
    return 0
}

/// macOS 26 改过完整触点结构的尾部；这里只读取仍稳定的首触点前缀。
private struct MTContactPrefix {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalizedX: Float
    var normalizedY: Float
}

private final class MultitouchCallbackRouter: @unchecked Sendable {
    static let shared = MultitouchCallbackRouter()

    private let lock = NSLock()
    private weak var receiver: PrivateMultitouchMonitor?

    func attach(_ receiver: PrivateMultitouchMonitor?) {
        lock.lock()
        self.receiver = receiver
        lock.unlock()
    }

    func route(device: MTDeviceRef?, contacts: UnsafeMutableRawPointer?, count: Int32) {
        lock.lock()
        let receiver = receiver
        lock.unlock()
        receiver?.receive(device: device, contacts: contacts, count: count)
    }
}

private final class MultitouchAPI {
    typealias CreateDeviceList = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterCallback = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias UnregisterCallback = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias StartDevice = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias StopDevice = @convention(c) (MTDeviceRef) -> Void

    let handle: UnsafeMutableRawPointer
    let createDeviceList: CreateDeviceList
    let registerCallback: RegisterCallback
    let unregisterCallback: UnregisterCallback
    let startDevice: StartDevice
    let stopDevice: StopDevice

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }

        guard
            let createDeviceList = Self.load("MTDeviceCreateList", from: handle, as: CreateDeviceList.self),
            let registerCallback = Self.load(
                "MTRegisterContactFrameCallback",
                from: handle,
                as: RegisterCallback.self
            ),
            let unregisterCallback = Self.load(
                "MTUnregisterContactFrameCallback",
                from: handle,
                as: UnregisterCallback.self
            ),
            let startDevice = Self.load("MTDeviceStart", from: handle, as: StartDevice.self),
            let stopDevice = Self.load("MTDeviceStop", from: handle, as: StopDevice.self)
        else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.createDeviceList = createDeviceList
        self.registerCallback = registerCallback
        self.unregisterCallback = unregisterCallback
        self.startDevice = startDevice
        self.stopDevice = stopDevice
    }

    deinit {
        dlclose(handle)
    }

    private static func load<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

final class PrivateMultitouchMonitor: MultitouchMonitoring {
    private let api: MultitouchAPI?
    private let stateLock = NSLock()
    private var handler: ((MultitouchContactFrame) -> Void)?
    private var deviceList: CFMutableArray?
    private var devices: [MTDeviceRef] = []

    init() {
        api = MultitouchAPI()
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !devices.isEmpty
    }

    @discardableResult
    func start(handler: @escaping (MultitouchContactFrame) -> Void) -> Bool {
        stop()
        guard let api, let listPointer = api.createDeviceList() else { return false }

        let list = Unmanaged<CFMutableArray>.fromOpaque(listPointer).takeRetainedValue()
        let count = CFArrayGetCount(list)
        guard count > 0 else { return false }

        var foundDevices: [MTDeviceRef] = []
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            foundDevices.append(UnsafeMutableRawPointer(mutating: raw))
        }
        guard !foundDevices.isEmpty else { return false }

        stateLock.lock()
        self.handler = handler
        deviceList = list
        devices = foundDevices
        stateLock.unlock()

        MultitouchCallbackRouter.shared.attach(self)
        for device in foundDevices {
            api.registerCallback(device, tocodeMultitouchCallback)
            api.startDevice(device, 0)
        }
        return true
    }

    func stop() {
        stateLock.lock()
        let devices = self.devices
        self.devices.removeAll()
        handler = nil
        stateLock.unlock()

        if let api {
            for device in devices {
                api.unregisterCallback(device, tocodeMultitouchCallback)
                api.stopDevice(device)
            }
        }
        MultitouchCallbackRouter.shared.attach(nil)

        stateLock.lock()
        deviceList = nil
        stateLock.unlock()
    }

    fileprivate func receive(
        device: MTDeviceRef?,
        contacts: UnsafeMutableRawPointer?,
        count: Int32
    ) {
        guard let device else { return }
        let rawCount = max(0, Int(count))
        var activeCount = rawCount
        var position: CGPoint?

        if rawCount > 0, let contacts {
            let first = contacts.assumingMemoryBound(to: MTContactPrefix.self).pointee
            let activeStates: Set<Int32> = [3, 4, 5]
            activeCount = activeStates.contains(first.state) ? rawCount : 0

            let x = CGFloat(first.normalizedX)
            let y = CGFloat(first.normalizedY)
            if x.isFinite, y.isFinite, (-0.25...1.25).contains(x), (-0.25...1.25).contains(y) {
                position = CGPoint(x: x, y: y)
            }
        }

        let frame = MultitouchContactFrame(
            deviceID: UInt(bitPattern: device),
            touchCount: activeCount,
            timestamp: ProcessInfo.processInfo.systemUptime,
            firstPosition: position
        )

        stateLock.lock()
        let handler = handler
        stateLock.unlock()
        handler?(frame)
    }
}
