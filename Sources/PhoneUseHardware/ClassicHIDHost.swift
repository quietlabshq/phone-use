import CoreBluetooth
import Darwin
import Foundation
import ObjectiveC
import PhoneUseCore
import PhoneUseHID

/// Mac-as-HID-device over Classic Bluetooth, following TapKit's HIDRuntime:
/// undocumented `CBClassicManager` APIs, a patched L2CAP open handler, and
/// raw `sendmsg` writes of HIDP input packets.
public actor ClassicHIDHost: HIDTransport {
    public static let shared = ClassicHIDHost()

    private var manager: AnyObject?
    private var interruptFD: Int32 = -1
    private var startError: PhoneError?
    private var started = false

    public func isHostConnected() async -> Bool {
        interruptFD >= 0 || HIDAdvertiser.shared.hasInterruptChannel()
    }

    public func send(_ report: HIDReport) async throws {
        try startAdvertising()
        let packet = HIDP.interruptPacket(for: report)
        if interruptFD >= 0 {
            try HIDSocket.write(packet, to: interruptFD)
            HIDRuntime.didSend(report, interruptFD: interruptFD)
            return
        }
        try HIDAdvertiser.shared.writeInterrupt(packet)
    }

    public func startAdvertising() throws {
        if started { if let startError { throw startError }; return }
        started = true
        do {
            try HIDRuntime.install { [weak self] fd in
                Task { await self?.setInterrupt(fd) }
            } closed: { [weak self] in
                Task { await self?.setInterrupt(-1) }
            }
            let manager = try HIDRuntime.makeManager()
            HIDRuntime.waitUntilPowered(manager)
            let handle = HIDRuntime.addService(HIDSDPRecord.bytes, to: manager)
            HIDLog.write("addServiceWithData handle=\(handle)")
            try HIDAdvertiser.shared.start { connected in
                HIDLog.write(connected ? "iPhone opened HID interrupt channel" : "HID interrupt channel closed")
            }
            HIDRuntime.setDiscoverable(true, on: manager)
            HIDRuntime.setConnectable(true, on: manager)
            self.manager = manager
            HIDLog.write("advertising as \(HIDSDPRecord.serviceName)")
        } catch let error as PhoneError {
            startError = error
            HIDLog.write("start failed: \(error)")
            throw error
        } catch {
            let wrapped = PhoneError.commandFailed("Bluetooth HID host failed to start: \(error)")
            startError = wrapped
            HIDLog.write("start failed: \(wrapped)")
            throw wrapped
        }
    }

    private func setInterrupt(_ fd: Int32) {
        interruptFD = fd
    }
}

enum HIDSocket {
    static func write(_ packet: [UInt8], to fd: Int32) throws {
        guard !packet.isEmpty else {
            throw PhoneError.commandFailed("cannot write an empty HIDP transaction")
        }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PhoneError.commandFailed("HID socket setup failed: \(String(cString: strerror(errno)))")
        }
        try packet.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else {
                throw PhoneError.commandFailed("HID report send failed")
            }
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: bytes.count)
            var message = msghdr()
            // CoreBluetooth's stream socket uses this empty ancillary record
            // to delimit one L2CAP packet (matching HIDRuntime's sendmsg path).
            var boundary = cmsghdr(cmsg_len: socklen_t(MemoryLayout<cmsghdr>.size), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
            let sent = withUnsafeMutablePointer(to: &iov) { iovPtr in
                message.msg_iov = iovPtr
                message.msg_iovlen = 1
                return withUnsafeMutablePointer(to: &boundary) { boundaryPtr in
                    message.msg_control = UnsafeMutableRawPointer(boundaryPtr)
                    message.msg_controllen = socklen_t(MemoryLayout<cmsghdr>.size)
                    return sendmsg(fd, &message, MSG_DONTWAIT)
                }
            }
            guard sent == bytes.count else {
                throw PhoneError.commandFailed("HID report send failed (\(sent)/\(bytes.count) bytes): \(String(cString: strerror(errno)))")
            }
        }
    }
}

/// Objective-C runtime glue for private CoreBluetooth Classic types.
enum HIDRuntime {
    private static let state = HIDRuntimeState()

    static func didSend(_ report: HIDReport, interruptFD: Int32) {
        state.lock.lock()
        let control = state.channels.first { _, channels in
            guard let interrupt = channels[HIDSDPRecord.interruptPSM] else { return false }
            return int32(interrupt, "socketFD") == interruptFD
        }.flatMap { state.controlSockets[$0.key] }
        state.lock.unlock()
        control?.didSend(report)
    }

