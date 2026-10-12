import Testing
import Foundation
import CoreGraphics
import PhoneUseCore
import PhoneUseHID
@testable import PhoneUseHardware

private func frame() -> CGImage {
    CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
}
private actor Transport: HIDTransport {
    var reports: [HIDReport] = []
    let connected: Bool
    var fail = false
    init(_ connected: Bool = true, fail: Bool = false) { self.connected = connected; self.fail = fail }
    func isHostConnected() -> Bool { connected }
    func send(_ report: HIDReport) throws {
        reports.append(report)
        if fail { fail = false; throw PhoneError.commandFailed("send failed") }
    }
}
private struct NoSleep: Sleeper { func sleep(milliseconds: Int) async throws {} }
private func phone(_ transport: Transport, gains: PointerGains? = nil) -> HardwarePhone {
    HardwarePhone(info: PhoneInfo(id: "test", name: "Test", kind: .hardware, screenSize: PixelSize(width: 100, height: 200)), capture: { frame() }, transport: transport, gains: gains, sleeper: NoSleep())
}
@Test func configRoundtripAndValidation() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try Config.load(from: url).phones.isEmpty)
    let config = Config(phones: [PhoneConfig(name: "Mine", captureDeviceName: "iPhone")])
    try config.save(to: url)
    #expect(try Config.load(from: url) == config)
    #expect(throws: (any Error).self) { try Config(phones: [PhoneConfig(name: "", captureDeviceName: "a")]).save(to: url) }
    #expect(throws: (any Error).self) { try Config(phones: config.phones + config.phones).save(to: url) }
    #expect(throws: (any Error).self) { try Config(phones: [PhoneConfig(name: "a", captureDeviceName: "a", pointer: PointerGains(pixelsPerCountX: 0, pixelsPerCountY: 1))]).save(to: url) }
}
@Test func actionFailsFastWhenHostDisconnected() async throws {
    let transport = Transport(false)
    let subject = phone(transport)
    await #expect(throws: (any Error).self) { try await subject.perform(.typeText("a")) }
    #expect(await transport.reports.isEmpty)
    #expect(try await subject.screenshot().width == 100)
}
@Test func connectedTypingAndFailureCleanup() async throws {
    let transport = Transport()
    try await phone(transport).perform(.typeText("a"))
    #expect(await transport.reports.count == 2)
    let failing = Transport(fail: true)
    await #expect(throws: (any Error).self) { try await phone(failing).perform(.typeText("a")) }
    #expect(await failing.reports.last == .keyboard(.empty))
}
@Test func invalidPointerAndActionsNeverSend() async throws {
    for gains in [PointerGains(pixelsPerCountX: .nan, pixelsPerCountY: 1), PointerGains(pixelsPerCountX: 0.00001, pixelsPerCountY: 1), PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1)] {
        let transport = Transport()
        let subject = phone(transport, gains: gains)
        await #expect(throws: (any Error).self) { try await subject.perform(.tap(PixelPoint(x: -1, y: 0), count: 1)) }
        await #expect(throws: (any Error).self) { try await subject.perform(.key(.letter("A"), modifiers: [], repeat: 1)) }
        #expect(await transport.reports.isEmpty)
    }
}
@Test func registryWithoutTransportStillProvidesScreenshots() async throws {
    let registry = HardwareRegistry(config: Config(phones: [PhoneConfig(name: "Mine", captureDeviceName: "USB")]), candidates: {
        [CaptureCandidate(id: "usb-1", name: "USB", size: PixelSize(width: 100, height: 200), capture: { frame() })]
    })
    let first = await registry.discover()
    #expect(first.phones.count == 1)
    #expect(first.phones.first?.info.name == "Mine")
    let subject = try #require(first.phones.first)
    #expect(try await subject.screenshot().width == 100)
    await #expect(throws: (any Error).self) { try await subject.perform(.typeText("a")) }
    let again = await registry.discover()
    #expect(again.phones.first?.info.id == subject.info.id)
}
@Test func duplicateCaptureNamesAndSlowUnsafeGainsAreRejected() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) {
        try Config(phones: [PhoneConfig(name: "one", captureDeviceName: "same"), PhoneConfig(name: "two", captureDeviceName: "same")]).save(to: url)
    }
    let transport = Transport()
    #expect(await phone(transport).isInputConnected())
    for gain in [PointerGains(pixelsPerCountX: 0.00001, pixelsPerCountY: 1), PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1, stepIntervalMs: 60000)] {
        await #expect(throws: (any Error).self) { try await phone(transport, gains: gain).perform(.tap(PixelPoint(x: 1, y: 1), count: 1)) }
    }
    #expect(await transport.reports.isEmpty)
}
private struct CancelSleep: Sleeper {
    func sleep(milliseconds: Int) async throws { throw CancellationError() }
}
@Test func cancellationReleasesPressedKeyboard() async throws {
    let transport = Transport()
    let subject = HardwarePhone(info: PhoneInfo(id: "cancel", name: "Cancel", kind: .hardware, screenSize: PixelSize(width: 100, height: 200)), capture: { frame() }, transport: transport, sleeper: CancelSleep())
    await #expect(throws: CancellationError.self) { try await subject.perform(.typeText("a")) }
    #expect(await transport.reports == [.keyboard(KeyboardReport(modifiers: 0, keys: [4])), .keyboard(.empty)])
}

@Test func hardwareScreenshotUpdatesRotationBounds() async throws {
    let transport = Transport()
    let subject = HardwarePhone(info: PhoneInfo(id: "rotated", name: "Rotated", kind: .hardware,
        screenSize: PixelSize(width: 200, height: 100)), capture: { frame() }, transport: transport,
        gains: PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1), sleeper: NoSleep())
    _ = try await subject.screenshot()
    await #expect(throws: (any Error).self) {
        try await subject.perform(.tap(PixelPoint(x: 150, y: 50), count: 1))
    }
    #expect(await transport.reports.isEmpty)
    try await subject.perform(.tap(PixelPoint(x: 50, y: 150), count: 1))
    #expect(await !transport.reports.isEmpty)
}

private actor RecordingSleeper: Sleeper {
    var delays: [Int] = []
    func sleep(milliseconds: Int) { delays.append(milliseconds) }
}
@Test func hardwareHomeUsesSettledKeyboardFallback() async throws {
    let transport = Transport()
    let sleeper = RecordingSleeper()
    let subject = HardwarePhone(info: PhoneInfo(id: "home", name: "Home", kind: .hardware, screenSize: .init(width: 100, height: 200)), capture: { frame() }, transport: transport, sleeper: sleeper)
    try await subject.perform(.home)
    #expect(await transport.reports == [
        .keyboard(KeyboardReport(modifiers: 8, keys: [11])), .keyboard(.empty),
        .keyboard(KeyboardReport(modifiers: 0, keys: [41])), .keyboard(.empty),
        .keyboard(KeyboardReport(modifiers: 0, keys: [41])), .keyboard(.empty),
    ])
    #expect(await sleeper.delays == [12, 800, 12, 800, 12, 800])
}
