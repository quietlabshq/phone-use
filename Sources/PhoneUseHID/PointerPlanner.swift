import PhoneUseCore

public struct PointerGains: Codable, Sendable, Equatable {
    public var pixelsPerCountX: Double
    public var pixelsPerCountY: Double
    public var stepCounts: Int
    public var stepIntervalMs: Int

    public init(pixelsPerCountX: Double, pixelsPerCountY: Double, stepCounts: Int = 8, stepIntervalMs: Int = 8) {
        self.pixelsPerCountX = pixelsPerCountX
        self.pixelsPerCountY = pixelsPerCountY
        self.stepCounts = stepCounts
        self.stepIntervalMs = stepIntervalMs
    }

    public func validate() throws {
        guard pixelsPerCountX.isFinite, pixelsPerCountX > 0,
              pixelsPerCountY.isFinite, pixelsPerCountY > 0,
              (1...127).contains(stepCounts), (0...60_000).contains(stepIntervalMs) else {
            throw PhoneError.commandFailed("Invalid pointer gains or cadence")
        }
    }
}

public struct TimedReport: Equatable, Sendable {
    public let report: HIDReport
    public let delayAfterMs: Int
    public init(report: HIDReport, delayAfterMs: Int) {
        self.report = report
        self.delayAfterMs = delayAfterMs
    }
}

/// Plans absolute-pointer reports on the 0...32767 HID axis. Pixel (0, 0) is
/// the top-left of `bounds`; the opposite corner is axis max.
public enum PointerPlanner {
    public static func hidPoint(_ point: PixelPoint, bounds: PixelSize) -> (UInt16, UInt16) {
        (axis(point.x, extent: bounds.width), axis(point.y, extent: bounds.height))
    }

    public static func move(to point: PixelPoint, bounds: PixelSize) -> [TimedReport] {
        [mouse(point, bounds: bounds, delay: 8)]
    }

    public static func tap(_ point: PixelPoint, count: Int = 1, bounds: PixelSize) -> [TimedReport] {
        precondition((0...1000).contains(count))
        let (x, y) = hidPoint(point, bounds: bounds)
        return move(to: point, bounds: bounds)
            + (0..<count).flatMap { _ in
                [mouse(buttons: MouseReport.primaryButton, x: x, y: y, delay: 60),
                 mouse(buttons: 0, x: x, y: y, delay: 80)]
            }
    }

    public static func longPress(_ point: PixelPoint, ms: Int, bounds: PixelSize) -> [TimedReport] {
        precondition(ms >= 0)
        let (x, y) = hidPoint(point, bounds: bounds)
        return move(to: point, bounds: bounds)
            + [mouse(buttons: MouseReport.primaryButton, x: x, y: y, delay: ms),
               mouse(buttons: 0, x: x, y: y)]
    }

    public static func swipe(from: PixelPoint, to: PixelPoint, ms: Int, bounds: PixelSize) -> [TimedReport] {
        precondition(ms >= 0)
        let steps = max(2, ms / 8 + (ms % 8 == 0 ? 0 : 1))
        let delays = distribute(ms, across: steps)
        let drag = (0..<steps).map { index in
            let t = Double(index) / Double(steps - 1)
            let point = PixelPoint(
                x: lerp(from.x, to.x, t),
                y: lerp(from.y, to.y, t)
            )
            let (x, y) = hidPoint(point, bounds: bounds)
            return mouse(buttons: MouseReport.primaryButton, x: x, y: y, delay: delays[index])
        }
        let (endX, endY) = hidPoint(to, bounds: bounds)
        return move(to: from, bounds: bounds) + drag + [mouse(buttons: 0, x: endX, y: endY)]
    }

    public static func home(at point: PixelPoint, bounds: PixelSize) -> [TimedReport] {
        let (x, y) = hidPoint(point, bounds: bounds)
        return [
            mouse(buttons: MouseReport.homeButton, x: x, y: y, delay: 60),
            mouse(buttons: 0, x: x, y: y, delay: 80),
        ]
    }

    private static func axis(_ pixel: Int, extent: Int) -> UInt16 {
        guard extent > 1 else { return 0 }
        let t = min(1, max(0, Double(pixel) / Double(extent - 1)))
        return UInt16((t * Double(MouseReport.axisMax)).rounded())
    }

    private static func lerp(_ from: Int, _ to: Int, _ t: Double) -> Int {
        Int((Double(from) + (Double(to) - Double(from)) * t).rounded())
    }

    private static func distribute(_ total: Int, across count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = total / count
        let remainder = total % count
        return (0..<count).map { $0 < remainder ? base + 1 : base }
    }

    private static func mouse(_ point: PixelPoint, bounds: PixelSize, buttons: UInt32 = 0, delay: Int = 0) -> TimedReport {
        let (x, y) = hidPoint(point, bounds: bounds)
        return mouse(buttons: buttons, x: x, y: y, delay: delay)
    }

    private static func mouse(buttons: UInt32, x: UInt16, y: UInt16, delay: Int = 0) -> TimedReport {
        TimedReport(report: .mouse(MouseReport(buttons: buttons, x: x, y: y)), delayAfterMs: delay)
    }
}
