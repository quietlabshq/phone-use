import CoreGraphics
import Foundation
import Observation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseMCP

/// Live view state for one phone: the frame stream and manual input.
@MainActor @Observable
final class PhoneSession {
    let id: String
    private(set) var image: CGImage?
    private(set) var streamError: String?
    private(set) var inputError: String?
    private(set) var pendingInputs = 0
    private(set) var framesPerSecond = 0.0

    @ObservationIgnored private var phone: any Phone
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var idleStop: Task<Void, Never>?
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

    /// Streams while at least one view shows the phone. Stopping waits a moment, so moving
    /// between the Wall and the Device screen keeps one stream running.
    func attach() {
        viewers += 1
        idleStop?.cancel(); idleStop = nil
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.stream()
                // Reconnect after USB replugs, simulator restarts, or AXe exits.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func stop() {
        idleStop?.cancel(); idleStop = nil
        streamTask?.cancel(); streamTask = nil
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
                    await model.prepareManualInput(on: id)
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
