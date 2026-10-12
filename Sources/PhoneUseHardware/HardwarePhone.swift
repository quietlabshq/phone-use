import CoreGraphics
import Foundation
import PhoneUseCore
import PhoneUseHID
import PhoneUseCapture

public struct UnavailableTransport: HIDTransport {
    public init() {}
    public func isHostConnected() async -> Bool { false }
    public func send(_ report: HIDReport) async throws {
        throw PhoneError.inputNotConnected("input transport not installed (see Task 10)")
    }
}

public actor HardwarePhone: Phone {
    public nonisolated let info: PhoneInfo
    private let capture: @Sendable () async throws -> CGImage
    private let transport: any HIDTransport
    private let sleeper: any Sleeper
    private var gains: PointerGains?
    private var bounds: PixelSize
    private var performing = false

    public init(info: PhoneInfo, capture: @escaping @Sendable () async throws -> CGImage,
                transport: any HIDTransport, gains: PointerGains? = nil, sleeper: any Sleeper = RealSleeper()) {
        self.info = info; self.capture = capture; self.transport = transport
        self.gains = gains; self.sleeper = sleeper; bounds = info.screenSize
    }
    public func screenshot() async throws -> PixelFrame {
        let image = try await capture()
        let frame = try PixelFrameImageAdapter.frame(from: image)
        bounds = PixelSize(width: frame.width, height: frame.height)
        return frame
    }
    public func isInputConnected() async -> Bool { await transport.isHostConnected() }
    private func connected() async throws {
        guard await transport.isHostConnected() else {
            throw PhoneError.inputNotConnected("input transport not installed or host disconnected (see Task 10)")
        }
    }
    public func perform(_ action: PhoneAction) async throws {
        try await connected()
        guard !performing else { throw PhoneError.commandFailed("Another hardware action is in progress") }
        performing = true
        defer { performing = false }
        let reports: [TimedReport]
        switch action {
        case .home: reports = KeyboardDriver.home()
        case let .typeText(text): reports = try KeyboardDriver.type(text)
        case let .key(key, modifiers, count):
            guard (1...100).contains(count) else { throw PhoneError.commandFailed("Key repeat must be 1...100") }
            if case let .letter(letter) = key, Key(name: String(letter)) == nil {
                throw PhoneError.commandFailed("Key must be a lowercase ASCII letter")
            }
            reports = KeyboardDriver.key(key, modifiers: modifiers, repeat: count)
        case let .tap(point, count):
            guard (1...3).contains(count) else { throw PhoneError.commandFailed("Tap count must be 1...3") }
            reports = PointerPlanner.tap(point, count: count, gains: try pointer([point]))
        case let .longPress(point, ms):
            try duration(ms)
            reports = PointerPlanner.longPress(point, ms: ms, gains: try pointer([point]))
        case let .swipe(from, to, ms):
            try duration(ms)
            reports = PointerPlanner.swipe(from: from, to: to, ms: ms, gains: try pointer([from, to]))
        }
        try await send(reports)
    }
    private func duration(_ ms: Int) throws {
        guard (1...60_000).contains(ms) else { throw PhoneError.commandFailed("Duration must be 1...60000 milliseconds") }
    }
    private func pointer(_ points: [PixelPoint]) throws -> PointerGains {
        guard let gains else { throw PhoneError.commandFailed("pointer not calibrated: run phone-use calibrate") }
        try gains.validate()
        let maximumSteps = ceil(max(Double(bounds.width) / gains.pixelsPerCountX, Double(bounds.height) / gains.pixelsPerCountY) / Double(gains.stepCounts))
        guard maximumSteps * Double(gains.stepIntervalMs) <= 60_000 else {
            throw PhoneError.commandFailed("Pointer cadence would take more than 60 seconds to cross the screen; recalibrate")
        }
        for point in points {
            guard (0..<bounds.width).contains(point.x), (0..<bounds.height).contains(point.y) else {
                throw PhoneError.outOfBounds(point, bounds)
            }
        }
        // The planner's fixed reset travels 40 * 127 counts on each axis.
        for (pixels, gain) in [(bounds.width, gains.pixelsPerCountX), (bounds.height, gains.pixelsPerCountY)] {
            let counts = Double(pixels) / gain
            guard counts.isFinite, counts <= 1_000_000, counts <= 5080 else {
                throw PhoneError.commandFailed("Pointer gains cannot reset across this screen; run phone-use calibrate")
            }
        }
        return gains
    }
    private func send(_ reports: [TimedReport]) async throws {
        var keyboard = false
        var mouse = false
        do {
            for timed in reports {
                try Task.checkCancellation()
                // Track attempted presses: a failed write may still have reached the host.
                switch timed.report {
                case let .keyboard(report): keyboard = keyboard || report != .empty
                case let .mouse(report): mouse = mouse || report.buttons != 0
                case .consumer: break
                }
                try await transport.send(timed.report)
                switch timed.report {
                case let .keyboard(report): keyboard = report != .empty
                case let .mouse(report): mouse = report.buttons != 0
                case .consumer: break
                }
                try await sleeper.sleep(milliseconds: timed.delayAfterMs)
            }
        } catch {
            let transport = transport
            let releaseKeyboard = keyboard; let releaseMouse = mouse
            await Task.detached {
                if releaseMouse { try? await transport.send(.mouse(MouseReport(buttons: 0, dx: 0, dy: 0, wheel: 0))) }
                if releaseKeyboard { try? await transport.send(.keyboard(.empty)) }
            }.value
            throw error
        }
    }
    public func calibrate(base: PointerGains = PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1)) async throws -> PointerGains {
        try await connected()
        guard !performing else { throw PhoneError.commandFailed("Another hardware action is in progress") }
        performing = true
        defer { performing = false }
        let result = try await PointerCalibration.run(send: { try await self.send($0) }, capture: { try await self.screenshot() }, base: base)
        gains = result
        return result
    }
}
