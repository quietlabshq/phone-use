import Foundation
import Testing
import PhoneUseCore
@testable import PhoneUseMCP

private actor SlowPhone: Phone {
    nonisolated let info = PhoneInfo(id: "one", name: "One", kind: .simulator, screenSize: .init(width: 1206, height: 2622))
    var actions: [PhoneAction] = []
    var started = 0
    func perform(_ action: PhoneAction) async throws {
        started += 1
        try await Task.sleep(for: .milliseconds(100))
        actions.append(action)
    }
    func screenshot() async throws -> PixelFrame {
        try PixelFrame(width: 1206, height: 2622, rowStride: 1206 * 4, pixels: Data(repeating: 0, count: 1206 * 2622 * 4))
    }
}
private struct OnePhone: PhoneRegistry {
    let phone: SlowPhone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], []) }
}
private struct FixedJPEG: FrameJPEGEncoder {
    func jpeg(_ frame: PixelFrame, maxLongEdge: Int, quality: Double) throws -> Data { Data(count: 4096) }
}
private struct Skip: Sleeper { func sleep(milliseconds: Int) async throws {} }

private let alice = AgentIdentity(id: "a", name: "alice")
private let bob = AgentIdentity(id: "b", name: "bob")
private let tap: [String: ToolArg] = ["x": .int(309), "y": .int(672)]

private func fixture() -> (ToolDispatcher, SlowPhone) {
    let phone = SlowPhone()
    return (ToolDispatcher(registry: OnePhone(phone: phone), sleeper: Skip(), imageEncoder: FixedJPEG()), phone)
}
private func errorText(_ output: ToolOutput) -> String? { if case let .error(message) = output { message } else { nil } }
/// Control errors as an agent sees them.
private func blocked(_ message: String) -> String { String(describing: PhoneError.commandFailed(message)) }

@Test func pauseBlocksMutationsButNotScreenshots() async {
    let (dispatcher, phone) = fixture()
    await dispatcher.pause(phoneID: "one")
    for (tool, args) in [("tap", tap), ("press_home", [:]), ("type_text", ["text": .string("hi")])] as [(String, [String: ToolArg])] {
        #expect(errorText(await dispatcher.call(tool, args, agent: alice)) == blocked(ControlMessage.paused))
    }
    guard case .jpeg = await dispatcher.call("screenshot", [:], agent: alice) else { Issue.record("Expected a screenshot"); return }
    #expect(await phone.actions.isEmpty)
    await dispatcher.resume(phoneID: "one")
    #expect(await dispatcher.call("tap", tap, agent: alice) == .text("OK"))
}

@Test func agentsCannotOverridePause() async {
    let (dispatcher, _) = fixture()
    await dispatcher.pause(phoneID: "one")
    #expect(errorText(await dispatcher.call("request_help", ["reason": .string("stuck")], agent: alice)) == blocked(ControlMessage.paused))
    #expect(await dispatcher.call("cancel_help", [:], agent: alice) == .text("No help request was pending."))
    #expect(await dispatcher.control(of: "one") == .paused)
}

@Test func takeOverFailsCallsQueuedBehindARunningAction() async throws {
    let (dispatcher, phone) = fixture()
    async let first = dispatcher.call("tap", tap, agent: alice)
    while await phone.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
    async let second = dispatcher.call("tap", tap, agent: alice)
    try await Task.sleep(for: .milliseconds(20))
    await dispatcher.takeOver(phoneID: "one")
    #expect(await first == .text("OK"))
    #expect(errorText(await second) == blocked(ControlMessage.person))
    #expect(await phone.actions.count == 1)
    await dispatcher.handBack(phoneID: "one")
    #expect(await dispatcher.call("tap", tap, agent: alice) == .text("OK"))
}

@Test func onlyTheRequestingAgentCanCancelHelp() async {
    let (dispatcher, _) = fixture()
    guard case .text = await dispatcher.call("request_help", ["reason": .string("Passcode needed")], agent: alice) else { Issue.record("Expected help"); return }
    #expect(await dispatcher.control(of: "one") == .helpRequested(reason: "Passcode needed", agent: alice))
    #expect(errorText(await dispatcher.call("tap", tap, agent: alice)) == blocked(ControlMessage.help("Passcode needed", own: true)))
    #expect(errorText(await dispatcher.call("tap", tap, agent: bob)) == blocked(ControlMessage.help("Passcode needed", own: false)))
    #expect(errorText(await dispatcher.call("cancel_help", [:], agent: bob)) == blocked(ControlMessage.help("Passcode needed", own: false)))
    #expect(errorText(await dispatcher.call("request_help", ["reason": .string("mine")], agent: bob)) == blocked(ControlMessage.help("Passcode needed", own: false)))
    #expect(await dispatcher.call("cancel_help", [:], agent: alice) == .text("Help request withdrawn."))
    #expect(await dispatcher.call("tap", tap, agent: alice) == .text("OK"))
}

