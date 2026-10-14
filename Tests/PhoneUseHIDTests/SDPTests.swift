import Testing
@testable import PhoneUseHID

struct SDPTests {
    @Test func hidRecordAdvertisesKeyboardMouseAndTheReportDescriptor() throws {
        let record = HIDSDPRecord.bytes
        let attributes = try SDPDecoder.attributes(in: record)
        #expect(attributes[0x0001] != nil, "ServiceClassIDList")
        #expect(containsUUID16(attributes[0x0001]!, 0x1124))
        #expect(containsPSM(attributes[0x0004]!, 0x0011), "HID control channel")
        #expect(containsPSM(attributes[0x000D]!, 0x0013), "HID interrupt channel")
        #expect(containsUUID16(attributes[0x0009]!, 0x1124), "HID profile")
        let descriptor = try #require(hidDescriptor(in: attributes[0x0206]!))
        #expect(descriptor == ReportDescriptor.bytes)
        #expect(String(bytes: stringValue(attributes[0x0100]!) ?? [], encoding: .utf8) == "phone-use HID Interface")
    }
}

private func containsUUID16(_ value: [UInt8], _ uuid: UInt16) -> Bool {
    let needle: [UInt8] = [0x19, UInt8(uuid >> 8), UInt8(truncatingIfNeeded: uuid)]
    return value.windows(ofCount: 3).contains(where: { Array($0) == needle })
}

private func containsPSM(_ value: [UInt8], _ psm: UInt16) -> Bool {
    let needle: [UInt8] = [0x09, UInt8(psm >> 8), UInt8(truncatingIfNeeded: psm)]
    return value.windows(ofCount: 3).contains(where: { Array($0) == needle })
}

private func hidDescriptor(in value: [UInt8]) -> [UInt8]? {
    guard let index = value.firstIndex(of: 0x22) else { return nil }
    return SDPDecoder.consumeData(Array(value[(index + 1)...]))
}

private func stringValue(_ value: [UInt8]) -> [UInt8]? {
    SDPDecoder.consumeString(value)
}

private enum SDPDecoder {
    static func attributes(in record: [UInt8]) throws -> [UInt16: [UInt8]] {
        var bytes = record
        let body = try consumeSequence(&bytes)
        var attributes: [UInt16: [UInt8]] = [:]
        var rest = body
        while !rest.isEmpty {
            guard rest[0] == 0x09, rest.count >= 3 else {
                throw SDPError.malformed
            }
            let id = UInt16(rest[1]) << 8 | UInt16(rest[2])
            rest.removeFirst(3)
            let value = try consumeElement(&rest)
            attributes[id] = value
        }
        return attributes
    }

    static func consumeData(_ bytes: [UInt8]) -> [UInt8]? {
        var rest = bytes
        return try? consumeData(&rest)
    }

    static func consumeString(_ bytes: [UInt8]) -> [UInt8]? {
        var rest = bytes
        return try? consumeString(&rest)
    }

    private static func consumeSequence(_ bytes: inout [UInt8]) throws -> [UInt8] {
        try consumeSized(&bytes, headers: [0x35: 1, 0x36: 2, 0x37: 4])
    }

    private static func consumeData(_ bytes: inout [UInt8]) throws -> [UInt8] {
        try consumeSized(&bytes, headers: [0x25: 1, 0x26: 2, 0x27: 4])
    }

    private static func consumeString(_ bytes: inout [UInt8]) throws -> [UInt8] {
        try consumeSized(&bytes, headers: [0x25: 1, 0x26: 2, 0x27: 4])
    }

    private static func consumeElement(_ bytes: inout [UInt8]) throws -> [UInt8] {
        guard let header = bytes.first else { throw SDPError.malformed }
        let start = bytes
        switch header {
        case 0x08: try skip(&bytes, 2)
        case 0x09: try skip(&bytes, 3)
        case 0x0A: try skip(&bytes, 5)
        case 0x0B: try skip(&bytes, 9)
        case 0x19: try skip(&bytes, 3)
        case 0x1A: try skip(&bytes, 5)
        case 0x1C: try skip(&bytes, 17)
        case 0x28: try skip(&bytes, 2)
        case 0x25, 0x26, 0x27, 0x35, 0x36, 0x37:
            _ = try consumeSized(&bytes, headers: [
                0x25: 1, 0x26: 2, 0x27: 4,
                0x35: 1, 0x36: 2, 0x37: 4,
            ])
        default:
            throw SDPError.malformed
        }
        return Array(start.prefix(start.count - bytes.count))
    }

    private static func consumeSized(_ bytes: inout [UInt8], headers: [UInt8: Int]) throws -> [UInt8] {
        guard let header = bytes.first, let sizeBytes = headers[header], bytes.count >= 1 + sizeBytes else {
            throw SDPError.malformed
        }
        var length = 0
        for index in 1...sizeBytes {
            length = (length << 8) | Int(bytes[index])
        }
        guard bytes.count >= 1 + sizeBytes + length else { throw SDPError.malformed }
        let payload = Array(bytes[(1 + sizeBytes)..<(1 + sizeBytes + length)])
        bytes.removeFirst(1 + sizeBytes + length)
        return payload
    }

    private static func skip(_ bytes: inout [UInt8], _ count: Int) throws {
        guard bytes.count >= count else { throw SDPError.malformed }
        bytes.removeFirst(count)
    }
}

private enum SDPError: Error { case malformed }

private extension Array {
    func windows(ofCount count: Int) -> [[Element]] {
        guard self.count >= count else { return [] }
        return (0...(self.count - count)).map { Array(self[$0..<($0 + count)]) }
    }
}
