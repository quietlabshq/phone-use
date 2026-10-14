import Darwin
import Foundation
import IOBluetooth
import PhoneUseCore
import PhoneUseHID

enum HIDLog {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data("phone-use hid: \(message)\n".utf8))
    }
}

/// Public IOBluetooth advertising: HID SDP, peripheral Class of Device, and
/// incoming L2CAP channels. Used when `CBClassicManager addServiceWithData:`
/// returns a zero handle so iOS sees a keyboard instead of a computer.
final class HIDAdvertiser: NSObject, @unchecked Sendable {
    static let shared = HIDAdvertiser()

    /// Limited Discoverable + Peripheral + keyboard/mouse combo.
    static let peripheralClassOfDevice: BluetoothClassOfDevice = 0x25C0

    private let lock = NSLock()
    private var sdpRecord: IOBluetoothSDPServiceRecord?
    private var notifications: [IOBluetoothUserNotification] = []
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var controlChannel: IOBluetoothL2CAPChannel?
    private var classRefresh: DispatchSourceTimer?
    private var onInterrupt: (@Sendable (Bool) -> Void)?
    private var runLoopThread: Thread?
    private var startError: Error?

    func start(onInterrupt: @escaping @Sendable (Bool) -> Void) throws {
        lock.lock()
        self.onInterrupt = onInterrupt
        lock.unlock()
        let thread = ensureRunLoopThread()
        startError = nil
        perform(
            #selector(startOnRunLoop),
            on: thread,
            with: nil,
            waitUntilDone: true,
            modes: [RunLoop.Mode.default.rawValue]
        )
        if let startError { throw startError }
    }

    private func ensureRunLoopThread() -> Thread {
        lock.lock()
        if let runLoopThread {
            lock.unlock()
            return runLoopThread
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            RunLoop.current.add(Port(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "phone-use.hid-advertiser"
        thread.qualityOfService = .userInitiated
        runLoopThread = thread
        lock.unlock()
        thread.start()
        ready.wait()
        return thread
    }

    @objc private func startOnRunLoop() {
        do {
            try publishSDP()
            applyClassOfDevice()
            registerChannels()
            startClassRefresh()
        } catch {
            startError = error
        }
    }

    func hasInterruptChannel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptChannel != nil
    }

    func writeInterrupt(_ packet: [UInt8]) throws {
        lock.lock()
        let channel = interruptChannel
        lock.unlock()
        guard let channel else {
            throw PhoneError.inputNotConnected(
                "No iPhone is connected over Bluetooth HID. Enable AssistiveTouch, open Settings > Bluetooth on the phone, and pair '\(HIDSDPRecord.serviceName)'."
            )
        }
        let status = packet.withUnsafeBytes { bytes -> IOReturn in
            guard let base = bytes.baseAddress else { return kIOReturnError }
            return channel.writeSync(UnsafeMutableRawPointer(mutating: base), length: UInt16(packet.count))
        }
        guard status == kIOReturnSuccess else {
            throw PhoneError.commandFailed("HID report send failed")
        }
    }

    private func publishSDP() throws {
        guard let record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: HIDSDPRecord.ioBluetoothDictionary) else {
            throw PhoneError.commandFailed("Bluetooth HID service registration failed")
        }
        var handle: BluetoothSDPServiceRecordHandle = 0
        let handleStatus = record.getHandle(&handle)
        HIDLog.write(
            "published SDP name=\(record.getServiceName() ?? "nil") handleStatus=\(handleStatus) handle=\(handle)"
        )
        lock.lock()
        sdpRecord = record
        lock.unlock()
    }

    private func applyClassOfDevice() {
        guard let controller = IOBluetoothHostController.default() else {
            HIDLog.write("no IOBluetoothHostController")
            return
        }
        let status = controller.setClassOfDevice(Self.peripheralClassOfDevice, forTimeInterval: 120)
        HIDLog.write(
            "setClassOfDevice status=\(status) want=\(String(format: "0x%X", Self.peripheralClassOfDevice)) now=\(String(format: "0x%X", controller.classOfDevice()))"
        )
    }

    private func startClassRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 90, repeating: 90)
        timer.setEventHandler { [weak self] in self?.applyClassOfDevice() }
        timer.resume()
        lock.lock()
        classRefresh = timer
        lock.unlock()
    }

    private func registerChannels() {
        let incoming = IOBluetoothUserNotificationChannelDirection(rawValue: 1)
        let control = IOBluetoothL2CAPChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(controlOpened(_:channel:)),
            withPSM: HIDSDPRecord.controlPSM,
            direction: incoming
        )
        let interrupt = IOBluetoothL2CAPChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(interruptOpened(_:channel:)),
            withPSM: HIDSDPRecord.interruptPSM,
            direction: incoming
        )
        HIDLog.write(
            "L2CAP listen control=\(control != nil) interrupt=\(interrupt != nil) thread=\(Thread.current.name ?? "?") runLoop=\(CFRunLoopGetCurrent() === CFRunLoopGetMain() ? "main" : "background")"
        )
        lock.lock()
        if let control { notifications.append(control) }
        if let interrupt { notifications.append(interrupt) }
        lock.unlock()
    }

    @objc private func controlOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        channel.setDelegate(self)
        lock.lock()
        controlChannel = channel
        lock.unlock()
        HIDLog.write("HID control channel opened psm=\(channel.psm)")
    }

    @objc private func interruptOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        channel.setDelegate(self)
        lock.lock()
        interruptChannel = channel
        let callback = onInterrupt
        lock.unlock()
        HIDLog.write("HID interrupt channel opened psm=\(channel.psm)")
        callback?(true)
    }
}

extension HIDAdvertiser: IOBluetoothL2CAPChannelDelegate {
    func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard dataLength > 0 else { return }
        let header = dataPointer.load(as: UInt8.self)
        HIDLog.write("HIDP psm=\(l2capChannel.psm) header=0x\(String(header, radix: 16)) len=\(dataLength)")
        guard l2capChannel === controlChannel else { return }
        if header & 0xF0 == 0x70 {
            var handshake: UInt8 = 0x00
            _ = l2capChannel.writeSync(&handshake, length: 1)
        }
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        HIDLog.write("L2CAP closed psm=\(l2capChannel.psm)")
        lock.lock()
        if l2capChannel === interruptChannel {
            interruptChannel = nil
            let callback = onInterrupt
            lock.unlock()
            callback?(false)
            return
        }
        if l2capChannel === controlChannel {
            controlChannel = nil
        }
        lock.unlock()
    }
}
