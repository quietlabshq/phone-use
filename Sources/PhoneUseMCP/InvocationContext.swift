import Foundation

/// Constructed by an authenticated transport. Authorization must reload current policy
/// on every call and return only explicitly permitted phone IDs.
public struct InvocationContext: Sendable {
    public let credentialID: String
    public let sessionID: String
    /// Absolute monotonic seconds, using the dispatcher's clock (MonotonicClock.now by default).
    public let deadline: TimeInterval?
    public let authorize: @Sendable () throws -> Set<String>
    public init(credentialID: String, sessionID: String, deadline: TimeInterval? = nil,
                authorize: @escaping @Sendable () throws -> Set<String>) {
        self.credentialID = credentialID
        self.sessionID = sessionID
        self.deadline = deadline
        self.authorize = authorize
    }
}
