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

    public func isHostConnected() async -> Bool { interruptFD >= 0 }

    public func send(_ report: HIDReport) async throws {
        try startAdvertising()
        guard interruptFD >= 0 else {
            throw PhoneError.inputNotConnected(
                "No iPhone is connected over Bluetooth HID. Enable AssistiveTouch, open Settings > Bluetooth on the phone, and pair '\(HIDSDPRecord.serviceName)'."
            )
        }
        try HIDSocket.write(HIDP.interruptPacket(for: report), to: interruptFD)
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
            let handle: UInt32 = HIDRuntime.addService(HIDSDPRecord.bytes, to: manager)
            guard handle != 0 else {
                throw PhoneError.commandFailed("Bluetooth HID service registration failed")
            }
            HIDRuntime.setDiscoverable(true, on: manager)
            HIDRuntime.setConnectable(true, on: manager)
            self.manager = manager
        } catch let error as PhoneError {
            startError = error
            throw error
        } catch {
            let wrapped = PhoneError.commandFailed("Bluetooth HID host failed to start: \(error)")
            startError = wrapped
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
        try packet.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else {
                throw PhoneError.commandFailed("HID report send failed")
            }
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: bytes.count)
            var message = msghdr()
            let sent = withUnsafeMutablePointer(to: &iov) { iovPtr in
                message.msg_iov = iovPtr
                message.msg_iovlen = 1
                return sendmsg(fd, &message, Int32(0x80))
            }
            guard sent == bytes.count else {
                throw PhoneError.commandFailed("HID report send failed")
            }
        }
    }
}

/// Objective-C runtime glue for private CoreBluetooth Classic types.
enum HIDRuntime {
    private static let state = HIDRuntimeState()

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
        if msg == 0x1B || msg == 0x1C, let args {
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
        let psm = intValue(args, key: "kCBMsgArgPSM")
        let isInterrupt = psm == nil || psm == Int(HIDSDPRecord.interruptPSM)
        if msg == 0x1B {
            let result = intValue(args, key: "kCBMsgArgResult") ?? 0
            guard result == 0 else { return }
            setL2CAPCallbacks(on: peer)
            _ = peer.perform(NSSelectorFromString("handleL2CAPChannelOpened:"), with: args)
            if isInterrupt {
                if let fd = socketFD(from: peer, psm: HIDSDPRecord.interruptPSM) ?? socketFD(fromOpenedArgs: args) {
                    notifyOpen(fd)
                }
            }
            return
        }
        _ = peer.perform(NSSelectorFromString("handleL2CAPChannelClosed:"), with: args)
        if isInterrupt {
            notifyClose()
        }
    }

    private static func setL2CAPCallbacks(on peer: AnyObject) {
        let opened: @convention(block) (AnyObject?, Int) -> Void = { channel, status in
            guard status == 0, let channel else { return }
            let psm = uint16(channel, "PSM")
            guard psm == HIDSDPRecord.interruptPSM else { return }
            let fd = int32(channel, "socketFD")
            guard fd >= 0 else { return }
            notifyOpen(fd)
        }
        let closed: @convention(block) (AnyObject?, Int) -> Void = { channel, _ in
            let psm = channel.map { uint16($0, "PSM") } ?? HIDSDPRecord.interruptPSM
            guard psm == HIDSDPRecord.interruptPSM else { return }
            notifyClose()
        }
        invokeBlock(peer, "setConnectL2CAPCallback:", opened)
        invokeBlock(peer, "setDisconnectL2CAPCallback:", closed)
    }

    private static func socketFD(from peer: AnyObject, psm: UInt16) -> Int32? {
        typealias ChannelForPSM = @convention(c) (AnyObject, Selector, UInt16) -> AnyObject?
        let selector = NSSelectorFromString("channelWithPSM:")
        guard let method = class_getInstanceMethod(object_getClass(peer), selector) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: ChannelForPSM.self)
        guard let channel = imp(peer, selector, psm) else { return nil }
        let fd = int32(channel, "socketFD")
        return fd >= 0 ? fd : nil
    }

    private static func socketFD(fromOpenedArgs args: AnyObject) -> Int32? {
        if let number = (args as? NSDictionary)?["kCBMsgArgSocketFD"] as? NSNumber { return number.int32Value }
        return nil
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
}

private typealias HandleMsgIMP = @convention(c) (AnyObject, Selector, Int32, AnyObject?) -> Void

private let hookedHandleMsg: HandleMsgIMP = { peer, sel, msg, args in
    HIDRuntime.handleMsg(peer: peer, sel: sel, msg: msg, args: args)
}
