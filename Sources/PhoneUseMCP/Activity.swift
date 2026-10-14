import Foundation
import PhoneUseCore

/// One MCP session, named after the client it reported in `initialize`.
public struct AgentIdentity: Sendable, Hashable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    /// A remote HTTP session, which reports no client name the app needs.
    public static func remote(sessionID: String) -> AgentIdentity { AgentIdentity(id: "remote:\(sessionID)", name: "remote") }
}

/// Who may change a phone. Agents can always take screenshots.
public enum PhoneControl: Sendable, Equatable {
    case agents
    case paused
    case helpRequested(reason: String, agent: AgentIdentity)
    case person
}

/// What an agent says it is working on, shown under the phone.
public struct TaskLabel: Sendable, Equatable {
    public let title: String
    public let agent: AgentIdentity
    public let since: Date
}

/// A phone-bound tool call or manual input, published when it starts and again when it ends.
public struct ToolCallRecord: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable { case agent(AgentIdentity), person }
    public enum Outcome: Sendable, Equatable { case running, succeeded(String), failed(String) }
    public let id: UUID
    public let phoneID: String
    public let source: Source
    public let tool: String
    /// Arguments as the caller gave them, for display.
    public let arguments: String
    /// Native-pixel touch points: one for taps and long presses, start and end for swipes.
    public let touches: [PixelPoint]
    public let started: Date
    public var outcome = Outcome.running
    public var finished: Date?
}

public enum DispatcherEvent: Sendable, Equatable {
    case call(ToolCallRecord)
    case control(phoneID: String, PhoneControl)
    case task(phoneID: String, TaskLabel?)
    case agentConnected(AgentIdentity)
    case agentDisconnected(AgentIdentity)
}

enum ControlMessage {
    static let paused = "Paused by the user. Do not act on this phone until they resume it; screenshots still work."
    static let person = "The user has taken over this phone. Do not act until they hand it back; screenshots still work."
    static func help(_ reason: String, own: Bool) -> String {
        own ? "Waiting for the user: \(reason). Take screenshots to check progress, or call cancel_help if you no longer need help."
            : "Another agent asked the user for help on this phone: \(reason). Do not act until it is resolved; screenshots still work."
    }
}
