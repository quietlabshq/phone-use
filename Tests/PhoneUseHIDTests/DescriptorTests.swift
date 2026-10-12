import Testing
@testable import PhoneUseHID

struct DescriptorTests {
    @Test func descriptorHasBalancedCollectionsAndExpectedReportWidths() throws {
        let bytes = ReportDescriptor.bytes
        var offset = 0
        var depth = 0
        var reportID = 0
        var size = 0
        var count = 0
        var inputBits: [Int: Int] = [:]
        while offset < bytes.count {
            let prefix = bytes[offset]
            offset += 1
            let length = prefix & 3 == 3 ? 4 : Int(prefix & 3)
            try #require(offset + length <= bytes.count)
            var value = 0
            for index in 0..<length {
                value |= Int(bytes[offset + index]) << (8 * index)
            }
            offset += length
            switch prefix & 0xFC {
            case 0x84: reportID = value
            case 0x74: size = value
            case 0x94: count = value
            case 0x80: inputBits[reportID, default: 0] += size * count
            case 0xA0: depth += 1
            case 0xC0:
                depth -= 1
                #expect(depth >= 0)
            default: break
            }
        }
        #expect(depth == 0)
        #expect(inputBits == [1: 64, 2: 32, 3: 16])
    }
}
