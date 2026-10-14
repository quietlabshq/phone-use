import Foundation

/// Bluetooth SDP record that advertises this Mac as a Classic HID keyboard and
/// mouse. `addServiceWithData:` publishes these bytes.
public enum HIDSDPRecord {
    public static let serviceName = "phone-use HID Interface"
    public static let controlPSM: UInt16 = 0x0011
    public static let interruptPSM: UInt16 = 0x0013

    public static let bytes: [UInt8] = encode([
        (0x0001, sequence([uuid16(0x1124)])),
        (0x0004, protocolList(psm: controlPSM)),
        (0x0005, sequence([uuid16(0x1002)])),
        (0x0006, sequence([uint16(0x656E), uint16(0x006A), uint16(0x0100)])),
        (0x0009, sequence([sequence([uuid16(0x1124), uint16(0x0101)])])),
        (0x000D, sequence([protocolList(psm: interruptPSM)])),
        (0x0100, string(serviceName)),
        (0x0200, uint16(0x0100)),
        (0x0201, uint16(0x0111)),
        (0x0202, uint8(0xC0)),
        (0x0203, uint8(0x21)),
        (0x0204, bool(true)),
        (0x0205, bool(true)),
        (0x0206, hidDescriptorList),
        (0x0207, sequence([sequence([uint16(0x0409), uint16(0x0100)])])),
        (0x0208, bool(false)),
        (0x0209, bool(false)),
        (0x020A, bool(true)),
        (0x020B, uint16(0x0101)),
        (0x020C, uint16(0x1F40)),
        (0x020D, bool(true)),
        (0x020E, bool(true)),
    ])

    private static var hidDescriptorList: [UInt8] {
        sequence([sequence([uint8(0x22), data(ReportDescriptor.bytes)])])
    }

    /// IOBluetooth `publishedServiceRecord(with:)` dictionary for the same HID
    /// record. Used when `addServiceWithData:` returns a zero handle.
    public static var ioBluetoothDictionary: [String: Any] {
        [
            "0x0001 - ServiceClassIDList": [uuidData(0x1124)],
            "0x0004 - ProtocolDescriptorList": protocolDict(psm: controlPSM),
            "0x0005 - BrowseGroupList": [uuidData(0x1002)],
            "0x0006 - LanguageBaseAttributeIDList": [uint16Dict(0x656E), uint16Dict(0x006A), uint16Dict(0x0100)],
            "0x0009 - BluetoothProfileDescriptorList": [[uuidData(0x1124), uint16Dict(0x0101)]],
            "0x000D - AdditionalProtocolDescriptorLists": [protocolDict(psm: interruptPSM)],
            "0x0100 - ServiceName": serviceName,
            "0x0200 - HIDParserVersion": uint16Dict(0x0100),
            "0x0201 - HIDDeviceSubclass": uint16Dict(0x0111),
            "0x0202 - HIDCountryCode": uint8Dict(0xC0),
            "0x0203 - HIDVirtualCable": uint8Dict(0x21),
            "0x0204 - HIDReconnectInitiate": boolDict(true),
            "0x0205 - HIDSDPDisable": boolDict(true),
            "0x0206 - HIDDescriptorList": [[uint8Dict(0x22), dataDict(ReportDescriptor.bytes)]],
            "0x0207 - HIDLANGIDBaseList": [[uint16Dict(0x0409), uint16Dict(0x0100)]],
            "0x0208 - HIDBatteryPower": boolDict(false),
            "0x0209 - HIDRemoteWake": boolDict(false),
            "0x020A - HIDNormallyConnectable": boolDict(true),
            "0x020B - HIDBootDevice": uint16Dict(0x0101),
            "0x020C - HIDSupervisionTimeout": uint16Dict(0x1F40),
            "0x020D - HIDSSRHostMaxLatency": boolDict(true),
            "0x020E - HIDSSRHostMinTimeout": boolDict(true),
        ]
    }
}

private func encode(_ attributes: [(UInt16, [UInt8])]) -> [UInt8] {
    sequence(attributes.map { uint16($0.0) + $0.1 })
}

private func sequence(_ elements: [[UInt8]]) -> [UInt8] {
    sized(0x35, elements.flatMap { $0 })
}

private func data(_ bytes: [UInt8]) -> [UInt8] {
    sized(0x25, bytes)
}

private func string(_ value: String) -> [UInt8] {
    sized(0x25, Array(value.utf8))
}

private func sized(_ header: UInt8, _ payload: [UInt8]) -> [UInt8] {
    if payload.count <= 0xFF {
        return [header, UInt8(payload.count)] + payload
    }
    return [header + 1, UInt8(payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)] + payload
}

private func uint8(_ value: UInt8) -> [UInt8] { [0x08, value] }
private func uint16(_ value: UInt16) -> [UInt8] { [0x09, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)] }
private func uuid16(_ value: UInt16) -> [UInt8] { [0x19, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)] }
private func bool(_ value: Bool) -> [UInt8] { [0x28, value ? 1 : 0] }

private func protocolList(psm: UInt16) -> [UInt8] {
    sequence([
        sequence([uuid16(0x0100), uint16(psm)]),
        sequence([uuid16(0x0011)]),
    ])
}

private func protocolDict(psm: UInt16) -> [[Any]] {
    [
        [uuidData(0x0100), uint16Dict(psm)],
        [uuidData(0x0011)],
    ]
}

private func uuidData(_ value: UInt16) -> Data {
    Data([UInt8(value >> 8), UInt8(truncatingIfNeeded: value)])
}

private func uint8Dict(_ value: UInt8) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": value]
}

private func uint16Dict(_ value: UInt16) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": 2, "DataElementValue": value]
}

private func boolDict(_ value: Bool) -> [String: Any] {
    ["DataElementType": 5, "DataElementValue": value ? 1 : 0]
}

private func dataDict(_ bytes: [UInt8]) -> [String: Any] {
    ["DataElementType": 4, "DataElementValue": Data(bytes)]
}