    static func install(opened: @escaping @Sendable (Int32) -> Void, closed: @escaping @Sendable () -> Void) throws {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.onOpen = opened
        state.onClose = closed
        guard !state.patched else { return }
        guard let peerClass = NSClassFromString("CBClassicPeer") else {
            throw PhoneError.commandFailed("class CBClassicPeer not found")
        }
        let selector = NSSelectorFromString("handleMsg:args:")
        guard let method = class_getInstanceMethod(peerClass, selector) else {
            throw PhoneError.commandFailed("class CBClassicPeer does not have method handleMsg:args:")
        }
        state.originalHandleMsg = unsafeBitCast(method_getImplementation(method), to: HandleMsgIMP.self)
        method_setImplementation(method, unsafeBitCast(hookedHandleMsg, to: IMP.self))
        state.patched = true
    }

    static func handleMsg(peer: AnyObject, sel: Selector, msg: Int32, args: AnyObject?) {
        if msg == 0x1B || msg == 0x1C, let args,
           let psm = intValue(args, key: "kCBMsgArgPSM"),
           psm == Int(HIDSDPRecord.controlPSM) || psm == Int(HIDSDPRecord.interruptPSM) {
            HIDLog.write("CBClassicPeer handleMsg=\(msg) args=\(args)")
            handleChannelMessage(peer: peer, msg: msg, args: args)
            return
        }
        state.lock.lock()
        let original = state.originalHandleMsg
        state.lock.unlock()
        original?(peer, sel, msg, args)
    }

    static func makeManager() throws -> AnyObject {
        _ = CBCentralManager.self
        guard let managerClass = NSClassFromString("CBClassicManager") else {
            throw PhoneError.commandFailed("class CBClassicManager not found")
        }
        let queue = DispatchQueue(label: "com.quietlabs.phone-use.hid")
        let privileged: [String: Any] = ["kCBMsgArgIsPrivilegedDaemon": kCFBooleanTrue as Any]
        if let manager = initManager(managerClass, queue: queue, options: privileged) {
            return manager
        }
        if let manager = initManager(managerClass, queue: queue, options: [:]) {
            return manager
        }
        throw PhoneError.commandFailed("CBClassicManager init failed")
    }

    static func waitUntilPowered(_ manager: AnyObject) {
        invokeObject(manager, "alertUserNotificationIsReady:", nil)
        invokeBlock(manager, "setConnectCallback:", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)
        invokeBlock(manager, "setDisconnectCallback:", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)
        _ = manager.perform(NSSelectorFromString("sendLocalDeviceStateRequest"))
        for _ in 0..<40 {
            if powerState(manager) >= 2 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func powerState(_ manager: AnyObject) -> Int {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let selector = NSSelectorFromString("powerState")
        guard let method = class_getInstanceMethod(object_getClass(manager), selector) else { return -1 }
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(manager, selector)
    }

    private static func invokeObject(_ object: AnyObject, _ name: String, _ value: Any?) {
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value as AnyObject?)
    }

    private static func initManager(_ managerClass: AnyClass, queue: DispatchQueue, options: [String: Any]) -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(managerClass, allocSelector) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(managerClass, allocSelector)
        return invoke(
            allocated.takeUnretainedValue(),
            "initWithQueue:options:",
            queue,
            options as NSDictionary
        )
    }

    static func addService(_ record: [UInt8], to manager: AnyObject) -> UInt32 {
        let data = Data(record) as NSData
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> UInt32
        let selector = NSSelectorFromString("addServiceWithData:")
        guard let method = class_getInstanceMethod(object_getClass(manager), selector) else { return 0 }
        let imp = unsafeBitCast(method_getImplementation(method), to: Add.self)
        return imp(manager, selector, data)
    }

    static func setDiscoverable(_ value: Bool, on manager: AnyObject) {
        invokeBool(manager, "setBTDiscoverable:", value)
        invokeBool(manager, "setBTConnectable:", value)
    }

    static func setConnectable(_ value: Bool, on manager: AnyObject) {
        invokeBool(manager, "setBTConnectable:", value)
    }

    private static func handleChannelMessage(peer: AnyObject, msg: Int32, args: AnyObject) {
        if msg == 0x1B {
            setL2CAPCallbacks(on: peer)
            _ = peer.perform(NSSelectorFromString("handleL2CAPChannelOpened:"), with: args)
            return
        }
        _ = peer.perform(NSSelectorFromString("handleL2CAPChannelClosed:"), with: args)
    }

