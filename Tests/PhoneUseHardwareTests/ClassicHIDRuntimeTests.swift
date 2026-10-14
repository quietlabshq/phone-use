import Foundation
import Testing
@testable import PhoneUseHardware

private typealias ChannelCallback = @convention(block) (AnyObject?, Int) -> Void

/// CoreBluetooth keeps channels in a weak table. The recipient of its open
/// callback must retain them, as IOBluetooth's existing callbacks do.
private final class RuntimePeer: NSObject {
    @objc dynamic var connectL2CAPCallback: ChannelCallback?
    @objc dynamic var disconnectL2CAPCallback: ChannelCallback?
    let channels = NSMapTable<NSNumber, RuntimeChannel>.strongToWeakObjects()

    @objc func handleL2CAPChannelOpened(_ args: NSDictionary) {
        let status = args["kCBMsgArgResult"] as! Int
        guard status == 0 else {
            connectL2CAPCallback?(nil, status)
            return
        }
        let psm = args["kCBMsgArgPSM"] as! UInt16
        let channel = RuntimeChannel(psm: psm)
        channels.setObject(channel, forKey: NSNumber(value: psm))
        connectL2CAPCallback?(channel, 0)
    }

    @objc func handleL2CAPChannelClosed(_ args: NSDictionary) {
        let key = args["kCBMsgArgPSM"] as! NSNumber
        disconnectL2CAPCallback?(channels.object(forKey: key), 0)
        channels.removeObject(forKey: key)
    }

    @objc func channelWithPSM(_ psm: UInt16) -> RuntimeChannel? {
        channels.object(forKey: NSNumber(value: psm))
    }

    func deliver(_ message: Int32, psm: UInt16, status: Int = 0) {
        autoreleasepool {
            HIDRuntime.handleMsg(peer: self, sel: NSSelectorFromString("handleMsg:args:"), msg: message,
                                 args: ["kCBMsgArgPSM": psm, "kCBMsgArgResult": status] as NSDictionary)
        }
    }
}

private final class RuntimeChannel: NSObject {
    @objc let PSM: UInt16
    @objc let socketFD: Int32 = -1
    init(psm: UInt16) { PSM = psm }
}

@Test func existingChannelOwnerReceivesOpenAndClose() {
    let peer = RuntimePeer()
    var retained: [UInt16: AnyObject] = [:]
    var closed: [UInt16] = []
    peer.connectL2CAPCallback = { channel, _ in
        let channel = channel as! RuntimeChannel
        retained[channel.PSM] = channel
    }
    peer.disconnectL2CAPCallback = { channel, _ in
        let channel = channel as! RuntimeChannel
        closed.append(channel.PSM)
        retained.removeValue(forKey: channel.PSM)
    }
    peer.deliver(0x1B, psm: 17)
    peer.deliver(0x1B, psm: 19)
    #expect(Set(retained.keys) == [17, 19])
    #expect(peer.channelWithPSM(17) != nil)
    #expect(peer.channelWithPSM(19) != nil)
    peer.deliver(0x1C, psm: 17)
    peer.deliver(0x1C, psm: 19)
    #expect(closed == [17, 19])
    #expect(retained.isEmpty)
}

@Test func nativeChannelOwnerRetainsBothChannelsUntilTheirClose() {
    let peer = RuntimePeer()
    peer.deliver(0x1B, psm: 17)
    peer.deliver(0x1B, psm: 19)
    #expect(peer.channelWithPSM(17) != nil)
    #expect(peer.channelWithPSM(19) != nil)
    peer.deliver(0x1C, psm: 17)
    #expect(peer.channelWithPSM(17) == nil)
    #expect(peer.channelWithPSM(19) != nil)
    peer.deliver(0x1C, psm: 19)
    #expect(peer.channelWithPSM(19) == nil)
}

@Test func failedChannelOpenReachesItsExistingOwner() {
    let peer = RuntimePeer()
    var receivedStatus: Int?
    peer.connectL2CAPCallback = { channel, status in
        #expect(channel == nil)
        receivedStatus = status
    }
    peer.deliver(0x1B, psm: 17, status: 5)
    #expect(receivedStatus == 5)
    #expect(peer.channelWithPSM(17) == nil)
}

@Test func closingOnePeerKeepsTheOtherPeersChannels() {
    let first = RuntimePeer()
    let second = RuntimePeer()
    first.deliver(0x1B, psm: 17)
    second.deliver(0x1B, psm: 17)
    first.deliver(0x1C, psm: 17)
    #expect(first.channelWithPSM(17) == nil)
    #expect(second.channelWithPSM(17) != nil)
    second.deliver(0x1C, psm: 17)
    #expect(second.channelWithPSM(17) == nil)
}

@Test func unrelatedPSMDoesNotInstallHIDCallbacks() {
    let peer = RuntimePeer()
    peer.deliver(0x1B, psm: 25)
    #expect(peer.connectL2CAPCallback == nil)
    #expect(peer.disconnectL2CAPCallback == nil)
}
