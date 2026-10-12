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

/// Plans require validated gains and coordinates requiring at most one million counts per axis.
public enum PointerPlanner {
    public static func resetToCorner() -> [TimedReport] {
        Array(repeating: mouse(dx: -127, dy: -127, delay: 8), count: 40)
    }

    public static func move(to point: PixelPoint, gains: PointerGains) -> [TimedReport] {
        counts(x: count(Double(point.x), gain: gains.pixelsPerCountX),
               y: count(Double(point.y), gain: gains.pixelsPerCountY), gains: gains)
    }

    public static func tap(_ point: PixelPoint, count: Int = 1, gains: PointerGains) -> [TimedReport] {
        precondition((0...1000).contains(count))
        return resetToCorner() + move(to: point, gains: gains)
            + (0..<count).flatMap { _ in [mouse(buttons: 1, delay: 60), mouse(delay: 80)] }
    }

    public static func longPress(_ point: PixelPoint, ms: Int, gains: PointerGains) -> [TimedReport] {
        precondition(ms >= 0)
        return resetToCorner() + move(to: point, gains: gains) + [mouse(buttons: 1, delay: ms), mouse()]
    }

    public static func swipe(from: PixelPoint, to: PixelPoint, ms: Int, gains: PointerGains) -> [TimedReport] {
        precondition(ms >= 0)
        var movement = counts(x: count(Double(to.x) - Double(from.x), gain: gains.pixelsPerCountX),
                              y: count(Double(to.y) - Double(from.y), gain: gains.pixelsPerCountY), gains: gains, buttons: 1)
        if movement.isEmpty { movement = [mouse(buttons: 1)] }
        movement = movement.enumerated().map { index, report in
            TimedReport(report: report.report, delayAfterMs: ms / movement.count + (index < ms % movement.count ? 1 : 0))
        }
        return resetToCorner() + move(to: from, gains: gains) + [mouse(buttons: 1)] + movement + [mouse()]
    }

    static func counts(x: Int, y: Int, gains: PointerGains, buttons: UInt8 = 0) -> [TimedReport] {
        precondition((try? gains.validate()) != nil)
        precondition(abs(x) <= 1_000_000 && abs(y) <= 1_000_000)
        var x = x
        var y = y
        var reports: [TimedReport] = []
        while x != 0 || y != 0 {
            let dx = min(gains.stepCounts, max(-gains.stepCounts, x))
            let dy = min(gains.stepCounts, max(-gains.stepCounts, y))
            reports.append(mouse(buttons: buttons, dx: dx, dy: dy, delay: gains.stepIntervalMs))
            x -= dx
            y -= dy
        }
        return reports
    }

    private static func count(_ pixels: Double, gain: Double) -> Int {
        let value = (pixels / gain).rounded()
        precondition(value.isFinite && abs(value) <= 1_000_000)
        return Int(value)
    }

    private static func mouse(buttons: UInt8 = 0, dx: Int = 0, dy: Int = 0, delay: Int = 0) -> TimedReport {
        TimedReport(report: .mouse(MouseReport(buttons: buttons, dx: Int8(dx), dy: Int8(dy), wheel: 0)), delayAfterMs: delay)
    }
}
