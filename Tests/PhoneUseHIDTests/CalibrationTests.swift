import Foundation
import Testing
import PhoneUseCore
@testable import PhoneUseHID

struct CalibrationTests {
    @Test func findsSeparateChangedCursorBlobs() {
        let threshold: UInt8 = 40
        let blobs = CursorLocator.changedBlobs(before: square(width: 200, height: 200, x: 20, y: 20, side: 10), after: square(width: 200, height: 200, x: 120, y: 20, side: 10), width: 200, height: 200, threshold: threshold)
        #expect(blobs.count == 2)
        #expect(blobs.contains(Blob(centroid: (24.5, 24.5), pixelCount: 100)))
        #expect(blobs.contains(Blob(centroid: (124.5, 24.5), pixelCount: 100)))
    }
    @Test func malformedFramesReturnNoBlobs() {
        #expect(CursorLocator.changedBlobs(before: [0], after: [], width: 1, height: 1).isEmpty)
        #expect(CursorLocator.changedBlobs(before: [], after: [], width: Int.max, height: 2).isEmpty)
        #expect(CursorLocator.changedBlobs(before: [], after: [], width: -1, height: 2).isEmpty)
    }
    @Test func absolutePointerSkipsCalibrationWithoutIO() async {
        let calls = CalibrationCalls()
        await #expect(throws: PhoneError.commandFailed("Absolute pointer does not need calibration")) {
            try await PointerCalibration.run(send: { _ in try await calls.send() },
                capture: { try await calls.capture() }, base: PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1))
        }
        #expect(await calls.sends == 0)
        #expect(await calls.captures == 0)
    }
}

private func square(width: Int, height: Int, x: Int, y: Int, side: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: width * height)
    for row in y..<min(height, y + side) {
        for col in x..<min(width, x + side) { data[row * width + col] = 255 }
    }
    return data
}

private actor CalibrationCalls {
    var sends = 0
    var captures = 0
    func send() throws {
        sends += 1
        throw PhoneError.commandFailed("unexpected send")
    }
    func capture() throws -> PixelFrame {
        captures += 1
        throw PhoneError.commandFailed("unexpected capture")
    }
}

@Test func calibrationRejectsInvalidGainsBeforeAnyIO() async {
    let calls = CalibrationCalls()
    await #expect(throws: PhoneError.self) {
        try await PointerCalibration.run(send: { _ in try await calls.send() },
            capture: { try await calls.capture() },
            base: PointerGains(pixelsPerCountX: 0, pixelsPerCountY: 1))
    }
    #expect(await calls.sends == 0)
    #expect(await calls.captures == 0)
}
