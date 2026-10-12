import Foundation
import Testing
import PhoneUseCore
@testable import PhoneUseMCP

private struct FixtureJPEGEncoder: FrameJPEGEncoder {
    func jpeg(_ frame: PixelFrame, maxLongEdge: Int, quality: Double) throws -> Data {
        Data([0xff, 0xd8, 0xff, 0xd9])
    }
}

private actor TestPhone: Phone {
    nonisolated let info: PhoneInfo
    var actions: [PhoneAction] = []
    var imageSize = PixelSize(width: 1206, height: 2622)
    var staleFrame: PixelFrame?
    let tracker: Activity?
    func rotate() { imageSize = .init(width: 2622, height: 1206) }
    var active = 0
    var maximum = 0
    init(_ id: String = "one", tracker: Activity? = nil) { self.tracker = tracker; info = .init(id: id, name: id, kind: .simulator, screenSize: .init(width: 1206, height: 2622)) }
    func perform(_ action: PhoneAction) async throws {
        await tracker?.start()
        active += 1
        maximum = max(maximum, active)
        actions.append(action)
        try await Task.sleep(for: .milliseconds(50))
        active -= 1
        await tracker?.end()
    }
    func screenshot() async throws -> PixelFrame {
        if let staleFrame { return staleFrame }
        let size = imageSize
        return try PixelFrame(width: size.width, height: size.height, rowStride: size.width * 4,
                              pixels: Data(repeating: 0, count: size.width * size.height * 4))
    }
    func installStaleFrame() throws { staleFrame = try PixelFrame(width: 2, height: 2, rowStride: 8, pixels: Data(repeating: 0, count: 16)) }
}
private struct Registry: PhoneRegistry {
    let phones: [any Phone]
    func discover() async -> (phones: [any Phone], hints: [String]) { (phones, ["hint"]) }
}
private struct NoSleep: Sleeper { func sleep(milliseconds: Int) async throws {} }

@Test func catalogAndMapping() async {
    #expect(ToolCatalog.all.count == 9)
    let phone = TestPhone()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]))
    _ = await dispatcher.call("tap", ["x": .int(309), "y": .int(672)])
    #expect(await phone.actions == [.tap(.init(x: 603, y: 1311), count: 1)])
    let list = await dispatcher.call("list_phones", [:])
    guard case let .text(text) = list else { Issue.record("Expected list"); return }
    #expect(text.contains("one | one | simulator | 1206x2622"))
    #expect(text.contains("hint"))
}
@Test func outOfBoundsTapIsError() async {
    let dispatcher = ToolDispatcher(registry: Registry(phones: [TestPhone()]))
    guard case let .error(message) = await dispatcher.call("tap", ["x": .int(700), "y": .int(0)]) else { Issue.record("Expected error"); return }
    #expect(message.contains("0-617"))
}
@Test func ambiguousPhones() async {
    let dispatcher = ToolDispatcher(registry: Registry(phones: [TestPhone("one"), TestPhone("two")]))
    guard case let .error(message) = await dispatcher.call("press_home", [:]) else { Issue.record("Expected error"); return }
    #expect(message.contains("one") && message.contains("two"))
}
@Test func rejectsInvalidArgumentsBeforeActing() async {
    let phone = TestPhone()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]), sleeper: NoSleep())
    let cases: [(String, [String: ToolArg])] = [
        ("tap", ["x": .int(0), "y": .int(0), "count": .string("2")]),
        ("tap", ["x": .int(0), "y": .int(0), "count": .int(-1)]),
        ("tap", ["x": .int(0)]), ("press_home", ["extra": .int(1)]),
        ("press_home", ["phone_id": .int(1)]),
        ("press_key", ["key": .string("a"), "modifiers": .strings(["invalid"])]),
        ("press_key", ["key": .string("a"), "repeat": .int(-1)]),
        ("long_press", ["x": .int(0), "y": .int(0), "duration_ms": .int(0)]),
        ("type_text", ["text": .string(String(repeating: "a", count: 101))]),
        ("type_text", ["text": .string("é")]),
        ("open_app", ["name": .string("")]),
        ("open_app", ["name": .string("é")]),
        ("open_app", ["name": .string(String(repeating: "a", count: 101))])]
    for (name, args) in cases {
        guard case .error = await dispatcher.call(name, args) else { Issue.record("Accepted \(name): \(args)"); continue }
    }
    #expect(await phone.actions.isEmpty)
}
@Test func screenshotDimensions() async throws {
    let dispatcher = ToolDispatcher(registry: Registry(phones: [TestPhone()]), imageEncoder: FixtureJPEGEncoder())
    guard case let .jpeg(data, note) = await dispatcher.call("screenshot", [:]) else { Issue.record("Expected JPEG"); return }
    #expect(data == Data([0xff, 0xd8, 0xff, 0xd9]))
    #expect(note.contains("618") && note.contains("1344"))
}
@Test func actionsOnOnePhoneAreSerialized() async {
    let phone = TestPhone()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]), sleeper: NoSleep())
    await withTaskGroup(of: ToolOutput.self) { group in
        for _ in 0..<4 { group.addTask { await dispatcher.call("tap", ["x": .int(0), "y": .int(0)]) } }
    }
    #expect(await phone.maximum == 1)
    await withTaskGroup(of: ToolOutput.self) { group in
        group.addTask { await dispatcher.call("open_app", ["name": .string("Maps")]) }
        group.addTask { await dispatcher.call("tap", ["x": .int(1), "y": .int(1)]) }
    }
    let actions = await phone.actions
    let macroStart = actions.firstIndex(of: homeActions[0])!
    #expect(Array(actions[macroStart..<macroStart + 4]) == homeActions + [.key(.space, modifiers: [.command], repeat: 1), .typeText("Maps"), .key(.enter, modifiers: [], repeat: 1)])
    #expect(await phone.maximum == 1)
}

