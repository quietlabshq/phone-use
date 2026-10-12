public protocol HIDTransport: Sendable {
    func send(_ report: HIDReport) async throws
    func isHostConnected() async -> Bool
}
