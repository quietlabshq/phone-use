import Foundation
import PhoneUseMCP

/// What the app knows about agents on one phone, built from dispatcher events.
struct PhoneActivity: Equatable {
    static let historyLimit = 200
    /// An agent counts as driving while its last call ended at most this long ago.
    static let drivingWindow: TimeInterval = 60

    /// Newest first.
    private(set) var calls: [ToolCallRecord] = []
    var control = PhoneControl.agents
    var controlSince: Date?
    var task: TaskLabel?
    private(set) var lastAgent: AgentIdentity?
    private(set) var lastAgentCall: Date?
    private(set) var drivingSince: Date?

    /// Inserts or updates a record; events for one call arrive at start and finish.
    mutating func record(_ record: ToolCallRecord) {
        if let index = calls.firstIndex(where: { $0.id == record.id }) {
            calls[index] = record
        } else {
            calls.insert(record, at: 0)
            if calls.count > Self.historyLimit { calls.removeLast(calls.count - Self.historyLimit) }
        }
        guard case let .agent(agent) = record.source else { return }
        if let last = lastAgentCall, record.started.timeIntervalSince(last) <= Self.drivingWindow, lastAgent == agent {} else {
            drivingSince = record.started
        }
        lastAgent = agent
        lastAgentCall = max(lastAgentCall ?? .distantPast, record.finished ?? record.started)
    }

    /// An agent that disconnected is no longer driving, however recently it acted.
    mutating func agentLeft(_ agent: AgentIdentity) {
        guard lastAgent == agent else { return }
        lastAgentCall = nil
        drivingSince = nil
    }

    func agentActive(at now: Date) -> Bool {
        guard let lastAgentCall else { return false }
        return calls.contains { $0.outcome == .running && $0.source != .person } || now.timeIntervalSince(lastAgentCall) <= Self.drivingWindow
    }

    /// Manual input takes the phone from an agent that is using it or waiting for help.
    func manualInputTakesOver(at now: Date) -> Bool {
        switch control {
        case .helpRequested: true
        case .agents: agentActive(at: now)
        case .paused, .person: false
        }
    }

    /// The most recent agent call that touched the screen, while it is still worth showing.
    func recentTouch(at now: Date, within seconds: TimeInterval = 2.5) -> ToolCallRecord? {
        guard let record = calls.first(where: { $0.byAgent && !$0.failed && !$0.touches.isEmpty }) else { return nil }
        return now.timeIntervalSince(record.finished ?? now) <= seconds ? record : nil
    }

    /// The agent's latest action that ran or is running; blocked calls never reached the phone.
    var latestAgentCall: ToolCallRecord? { calls.first { $0.byAgent && !$0.failed } }
}

extension ToolCallRecord {
    var byAgent: Bool { if case .agent = source { true } else { false } }
    var failed: Bool { if case .failed = outcome { true } else { false } }
}

/// A phone's state as the Wall and sidebar show it.
enum PhoneStatus: Equatable {
    case driving(AgentIdentity)
    case needsYou(reason: String, agent: AgentIdentity)
    case person
    case paused
    case idle
    case offline

    init(activity: PhoneActivity?, online: Bool, now: Date) {
        guard online else { self = .offline; return }
        switch activity?.control ?? .agents {
        case let .helpRequested(reason, agent): self = .needsYou(reason: reason, agent: agent)
        case .person: self = .person
        case .paused: self = .paused
        case .agents:
            if let activity, activity.agentActive(at: now), let agent = activity.lastAgent { self = .driving(agent) } else { self = .idle }
        }
    }

    enum Filter: String, CaseIterable, Hashable {
        case all, driving, needsYou, person, paused, idle, offline
        var label: String {
            switch self {
            case .all: "All"
            case .driving: "Agent driving"
            case .needsYou: "Needs you"
            case .person: "You're driving"
            case .paused: "Paused"
            case .idle: "Idle"
            case .offline: "Offline"
            }
        }
    }

    var filter: Filter {
        switch self {
        case .driving: .driving
        case .needsYou: .needsYou
        case .person: .person
        case .paused: .paused
        case .idle: .idle
        case .offline: .offline
        }
    }

    /// When the current state began, for the elapsed timer.
    func since(_ activity: PhoneActivity?) -> Date? {
        guard let activity else { return nil }
        switch self {
        case let .driving(agent): return activity.task?.agent == agent ? activity.task?.since : activity.drivingSince
        case .needsYou, .person, .paused: return activity.controlSince
        case .idle, .offline: return nil
        }
    }
}

enum Elapsed {
    static func format(from start: Date?, to now: Date) -> String {
        guard let start else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
