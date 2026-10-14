import CoreGraphics
import Foundation
import PhoneUseCore
import PhoneUseHID
import PhoneUseCapture

public struct UnavailableTransport: HIDTransport {
    public init() {}
    public func isHostConnected() async -> Bool { false }
    public func send(_ report: HIDReport) async throws {
        throw PhoneError.inputNotConnected("Bluetooth HID host is not advertising or no iPhone is connected")
    }
}

public actor HardwarePhone: Phone {
    public nonisolated let info: PhoneInfo
    private let capture: @Sendable () async throws -> CGImage
    private let transport: any HIDTransport
    private let sleeper: any Sleeper
    private var gains: PointerGains?
    private var bounds: PixelSize
    private var lastPointer: PixelPoint
    private var performing = false

    public init(info: PhoneInfo, capture: @escaping @Sendable () async throws -> CGImage,
                transport: any HIDTransport, gains: PointerGains? = nil, sleeper: any Sleeper = RealSleeper()) {
        self.info = info; self.capture = capture; self.transport = transport
        self.gains = gains; self.sleeper = sleeper; bounds = info.screenSize
        lastPointer = PixelPoint(x: info.screenSize.width / 2, y: info.screenSize.height / 2)
    }
    public func screenshot() async throws -> PixelFrame {
        let image = try await capture()
        let frame = try PixelFrameImageAdapter.frame(from: image)
        bounds = PixelSize(width: frame.width, height: frame.height)
        lastPointer = PixelPoint(
            x: min(max(0, lastPointer.x), max(0, bounds.width - 1)),
            y: min(max(0, lastPointer.y), max(0, bounds.height - 1))
        )
        return frame
    }
    public func isInputConnected() async -> Bool { await transport.isHostConnected() }
    private func connected() async throws {
        guard await transport.isHostConnected() else {
            throw PhoneError.inputNotConnected("Bluetooth HID host is not advertising or no iPhone is connected")
        }
    }
    public func perform(_ action: PhoneAction) async throws {
        try await connected()
        guard !performing else { throw PhoneError.commandFailed("Another hardware action is in progress") }
        performing = true
        defer { performing = false }
        let reports: [TimedReport]
        switch action {
        case .home:
            reports = PointerPlanner.home(at: lastPointer, bounds: bounds)
        case let .typeText(text): reports = try KeyboardDriver.type(text)
        case let .key(key, modifiers, count):
            guard (1...100).contains(count) else { throw PhoneError.commandFailed("Key repeat must be 1...100") }
            if case let .letter(letter) = key, Key(name: String(letter)) == nil {
                throw PhoneError.commandFailed("Key must be a lowercase ASCII letter")
            }
            reports = KeyboardDriver.key(key, modifiers: modifiers, repeat: count)
        case let .tap(point, count):
            guard (1...3).contains(count) else { throw PhoneError.commandFailed("Tap count must be 1...3") }
            try pointer([point])
            lastPointer = point
            reports = PointerPlanner.tap(point, count: count, bounds: bounds)
        case let .longPress(point, ms):
            try duration(ms)
            try pointer([point])
            lastPointer = point
            reports = PointerPlanner.longPress(point, ms: ms, bounds: bounds)
        case let .swipe(from, to, ms):
            try duration(ms)
            try pointer([from, to])
            lastPointer = to
            reports = PointerPlanner.swipe(from: from, to: to, ms: ms, bounds: bounds)
        }
        try await send(reports)
    }
    private func duration(_ ms: Int) throws {
        guard (1...60_000).contains(ms) else { throw PhoneError.commandFailed("Duration must be 1...60000 milliseconds") }
    }
    private func pointer(_ points: [PixelPoint]) throws {
        for point in points {
            guard (0..<bounds.width).contains(point.x), (0..<bounds.height).contains(point.y) else {
                throw PhoneError.outOfBounds(point, bounds)
            }
        }
    }
    private func send(_ reports: [TimedReport]) async throws {
        var keyboard = false
        var mouse = false
        var lastMouse = MouseReport.empty
        do {
            for timed in reports {
                try Task.checkCancellation()
                // Track attempted presses: a failed write may still have reached the host.
                switch timed.report {
                case let .keyboard(report): keyboard = keyboard || report != .empty
                case let .mouse(report):
                    lastMouse = report
                    mouse = mouse || report.buttons != 0
                }
                try await transport.send(timed.report)
                switch timed.report {
                case let .keyboard(report): keyboard = report != .empty
                case let .mouse(report):
                    lastMouse = report
                    mouse = report.buttons != 0
                }
                try await sleeper.sleep(milliseconds: timed.delayAfterMs)
            }
        } catch {
            let transport = transport
            let releaseKeyboard = keyboard
            let releaseMouse = mouse
            let mouseRelease = MouseReport(buttons: 0, x: lastMouse.x, y: lastMouse.y)
            await Task.detached {
                if releaseMouse { try? await transport.send(.mouse(mouseRelease)) }
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