    private static func setL2CAPCallbacks(on peer: AnyObject) {
        // IOBluetooth installs callbacks that wrap and retain these channels.
        // Replacing them prevents its registered listeners from accepting them.
        guard objectValue(peer, "connectL2CAPCallback") == nil,
              objectValue(peer, "disconnectL2CAPCallback") == nil else { return }
        let peerID = ObjectIdentifier(peer)
        let opened: @convention(block) (AnyObject?, Int) -> Void = { channel, status in
            guard status == 0, let channel else { return }
            let psm = uint16(channel, "PSM")
            guard psm == HIDSDPRecord.controlPSM || psm == HIDSDPRecord.interruptPSM else { return }
            // CBClassicPeer's channel table is weak. Retain both HID channels,
            // including control, until CoreBluetooth delivers their close.
            state.lock.lock()
            state.channels[peerID, default: [:]][psm] = channel
            state.lock.unlock()
            let fd = int32(channel, "socketFD")
            guard fd >= 0 else { return }
            if psm == HIDSDPRecord.controlPSM {
                do {
                    let control = try HIDControlSocket(fd: fd)
                    state.lock.lock()
                    let old = state.controlSockets.updateValue(control, forKey: peerID)
                    state.lock.unlock()
                    old?.stop()
                } catch {
                    FileHandle.standardError.write(Data("phone-use hid: control channel failed: \(error)\n".utf8))
                }
            } else {
                notifyOpen(fd)
            }
        }
        let closed: @convention(block) (AnyObject?, Int) -> Void = { channel, _ in
            guard let channel else { return }
            let psm = uint16(channel, "PSM")
            state.lock.lock()
            let retained = state.channels[peerID]?[psm]
            var control: HIDControlSocket?
            if retained === channel {
                if psm == HIDSDPRecord.controlPSM {
                    control = state.controlSockets.removeValue(forKey: peerID)
                }
                state.channels[peerID]?.removeValue(forKey: psm)
                if state.channels[peerID]?.isEmpty == true {
                    state.channels.removeValue(forKey: peerID)
                }
            }
            state.lock.unlock()
            control?.stop()
            guard retained === channel else { return }
            guard psm == HIDSDPRecord.interruptPSM else { return }
            notifyClose()
        }
        invokeBlock(peer, "setConnectL2CAPCallback:", opened)
        invokeBlock(peer, "setDisconnectL2CAPCallback:", closed)
    }

    private static func objectValue(_ object: AnyObject, _ name: String) -> AnyObject? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }

    private static func intValue(_ args: AnyObject, key: String) -> Int? {
        (args as? NSDictionary)?[key] as? Int ?? ((args as? NSDictionary)?[key] as? NSNumber)?.intValue
    }

    private static func invoke(_ object: AnyObject, _ name: String, _ a: Any, _ b: Any) -> AnyObject? {
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: Init.self)
        return imp(object, selector, a as AnyObject, b as AnyObject)?.takeRetainedValue()
    }

    private static func invokeBool(_ object: AnyObject, _ name: String, _ value: Bool) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
    }

    private static func invokeBlock(_ object: AnyObject, _ name: String, _ block: Any) {
        typealias Setter = @convention(c) (AnyObject, Selector, Any) -> Void
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, block)
    }

    private static func uint16(_ object: AnyObject, _ name: String) -> UInt16 {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt16
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return 0 }
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }

    private static func int32(_ object: AnyObject, _ name: String) -> Int32 {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return -1 }
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }

    private static func notifyOpen(_ fd: Int32) {
        state.lock.lock()
        let open = state.onOpen
        state.lock.unlock()
        open?(fd)
    }

    private static func notifyClose() {
        state.lock.lock()
        let close = state.onClose
        state.lock.unlock()
        close?()
    }
}

/// Lock-protected mutable hook state. CoreBluetooth delivers `handleMsg:args:`
/// on its own queue, so this cannot live in the `ClassicHIDHost` actor.
private final class HIDRuntimeState: @unchecked Sendable {
    let lock = NSLock()
    var originalHandleMsg: HandleMsgIMP?
    var patched = false
    var onOpen: (@Sendable (Int32) -> Void)?
    var onClose: (@Sendable () -> Void)?
    var channels: [ObjectIdentifier: [UInt16: AnyObject]] = [:]
    var controlSockets: [ObjectIdentifier: HIDControlSocket] = [:]
}

private typealias HandleMsgIMP = @convention(c) (AnyObject, Selector, Int32, AnyObject?) -> Void

private let hookedHandleMsg: HandleMsgIMP = { peer, sel, msg, args in
    HIDRuntime.handleMsg(peer: peer, sel: sel, msg: msg, args: args)
}
