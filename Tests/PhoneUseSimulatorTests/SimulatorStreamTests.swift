import CoreGraphics
import Foundation
import Testing
import PhoneUseCapture
import PhoneUseCore
@testable import PhoneUseSimulator

private func prefixed(_ payload: [UInt8]) -> Data {
    let length = UInt32(payload.count)
    return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)] + payload)
}

@Test func lengthPrefixedFramesSurviveArbitraryChunking() throws {
    let stream = prefixed([1, 2, 3]) + prefixed([]) + prefixed(Array(repeating: 9, count: 300))
    for chunkSize in [1, 2, 5, 7, 64, stream.count] {
        var parser = LengthPrefixedFrames()
        var frames: [Data] = []
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + chunkSize)
            frames += try parser.append(stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(frames == [Data([1, 2, 3]), Data(), Data(repeating: 9, count: 300)])
    }
}
@Test func lengthPrefixedFramesRejectOversizedFrames() {
    var parser = LengthPrefixedFrames()
    #expect(throws: PhoneError.self) { _ = try parser.append(Data([0xff, 0xff, 0xff, 0xff])) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PHONE_USE_SIM_UDID"] != nil))
func liveSimulatorStreamDeliversNativeFrames() async throws {
    let udid = try #require(ProcessInfo.processInfo.environment["PHONE_USE_SIM_UDID"])
    let axe = ProcessInfo.processInfo.environment["PHONE_USE_AXE"] ?? "axe"
    let phone = SimulatorPhone(udid: udid, name: "Live", screenSize: .init(width: 1, height: 1), pointScale: 3, axe: axe)
    var frames = try await phone.liveFrames().makeAsyncIterator()
    let first = try #require(await frames.next())
    let second = try #require(await frames.next())
    #expect(first.width > 300 && first.height > first.width)
    #expect(second.width == first.width)
}
