import Foundation
import Testing
import PhoneUseCore
import PhoneUseMCP
@testable import PhoneUseApp

private let alice = AgentIdentity(id: "a", name: "alice")
private let start = Date(timeIntervalSince1970: 1_000)

private func call(_ agent: AgentIdentity?, at offset: TimeInterval, finished: TimeInterval? = nil, touches: [PixelPoint] = [], id: UUID = UUID()) -> ToolCallRecord {
    ToolCallRecord(id: id, phoneID: "one", source: agent.map { .agent($0) } ?? .person, tool: "tap", arguments: "1, 2", touches: touches,
                   started: start + offset, outcome: finished == nil ? .running : .succeeded("Done"), finished: finished.map { start + $0 })
}

@Test func agentDrivesForAMinuteAfterItsLastCall() {
    var activity = PhoneActivity()
    activity.record(call(alice, at: 0, finished: 1))
    #expect(PhoneStatus(activity: activity, online: true, now: start + 61) == .driving(alice))
    #expect(PhoneStatus(activity: activity, online: true, now: start + 62) == .idle)
    #expect(PhoneStatus(activity: activity, online: false, now: start + 2) == .offline)
}

@Test func drivingEndsWhenTheAgentDisconnects() {
    var activity = PhoneActivity()
    activity.record(call(alice, at: 0, finished: 1))
    activity.agentLeft(AgentIdentity(id: "b", name: "bob"))
    #expect(PhoneStatus(activity: activity, online: true, now: start + 2) == .driving(alice))
    activity.agentLeft(alice)
    #expect(PhoneStatus(activity: activity, online: true, now: start + 2) == .idle)
}

@Test func controlOutranksDriving() {
    var activity = PhoneActivity()
    activity.record(call(alice, at: 0, finished: 1))
    activity.control = .helpRequested(reason: "Passcode", agent: alice)
    #expect(PhoneStatus(activity: activity, online: true, now: start + 2) == .needsYou(reason: "Passcode", agent: alice))
    activity.control = .person
    #expect(PhoneStatus(activity: activity, online: true, now: start + 2) == .person)
    activity.control = .paused
    #expect(PhoneStatus(activity: activity, online: true, now: start + 2) == .paused)
}

@Test func manualInputTakesOverOnlyFromABusyAgent() {
    var activity = PhoneActivity()
    #expect(!activity.manualInputTakesOver(at: start))
    activity.record(call(nil, at: 0, finished: 1))
    #expect(!activity.manualInputTakesOver(at: start + 2))
    activity.record(call(alice, at: 2, finished: 3))
    #expect(activity.manualInputTakesOver(at: start + 4))
    #expect(!activity.manualInputTakesOver(at: start + 70))
    activity.control = .helpRequested(reason: "Face ID", agent: alice)
    #expect(activity.manualInputTakesOver(at: start + 70))
    activity.control = .paused
    #expect(!activity.manualInputTakesOver(at: start + 4))
}

@Test func recordsUpdateInPlaceAndKeepABoundedHistory() {
    var activity = PhoneActivity()
    let id = UUID()
    activity.record(call(alice, at: 0, id: id))
    activity.record(call(alice, at: 0, finished: 1, id: id))
    #expect(activity.calls.count == 1)
    #expect(activity.calls[0].outcome == .succeeded("Done"))
    for index in 0..<(PhoneActivity.historyLimit + 5) { activity.record(call(alice, at: Double(index), finished: Double(index))) }
    #expect(activity.calls.count == PhoneActivity.historyLimit)
    #expect(activity.calls[0].started == start + Double(PhoneActivity.historyLimit + 4))
}

@Test func touchesFadeAfterTheActionEnds() {
    var activity = PhoneActivity()
    activity.record(call(alice, at: 0, touches: [.init(x: 5, y: 6)]))
    #expect(activity.recentTouch(at: start + 30) != nil)
    activity.record(call(alice, at: 0, finished: 1, touches: [.init(x: 5, y: 6)], id: activity.calls[0].id))
    #expect(activity.recentTouch(at: start + 3) != nil)
    #expect(activity.recentTouch(at: start + 4) == nil)
}

@Test func elapsedFormatsMinutesAndHours() {
    #expect(Elapsed.format(from: start, to: start + 252) == "4:12")
    #expect(Elapsed.format(from: start, to: start + 3_725) == "1:02:05")
    #expect(Elapsed.format(from: nil, to: start) == "")
}

@Test func blockedCallsShowNoTouchOrCaption() {
    var activity = PhoneActivity()
    activity.record(call(alice, at: 0, finished: 1, touches: [.init(x: 1, y: 1)]))
    var blocked = call(alice, at: 2, finished: 2, touches: [.init(x: 9, y: 9)])
    blocked.outcome = .failed("Paused")
    activity.record(blocked)
    #expect(activity.recentTouch(at: start + 2)?.touches == [.init(x: 1, y: 1)])
    #expect(activity.latestAgentCall?.started == start)
}
