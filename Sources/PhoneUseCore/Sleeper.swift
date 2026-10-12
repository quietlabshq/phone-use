public protocol Sleeper: Sendable {
    func sleep(milliseconds: Int) async throws
}

public struct RealSleeper: Sleeper {
    public init() {}

    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
