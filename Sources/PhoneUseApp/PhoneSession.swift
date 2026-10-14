import CoreGraphics
import Foundation
import Observation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseHardware
import PhoneUseMCP

/// Live view state for one phone: the frame stream, input, and link status.
@MainActor @Observable
final class PhoneSession {
    let id: String
    private(set) var image: CGImage?
    private(set) var streamError: String?
    private(set) var inputError: String?
    private(set) var inputConnected: Bool?
    private(set) var pendingInputs = 0
    private(set) var framesPerSecond = 0.0

    @ObservationIgnored private var phone: any Phone
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typingFlush: Task<Void, Never>?
    @ObservationIgnored private var frameTimes: [ContinuousClock.Instant] = []
    @ObservationIgnored private var inputQueue: AsyncStream<DirectCommand>.Continuation?
    @ObservationIgnored private var inputTask: Task<Void, Never>?

    init(entry: PhoneEntry, model: AppModel) {
        id = entry.id
        phone = entry.phone
        self.model = model
    }

    func update(phone: any Phone) { self.phone = phone }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.stream()
                // Reconnect after USB replugs, simulator restarts, or AXe exits.
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if phone is HardwarePhone {
            statusTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollInput()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func stop() {
        streamTask?.cancel(); streamTask = nil
        statusTask?.cancel(); statusTask = nil
    }

    /// Ends the input queue too; used when the phone disappears.
    func close() {
        stop()
        inputQueue?.finish(); inputQueue = nil
        inputTask?.cancel(); inputTask = nil
    }

    private func stream() async {
        guard let source = phone as? any LiveFrameSource else {
            streamError = "Live view is not available for this phone."
            return
        }
        do {
            for await frame in try await source.liveFrames() {
                image = frame
                streamError = nil
                countFrame()
            }
            if !Task.isCancelled { streamError = "The live stream ended. Reconnecting..." }
        } catch {
            streamError = String(describing: error)
        }
    }

    private func countFrame() {
        let now = ContinuousClock.now
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > .seconds(2) }
        framesPerSecond = Double(frameTimes.count) / 2
    }

    private func pollInput() async {
        guard let hardware = phone as? HardwarePhone else { return }
        inputConnected = await hardware.isInputConnected()
    }

    // MARK: Input

    func perform(_ action: PhoneAction) { send(.action(action)) }
    func home() { send(.home) }
    func openApp(_ name: String) { send(.openApp(name)) }

    /// Buffers printable characters so a burst of typing becomes one `typeText`.
    func type(_ text: String) {
        typed += text
        typingFlush?.cancel()
        if typed.utf8.count >= 100 { flushTyping(); return }
        typingFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flushTyping()
        }
    }

    func key(_ key: Key, modifiers: [Modifier]) {
        send(.action(.key(key, modifiers: modifiers, repeat: 1)))
    }

    private func flushTyping() {
        typingFlush?.cancel()
        guard !typed.isEmpty else { return }
        let text = typed
        typed = ""
        enqueue(.action(.typeText(text)))
    }

    /// Sends buffered typing first, so text lands before any later tap or key.
    private func send(_ command: DirectCommand) {
        flushTyping()
        enqueue(command)
    }

    private func enqueue(_ command: DirectCommand) {
        if inputQueue == nil { startInputQueue() }
        pendingInputs += 1
        inputQueue?.yield(command)
    }

    /// Commands run one at a time, in the order the user made them.
    private func startInputQueue() {
        let (commands, continuation) = AsyncStream.makeStream(of: DirectCommand.self)
        inputQueue = continuation
        let id = id
        inputTask = Task { [weak self, weak model] in
            for await command in commands {
                do {
                    guard let model else { throw PhoneError.commandFailed("Phone Use is shutting down") }
                    try await model.run(command, on: id)
                    self?.inputError = nil
                } catch {
                    self?.inputError = String(describing: error)
                }
                self?.pendingInputs -= 1
            }
        }
    }
}