private actor Activity {
    var active = 0
    var maximum = 0
    func start() { active += 1; maximum = max(maximum, active) }
    func end() { active -= 1 }
}
@Test func differentPhonesActConcurrently() async {
    let tracker = Activity()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [TestPhone("one", tracker: tracker), TestPhone("two", tracker: tracker)]))
    await withTaskGroup(of: ToolOutput.self) { group in
        for id in ["one", "two"] { group.addTask { await dispatcher.call("press_home", ["phone_id": .string(id)]) } }
    }
    #expect(await tracker.maximum == 2)
}
@Test func rotatedScreenshotDefinesInputCoordinates() async {
    let phone = TestPhone()
    await phone.rotate()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]), imageEncoder: FixtureJPEGEncoder())
    _ = await dispatcher.call("screenshot", [:])
    _ = await dispatcher.call("tap", ["x": .int(672), "y": .int(309)])
    #expect(await phone.actions == [.tap(.init(x: 1311, y: 603), count: 1)])
}

@Test func screenshotRejectsFrameCapturedBeforeLastAction() async throws {
    let phone = TestPhone()
    try await phone.installStaleFrame()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]), imageEncoder: FixtureJPEGEncoder())
    _ = await dispatcher.call("tap", ["x": .int(0), "y": .int(0)])
    guard case let .error(message) = await dispatcher.call("screenshot", [:]) else { Issue.record("Expected stale frame error"); return }
    #expect(message.contains("stale frame"))
}
@Test func cancelledQueuedActionDoesNotSendInput() async {
    let phone = TestPhone()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]))
    let first = Task { await dispatcher.call("tap", ["x": .int(0), "y": .int(0)]) }
    while await phone.active == 0 { await Task.yield() }
    let queued = Task { await dispatcher.call("tap", ["x": .int(1), "y": .int(1)]) }
    queued.cancel()
    _ = await first.value
    guard case .error = await queued.value else { Issue.record("Expected cancellation error"); return }
    #expect(await phone.actions == [.tap(.init(x: 0, y: 0), count: 1)])
}
@Test func longUnsupportedTextReportsCharacters() async {
    let dispatcher = ToolDispatcher(registry: Registry(phones: [TestPhone()]))
    guard case let .error(message) = await dispatcher.call("type_text", ["text": .string(String(repeating: "é", count: 60))]) else { Issue.record("Expected error"); return }
    #expect(message.contains("Unsupported characters"))
}
@Test func noPhonesIncludesDiscoveryHints() async {
    let dispatcher = ToolDispatcher(registry: Registry(phones: []))
    guard case let .error(message) = await dispatcher.call("screenshot", [:]) else { Issue.record("Expected error"); return }
    #expect(message.contains("hint"))
}

@Test func pressHomePerformsEveryMacroAction() async {
    let phone = TestPhone()
    let dispatcher = ToolDispatcher(registry: Registry(phones: [phone]), sleeper: NoSleep())
    _ = await dispatcher.call("press_home", [:])
    #expect(await phone.actions == homeActions)
}

private let homeActions: [PhoneAction] = [.home]

@Test func remoteScopeFiltersSelectionAndHints() async {
    let one = TestPhone("one"), two = TestPhone("two")
    let dispatcher = ToolDispatcher(registry: Registry(phones: [one, two]))
    let context = InvocationContext(credentialID: "credential", sessionID: "session", authorize: { ["one"] })
    guard case let .text(list) = await dispatcher.call("list_phones", [:], context: context) else { Issue.record("Expected list"); return }
    #expect(list.contains("one"))
    #expect(!list.contains("two") && !list.contains("hint"))
    _ = await dispatcher.call("tap", ["x": .int(0), "y": .int(0)], context: context)
    #expect(await one.actions.count == 1)
    #expect(await two.actions.isEmpty)
    let forbidden = await dispatcher.call("press_home", ["phone_id": .string("two")], context: context)
    let missing = await dispatcher.call("press_home", ["phone_id": .string("missing")], context: context)
    guard case let .error(a) = forbidden, case let .error(b) = missing else { Issue.record("Expected errors"); return }
    #expect(a == b)
}
