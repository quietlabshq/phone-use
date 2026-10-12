import Foundation

/// Process-local seconds that continue advancing while the computer sleeps.
public enum MonotonicClock {
    private static let origin = ContinuousClock.now
    public static var now: TimeInterval {
        let components = origin.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
