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
    var failWhenButtonsPressed = false
    init(_ connected: Bool = true, fail: Bool = false, failWhenButtonsPressed: Bool = false) {
        self.connected = connected
        self.fail = fail
        self.failWhenButtonsPressed = failWhenButtonsPressed
    }
    func isHostConnected() -> Bool { connected }
    func send(_ report: HIDReport) throws {
        reports.append(report)
        if failWhenButtonsPressed, case .mouse(let mouse) = report, mouse.buttons != 0 {
            throw PhoneError.commandFailed("send failed")
        }
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
    let transport = Transport()
    let subject = phone(transport)
    await #expect(throws: (any Error).self) { try await subject.perform(.tap(PixelPoint(x: -1, y: 0), count: 1)) }
    await #expect(throws: (any Error).self) { try await subject.perform(.key(.letter("A"), modifiers: [], repeat: 1)) }
    #expect(await transport.reports.isEmpty)
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
@Test func duplicateCaptureNamesAreRejected() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) {
        try Config(phones: [PhoneConfig(name: "one", captureDeviceName: "same"), PhoneConfig(name: "two", captureDeviceName: "same")]).save(to: url)
    }
    let transport = Transport()
    #expect(await phone(transport).isInputConnected())
    try await phone(transport).perform(.tap(PixelPoint(x: 1, y: 1), count: 1))
    #expect(await !transport.reports.isEmpty)
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
        sleeper: NoSleep())
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
@Test func mouseSendFailureReleasesButtonsAtLastPoint() async throws {
    let transport = Transport(failWhenButtonsPressed: true)
    await #expect(throws: (any Error).self) {
        try await phone(transport).perform(.tap(PixelPoint(x: 99, y: 199), count: 1))
    }
    let reports = await transport.reports
    #expect(reports.contains(.mouse(MouseReport(buttons: MouseReport.primaryButton, x: 32767, y: 32767))))
    #expect(reports.last == .mouse(MouseReport(buttons: 0, x: 32767, y: 32767)))
}

@Test func hardwareHomePressesAssistiveTouchButtonThree() async throws {
    let transport = Transport()
    let sleeper = RecordingSleeper()
    let subject = HardwarePhone(info: PhoneInfo(id: "home", name: "Home", kind: .hardware, screenSize: .init(width: 101, height: 201)), capture: { frame() }, transport: transport, sleeper: sleeper)
    try await subject.perform(.home)
    #expect(await transport.reports == [
        .mouse(MouseReport(buttons: MouseReport.homeButton, x: 16384, y: 16384)),
        .mouse(MouseReport(buttons: 0, x: 16384, y: 16384)),
    ])
    #expect(await sleeper.delays == [60, 80])
}
@Test func registryReloadsConfigurationOnEachDiscovery() async throws {
    let store = ConfigBox()
    let registry = HardwareRegistry(loadConfig: { store.config }, candidates: {
        [CaptureCandidate(id: "usb-1", name: "USB", size: PixelSize(width: 100, height: 200), capture: { frame() })]
    })
    let before = await registry.discover()
    #expect(before.phones.isEmpty)
    #expect(before.hints.contains { $0.contains("unconfigured") })
    store.config = Config(phones: [PhoneConfig(name: "Mine", captureDeviceName: "USB")])
    #expect(await registry.discover().phones.map(\.info.name) == ["Mine"])
    store.config = Config(phones: [PhoneConfig(name: "Renamed", captureDeviceName: "USB")])
    let renamed = try #require(await registry.discover().phones.first)
    #expect(renamed.info.name == "Renamed")
    // An unchanged entry keeps its phone; changed pointer gains rebuild it.
    #expect(try #require(await registry.discover().phones.first) as AnyObject === renamed as AnyObject)
    store.config = Config(phones: [PhoneConfig(name: "Renamed", captureDeviceName: "USB", pointer: PointerGains(pixelsPerCountX: 2, pixelsPerCountY: 2))])
    #expect(try #require(await registry.discover().phones.first) as AnyObject !== renamed as AnyObject)
}
private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Config()
    var config: Config {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
