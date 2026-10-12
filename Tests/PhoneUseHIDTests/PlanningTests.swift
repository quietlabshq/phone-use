import Testing
import PhoneUseCore
@testable import PhoneUseHID

struct PlanningTests {
    let gains = PointerGains(pixelsPerCountX: 2, pixelsPerCountY: 2)
    @Test func boundedMovement() {
        let reports = PointerPlanner.move(to: PixelPoint(x: 100, y: 50), gains: gains)
        let mice = reports.compactMap { if case .mouse(let mouse) = $0.report { mouse } else { nil } }
        #expect(mice.reduce(0) { $0 + Int($1.dx) } == 50)
        #expect(mice.reduce(0) { $0 + Int($1.dy) } == 25)
        #expect(mice.allSatisfy { abs(Int($0.dx)) <= 8 && abs(Int($0.dy)) <= 8 })
        #expect(reports.allSatisfy { $0.delayAfterMs == 8 })
        #expect(PointerPlanner.resetToCorner().count == 40)
    }
    @Test func tapAndHoldRelease() {
        let tap = PointerPlanner.tap(PixelPoint(x: 10, y: 10), count: 2, gains: gains)
        #expect(tap.filter { $0.report.payload[0] == 1 }.count == 2)
        #expect(tap.suffix(4).map(\.delayAfterMs) == [60, 80, 60, 80])
        #expect(tap.last?.report.payload[0] == 0)
        let hold = PointerPlanner.longPress(PixelPoint(x: 0, y: 0), ms: 999, gains: gains)
        #expect(hold.suffix(2).map(\.delayAfterMs) == [999, 0])
    }
    @Test func swipeMovesBackwardsWithExactDuration() {
        let reports = PointerPlanner.swipe(from: PixelPoint(x: 100, y: 80), to: PixelPoint(x: 0, y: 0), ms: 301, gains: gains)
        let drag = reports.filter { $0.report.payload[0] == 1 }
        #expect(drag.reduce(0) { $0 + $1.delayAfterMs } == 301)
        #expect(drag.reduce(0) { $0 + Int(Int8(bitPattern: $1.report.payload[1])) } == -50)
        #expect(reports.last?.report.payload[0] == 0)
    }
    @Test func rejectsInvalidGains() {
        for value in [0.0, -1, .nan, .infinity] {
            #expect(throws: PhoneError.self) { try PointerGains(pixelsPerCountX: value, pixelsPerCountY: 1).validate() }
        }
        #expect(throws: PhoneError.self) { try PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1, stepCounts: 128).validate() }
    }
    @Test func keyboardPressesAndReleases() throws {
        let reports = try KeyboardDriver.type("aA")
        #expect(reports.map(\.report) == [.keyboard(KeyboardReport(modifiers: 0, keys: [4])), .keyboard(.empty), .keyboard(KeyboardReport(modifiers: 2, keys: [4])), .keyboard(.empty)])
        #expect(KeyboardDriver.key(.enter, modifiers: [.command], repeat: 2).count == 4)
        #expect(throws: PhoneError.self) { try KeyboardDriver.type("😀") }
    }
}