@Test func onlyHandBackEndsATakeOver() async {
    let (dispatcher, _) = fixture()
    _ = await dispatcher.call("request_help", ["reason": .string("Face ID")], agent: alice)
    await dispatcher.takeOver(phoneID: "one")
    #expect(errorText(await dispatcher.call("cancel_help", [:], agent: alice)) == blocked(ControlMessage.person))
    #expect(errorText(await dispatcher.call("request_help", ["reason": .string("again")], agent: alice)) == blocked(ControlMessage.person))
    await dispatcher.resume(phoneID: "one")
    #expect(await dispatcher.control(of: "one") == .person)
    await dispatcher.handBack(phoneID: "one")
    #expect(await dispatcher.control(of: "one") == .agents)
}

@Test func helpReasonAndTaskTitleAreBounded() async {
    let (dispatcher, _) = fixture()
    #expect(errorText(await dispatcher.call("request_help", ["reason": .string("  ")], agent: alice)) != nil)
    #expect(errorText(await dispatcher.call("request_help", ["reason": .string(String(repeating: "a", count: 201))], agent: alice)) != nil)
    #expect(errorText(await dispatcher.call("set_task", ["title": .string(String(repeating: "a", count: 81))], agent: alice)) != nil)
    #expect(await dispatcher.control(of: "one") == .agents)
}

@Test func disconnectDropsTheAgentsHelpAndTasks() async {
    let (dispatcher, _) = fixture()
    _ = await dispatcher.call("set_task", ["title": .string("Checkout regression")], agent: alice)
    _ = await dispatcher.call("request_help", ["reason": .string("Passcode")], agent: alice)
    #expect(await dispatcher.task(of: "one")?.title == "Checkout regression")
    await dispatcher.agentDisconnected(bob)
    #expect(await dispatcher.task(of: "one") != nil)
    await dispatcher.agentDisconnected(alice)
    #expect(await dispatcher.task(of: "one") == nil)
    #expect(await dispatcher.control(of: "one") == .agents)
}

@Test func eventsDescribeCallsTasksAndControl() async throws {
    let (dispatcher, _) = fixture()
    _ = await dispatcher.call("set_task", ["title": .string("Checkout")], agent: alice)
    _ = await dispatcher.call("tap", tap, agent: alice)
    _ = await dispatcher.call("screenshot", [:], agent: alice)
    _ = await dispatcher.call("type_text", ["text": .string("hello")], agent: alice)
    await dispatcher.pause(phoneID: "one")
    _ = await dispatcher.call("swipe", ["from_x": .int(1), "from_y": .int(2), "to_x": .int(3), "to_y": .int(4)], agent: alice)
    try await dispatcher.run(.action(.tap(.init(x: 10, y: 20), count: 2)), phoneID: "one")
    _ = await dispatcher.call("list_phones", [:], agent: alice)

    var events: [DispatcherEvent] = []
    for await event in dispatcher.events {
        events.append(event)
        if case let .call(record) = event, record.source == .person, record.finished != nil { break }
    }
    let finished = events.compactMap { if case let .call(record) = $0, record.finished != nil { record } else { nil } }
    #expect(finished.map(\.tool) == ["set_task", "tap", "screenshot", "type_text", "swipe", "tap"])
    #expect(finished.map(\.arguments) == ["\"Checkout\"", "309, 672", "", "\"hello\"", "1, 2 → 3, 4", "10, 20 ×2"])
    #expect(finished.map(\.outcome) == [.succeeded("Task set."), .succeeded("Done"), .succeeded("618×1344 · 4 KB"), .succeeded("5 keys"),
                                        .failed(blocked(ControlMessage.paused)), .succeeded("Done")])
    #expect(finished[1].touches == [.init(x: 603, y: 1311)])
    #expect(finished[4].touches.count == 2)
    #expect(finished.map(\.source) == [.agent(alice), .agent(alice), .agent(alice), .agent(alice), .agent(alice), .person])
    #expect(events.contains { if case let .task(_, task) = $0 { task?.title == "Checkout" } else { false } })
    #expect(events.contains(.control(phoneID: "one", .paused)))
    let starts = events.filter { if case let .call(record) = $0 { record.outcome == .running } else { false } }
    #expect(starts.count == finished.count)
}

@Test func catalogMarksOnlyPhoneChangingToolsAsMutations() {
    let names = Set(ToolCatalog.all.map(\.name))
    #expect(ToolDispatcher.mutations.isSubset(of: names))
    #expect(names.subtracting(ToolDispatcher.mutations) == ["list_phones", "screenshot", "set_task", "request_help", "cancel_help"])
}
