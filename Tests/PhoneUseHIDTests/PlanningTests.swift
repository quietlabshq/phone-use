import Testing
import PhoneUseCore
@testable import PhoneUseHID

struct PlanningTests {
    let bounds = PixelSize(width: 100, height: 200)

    @Test func mapsPixelsOntoTheAbsoluteHIDAxis() {
        #expect(PointerPlanner.hidPoint(PixelPoint(x: 0, y: 0), bounds: bounds) == (0, 0))
        #expect(PointerPlanner.hidPoint(PixelPoint(x: 99, y: 199), bounds: bounds) == (32767, 32767))
        #expect(PointerPlanner.hidPoint(PixelPoint(x: 50, y: 100), bounds: PixelSize(width: 101, height: 201)) == (16384, 16384))
        let reports = PointerPlanner.move(to: PixelPoint(x: 99, y: 0), bounds: bounds)
        #expect(reports.map(\.report) == [.mouse(MouseReport(buttons: 0, x: 32767, y: 0))])
    }

    @Test func tapAndHoldReleaseStayAtTheTarget() {
        let tap = PointerPlanner.tap(PixelPoint(x: 0, y: 0), count: 2, bounds: bounds)
        #expect(tap.map(\.report) == [
            .mouse(MouseReport(buttons: 0, x: 0, y: 0)),
            .mouse(MouseReport(buttons: 1, x: 0, y: 0)),
            .mouse(MouseReport.empty),
            .mouse(MouseReport(buttons: 1, x: 0, y: 0)),
            .mouse(MouseReport.empty),
        ])
        #expect(tap.map(\.delayAfterMs) == [8, 60, 80, 60, 80])
        let hold = PointerPlanner.longPress(PixelPoint(x: 99, y: 199), ms: 999, bounds: bounds)
        #expect(hold.suffix(2).map(\.delayAfterMs) == [999, 0])
        #expect(hold.last?.report == .mouse(MouseReport(buttons: 0, x: 32767, y: 32767)))
    }

    @Test func swipeHoldsPrimaryButtonAcrossInterpolatedPoints() {
        let reports = PointerPlanner.swipe(
            from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 99, y: 0), ms: 24, bounds: bounds
        )
        let drag = reports.compactMap { report -> MouseReport? in
            guard case .mouse(let mouse) = report.report, mouse.buttons == 1 else { return nil }
            return mouse
        }
        #expect(drag.count >= 2)
        #expect(drag.first?.x == 0)
        #expect(drag.last?.x == 32767)
        #expect(drag.allSatisfy { $0.y == 0 })
        #expect(reports.filter { if case .mouse(let mouse) = $0.report { mouse.buttons == 1 } else { false } }
            .reduce(0) { $0 + $1.delayAfterMs } == 24)
        #expect(reports.last?.report == .mouse(MouseReport(buttons: 0, x: 32767, y: 0)))
    }

    @Test func homePressesButtonThreeAtTheGivenPoint() {
        let reports = PointerPlanner.home(at: PixelPoint(x: 50, y: 100), bounds: PixelSize(width: 101, height: 201))
        #expect(reports.map(\.report) == [
            .mouse(MouseReport(buttons: MouseReport.homeButton, x: 16384, y: 16384)),
            .mouse(MouseReport(buttons: 0, x: 16384, y: 16384)),
        ])
        #expect(reports.map(\.delayAfterMs) == [60, 80])
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
