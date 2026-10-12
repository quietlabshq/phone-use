import PhoneUseCore

public enum PointerCalibration {
    /// `send` must honor report delays and finish after the host has consumed the reports.
    public static func run(send: @Sendable ([TimedReport]) async throws -> Void,
                           capture: @Sendable () async throws -> PixelFrame,
                           base: PointerGains) async throws -> PointerGains {
        try base.validate()
        let positioningCounts = 600
        let positioningSteps = (positioningCounts + base.stepCounts - 1) / base.stepCounts
        guard positioningSteps * base.stepIntervalMs <= 60_000 else {
            throw PhoneError.commandFailed("Calibration cadence would take more than 60 seconds per movement")
        }
        var xs: [Double] = []
        var ys: [Double] = []
        for _ in 0..<3 {
            for horizontal in [true, false] {
                try await send(PointerPlanner.resetToCorner())
                try await send(PointerPlanner.counts(x: 300, y: positioningCounts, gains: base))
                try await Task.sleep(for: .milliseconds(100))
                let before = try await capture().upright()
                try await send(PointerPlanner.counts(x: horizontal ? 200 : 0, y: horizontal ? 0 : 200, gains: base))
                try await Task.sleep(for: .milliseconds(100))
                let after = try await capture().upright()
                guard before.width == after.width, before.height == after.height else {
                    throw PhoneError.commandFailed("Capture dimensions changed during calibration")
                }
                let blobs = CursorLocator.changedBlobs(before: CursorLocator.grayscale(before), after: CursorLocator.grayscale(after), width: before.width, height: before.height)
                guard blobs.count >= 2 else { throw PhoneError.commandFailed("cursor not visible in capture") }
                guard blobs.count == 2 else { throw PhoneError.commandFailed("Ambiguous cursor movement in capture") }
                let a = blobs[0]
                let b = blobs[1]
                let distance = horizontal ? abs(a.centroid.0 - b.centroid.0) : abs(a.centroid.1 - b.centroid.1)
                let perpendicular = horizontal ? abs(a.centroid.1 - b.centroid.1) : abs(a.centroid.0 - b.centroid.0)
                let margin = max(Double(a.pixelCount).squareRoot(), Double(b.pixelCount).squareRoot())
                guard perpendicular <= 2, distance > margin,
                      Double(min(a.pixelCount, b.pixelCount)) / Double(max(a.pixelCount, b.pixelCount)) >= 0.8,
                      [a, b].allSatisfy({ blob in
                          blob.centroid.0 > margin && blob.centroid.1 > margin &&
                          blob.centroid.0 < Double(before.width) - margin && blob.centroid.1 < Double(before.height) - margin
                      }) else { throw PhoneError.commandFailed("Cursor movement is clipped or ambiguous") }
                if horizontal { xs.append(distance / 200) } else { ys.append(distance / 200) }
            }
        }
        let x = xs.reduce(0, +) / Double(xs.count)
        let y = ys.reduce(0, +) / Double(ys.count)
        guard xs.allSatisfy({ abs($0 - x) / x < 0.05 }), ys.allSatisfy({ abs($0 - y) / y < 0.05 }) else {
            throw PhoneError.commandFailed("Cursor calibration was inconsistent")
        }
        let result = PointerGains(pixelsPerCountX: x, pixelsPerCountY: y, stepCounts: base.stepCounts, stepIntervalMs: base.stepIntervalMs)
        try result.validate()
        return result
    }
}
