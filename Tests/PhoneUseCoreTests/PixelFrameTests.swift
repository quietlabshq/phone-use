import Foundation
import Testing
@testable import PhoneUseCore

@Test func frameAcceptsPaddedRowsAndPreservesMetadata() throws {
    let freshness = FrameFreshness(sequence: 42, capturedAtNanoseconds: 1234)
    let frame = try PixelFrame(width: 2, height: 2, rowStride: 12,
                               pixels: Data([1, 0, 0, 255, 2, 0, 0, 255, 9, 9, 9, 9,
                                             3, 0, 0, 255, 4, 0, 0, 255, 9, 9, 9, 9]),
                               freshness: freshness)
    #expect(frame.rowStride == 12)
    #expect(try frame.upright() == frame)
    #expect(frame.freshness == freshness)
}

@Test func frameRotatesIntoUprightDisplayCoordinates() throws {
    let source = Data([1, 0, 0, 255, 2, 0, 0, 255,
                       3, 0, 0, 255, 4, 0, 0, 255])
    let right = try PixelFrame(width: 2, height: 2, rowStride: 8, orientation: .right, pixels: source).upright()
    #expect(right.orientation == .up)
    #expect(right.pixels == Data([3, 0, 0, 255, 1, 0, 0, 255,
                                  4, 0, 0, 255, 2, 0, 0, 255]))

    let left = try PixelFrame(width: 2, height: 2, rowStride: 8, orientation: .left, pixels: source).upright()
    #expect(left.pixels == Data([2, 0, 0, 255, 4, 0, 0, 255,
                                 1, 0, 0, 255, 3, 0, 0, 255]))
}

@Test func frameRejectsInvalidDimensionsStrideAndBufferLength() {
    #expect(throws: PhoneError.invalidFrame("Frame dimensions must be positive")) {
        try PixelFrame(width: 0, height: 1, rowStride: 0, pixels: Data())
    }
    #expect(throws: (any Error).self) {
        try PixelFrame(width: 2, height: 1, rowStride: 7, pixels: Data(repeating: 0, count: 7))
    }
    #expect(throws: (any Error).self) {
        try PixelFrame(width: 2, height: 2, rowStride: 8, pixels: Data(repeating: 0, count: 15))
    }
    #expect(throws: (any Error).self) {
        try PixelFrame(width: Int.max, height: 2, rowStride: Int.max, pixels: Data())
    }
}
