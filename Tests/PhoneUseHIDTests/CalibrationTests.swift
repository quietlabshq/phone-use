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
    @Test func recoversSimulatedGain() async throws {
        let pointer = SimulatedPointer()
        let result = try await PointerCalibration.run(send: { await pointer.send($0) }, capture: { await pointer.capture() }, base: PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1))
        #expect(abs(result.pixelsPerCountX - 2.3) / 2.3 < 0.02)
        #expect(abs(result.pixelsPerCountY - 2.3) / 2.3 < 0.02)
    }
    @Test func rejectsMissingCursor() async {
        let pointer = SimulatedPointer(visible: false)
        await #expect(throws: PhoneError.commandFailed("cursor not visible in capture")) {
            try await PointerCalibration.run(send: { await pointer.send($0) }, capture: { await pointer.capture() }, base: PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1))
        }
    }
    @Test func rejectsClippedCursor() async {
        let pointer = SimulatedPointer(width: 1000, height: 1600)
        await #expect(throws: PhoneError.self) {
            try await PointerCalibration.run(send: { await pointer.send($0) }, capture: { await pointer.capture() }, base: PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1))
        }
    }
}

private func square(width: Int, height: Int, x: Int, y: Int, side: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: width * height)
    for row in y..<min(height, y + side) {
        for col in x..<min(width, x + side) { data[row * width + col] = 255 }
    }
    return data
}

private actor SimulatedPointer {
    var x = 0.0
    var y = 0.0
    let width: Int
    let height: Int
    let visible: Bool
    init(width: Int = 2400, height: Int = 2600, visible: Bool = true) {
        self.width = width
        self.height = height
        self.visible = visible
    }
    func send(_ reports: [TimedReport]) {
        for report in reports {
            guard case .mouse(let mouse) = report.report else { continue }
            x = min(Double(width - 12), max(0, x + Double(mouse.dx) * 2.3))
            y = min(Double(height - 12), max(0, y + Double(mouse.dy) * 2.3))
        }
    }
    func capture() -> PixelFrame {
        let grayscale = visible ? square(width: width, height: height, x: Int(x.rounded()), y: Int(y.rounded()), side: 12) : [UInt8](repeating: 0, count: width * height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in grayscale.indices {
            let offset = index * 4
            rgba[offset] = grayscale[index]
            rgba[offset + 1] = grayscale[index]
            rgba[offset + 2] = grayscale[index]
            rgba[offset + 3] = 255
        }
        return try! PixelFrame(width: width, height: height, rowStride: width * 4, pixels: Data(rgba))
    }
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

@Test func calibrationRejectsExcessiveCadenceBeforeAnyIO() async {
    for base in [
        PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1, stepCounts: 1, stepIntervalMs: 60_000),
        PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1, stepCounts: 8, stepIntervalMs: 801),
    ] {
        let calls = CalibrationCalls()
        await #expect(throws: PhoneError.commandFailed("Calibration cadence would take more than 60 seconds per movement")) {
            try await PointerCalibration.run(send: { _ in try await calls.send() },
                capture: { try await calls.capture() }, base: base)
        }
        #expect(await calls.sends == 0)
        #expect(await calls.captures == 0)
    }
}
