import Testing
@testable import PhoneUseCore

private enum Event: Equatable {
    case action(PhoneAction)
    case sleep(Int)
}

private actor EventLog {
    private var events: [Event] = []
    func append(_ event: Event) { events.append(event) }
    func snapshot() -> [Event] { events }
}

private struct RecordingPhone: Phone {
    let info = PhoneInfo(id: "test", name: "Test", kind: .simulator, screenSize: PixelSize(width: 100, height: 100))
    let log: EventLog
    func screenshot() async throws -> PixelFrame { fatalError("unused") }
    func perform(_ action: PhoneAction) async throws { await log.append(.action(action)) }
}

private struct RecordingSleeper: Sleeper {
    let log: EventLog
    func sleep(milliseconds: Int) async throws { await log.append(.sleep(milliseconds)) }
}

@Test func homeUsesBackendActionAndSettles() async throws {
    let log = EventLog()
    try await Macros.home(on: RecordingPhone(log: log), sleeper: RecordingSleeper(log: log))
    #expect(await log.snapshot() == homeEvents)
}

private let homeEvents: [Event] = [.action(.home), .sleep(800)]

@Test func openAppPerformsSearchSequenceWithDelays() async throws {
    let log = EventLog()
    try await Macros.openApp("Settings", on: RecordingPhone(log: log), sleeper: RecordingSleeper(log: log))
    #expect(await log.snapshot() == homeEvents + [
        .action(.key(.space, modifiers: [.command], repeat: 1)),
        .sleep(800),
        .action(.typeText("Settings")),
        .sleep(800),
        .action(.key(.enter, modifiers: [], repeat: 1)),
        .sleep(800),
    ])
}

@Test func openAppRejectsUnsupportedNameBeforeAnyAction() async {
    let log = EventLog()
    await #expect(throws: PhoneError.unsupportedCharacters("é👍")) {
        try await Macros.openApp("Café 👍", on: RecordingPhone(log: log), sleeper: RecordingSleeper(log: log))
    }
    #expect(await log.snapshot().isEmpty)
}
