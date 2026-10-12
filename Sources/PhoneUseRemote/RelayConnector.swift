import Foundation
import PhoneUseCore

public enum RelayConnectionError: Error, Sendable { case pairingRejected(Int), invalidPairingResponse, invalidConnection }

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private func privateSession() -> URLSession {
    let settings = URLSessionConfiguration.ephemeral
    settings.httpCookieStorage = nil
    settings.httpShouldSetCookies = false
    settings.urlCache = nil
    settings.requestCachePolicy = .reloadIgnoringLocalCacheData
    settings.timeoutIntervalForRequest = 24 * 60 * 60
    return URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
}

private final class PongWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var outcome: Bool?

    func install(_ value: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            value.resume(returning: outcome)
        } else {
            continuation = value
            lock.unlock()
        }
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

public enum RelayPairing {
    /// The pairing token exists only in this call and is never persisted.
    public static func pair(origin: URL, macID: String, token: String, allowInsecureLoopback: Bool = false) async throws -> RelayConfiguration {
        // Validate the endpoint before placing a bearer secret in a request.
        let endpoint = try RelayConfiguration(origin: origin, macID: macID, daemonSecret: "placeholder", allowInsecureLoopback: allowInsecureLoopback)
        guard !token.isEmpty, token.utf8.count <= 256, !token.utf8.contains(where: { $0 < 33 || $0 > 126 }) else { throw RelayConnectionError.invalidPairingResponse }
        let session = privateSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.pairURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayConnectionError.invalidPairingResponse }
        guard http.statusCode == 200 else { throw RelayConnectionError.pairingRejected(http.statusCode) }
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daemonSecret = object["daemonSecret"] as? String else { throw RelayConnectionError.invalidPairingResponse }
        return try RelayConfiguration(origin: origin, macID: macID, daemonSecret: daemonSecret, allowInsecureLoopback: allowInsecureLoopback)
    }
}

enum RelayBackoff {
    static func seconds(attempt: Int, random: Double) -> Double {
        min(30, 0.5 * pow(2, Double(min(6, max(0, attempt))))) * (0.5 + 0.5 * min(1, max(0, random)))
    }
}

/// One optional outbound adapter. The HTTP service owns all sessions, requests, and phones.
public actor RelayConnector {
    private let config: RelayConfiguration
    private let credentials: CredentialStore
    private let service: HTTPService
    private var loopTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var dispatches: [String: Task<Void, Never>] = [:]
    private var stopped = false
    private var snapshotUnavailable = false
    private let heartbeatInterval: Duration
    private let pongTimeout: Duration

    public init(config: RelayConfiguration, credentials: CredentialStore, service: HTTPService,
                heartbeatInterval: Duration = .seconds(30), pongTimeout: Duration = .seconds(10)) {
        self.config = config; self.credentials = credentials; self.service = service
        self.heartbeatInterval = heartbeatInterval; self.pongTimeout = pongTimeout
    }
    public func start() {
        guard loopTask == nil, !stopped else { return }
        loopTask = Task { await runLoop() }
    }
    public func stop() async {
        stopped = true
        socket?.cancel(with: .goingAway, reason: nil)
        loopTask?.cancel()
        await loopTask?.value
        await cancelDispatches()
        loopTask = nil
    }
    private func runLoop() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            do {
                _ = try credentials.relaySnapshot()
                snapshotUnavailable = false
            } catch {
                reportSnapshotFailure()
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let session = privateSession()
            var request = URLRequest(url: config.connectURL)
            request.setValue("Bearer \(config.daemonSecret)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = RelayWire.frameLimit
            socket = task
            task.resume()
            let connectedAt = MonotonicClock.now
            do {
                try await connected(task)
                if MonotonicClock.now - connectedAt >= 30 { attempt = 0 }
            } catch { /* A rejected daemon credential is terminal; outages remain retryable. */ }
            let revoked = (task.response as? HTTPURLResponse)?.statusCode == 401 ||
                (task.closeCode.rawValue == 4001 && String(data: task.closeReason ?? Data(), encoding: .utf8) == "Revoked")
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            session.invalidateAndCancel()
            await cancelDispatches()
            if revoked || stopped || Task.isCancelled { break }
            let delay = RelayBackoff.seconds(attempt: attempt, random: Double.random(in: 0...1))
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }
    private func connected(_ task: URLSessionWebSocketTask) async throws {
        let initial = try await task.receive()
        guard case let .string(text) = initial else { throw RelayConnectionError.invalidConnection }
        let generation = try RelayWire.connectedGeneration(Data(text.utf8))
        let initialSnapshot: [RelayCredentialSnapshot]
        do { initialSnapshot = try credentials.relaySnapshot() }
        catch { reportSnapshotFailure(); throw RelayConnectionError.invalidConnection }
        try await send(try RelayWire.hello(generation: generation, credentials: initialSnapshot), to: task)
        let poll = Task { await pollCredentials(generation: generation, initial: initialSnapshot, socket: task) }
        let heartbeat = Task { await monitorHeartbeat(socket: task) }
        let result: Result<Void, Error>
        do { try await receiveDispatches(task, generation: generation); result = .success(()) }
        catch { result = .failure(error) }
        poll.cancel()
        heartbeat.cancel()
        await poll.value
        await heartbeat.value
        try result.get()
    }
    private func receiveDispatches(_ task: URLSessionWebSocketTask, generation: String) async throws {
        while !Task.isCancelled && !stopped {
            let message = try await task.receive()
            guard case let .string(text) = message, Data(text.utf8).count <= RelayWire.frameLimit else { throw RelayConnectionError.invalidConnection }
            let raw = Data(text.utf8)
            let dispatch: RelayDispatch
            do {
                dispatch = try RelayWire.parseDispatch(raw, generation: generation, nowMilliseconds: Self.nowMilliseconds())
            } catch RelayWireError.expired {
                if let failure = try? RelayWire.rejectedDispatch(raw, generation: generation, outcome: "not_started") { try await send(failure, to: task) }
                continue
            } catch { throw RelayConnectionError.invalidConnection }
            guard dispatches[dispatch.dispatchID] == nil, dispatches.count < 32 else {
                try await send(try RelayWire.failure(for: dispatch, outcome: "not_started"), to: task)
                continue
            }
            let deadline = MonotonicClock.now + dispatch.deadlineInterval
            dispatches[dispatch.dispatchID] = Task {
                let response = await self.service.handle(dispatch.request, deadline: deadline)
                if !Task.isCancelled {
                    do {
                        try await self.send(RelayWire.resultStart(for: dispatch, response: response), to: task)
                        var sequence = 0
                        for offset in stride(from: 0, to: response.body.count, by: RelayWire.chunkLimit) {
                            try Task.checkCancellation()
                            let chunk = response.body[offset..<min(offset + RelayWire.chunkLimit, response.body.count)]
                            try await self.send(RelayWire.resultChunk(for: dispatch, sequence: sequence, body: chunk), to: task)
                            sequence += 1
                        }
                        try Task.checkCancellation()
                        try await self.send(RelayWire.resultEnd(for: dispatch), to: task)
                    } catch { /* Disconnect makes the outcome unknown at the relay. */ }
                }
                self.dispatches.removeValue(forKey: dispatch.dispatchID)
            }
        }
    }
    private func monitorHeartbeat(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled && !stopped {
            do { try await Task.sleep(for: heartbeatInterval) }
            catch { break }
            guard !Task.isCancelled && !stopped else { break }
            let waiter = PongWaiter()
            let timeout = pongTimeout
            let received = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiter.install(continuation)
                    socket.sendPing { error in waiter.finish(error == nil) }
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { waiter.finish(false) }
                }
            } onCancel: {
                waiter.finish(false)
            }
            if !received && !Task.isCancelled {
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
        }
    }
    private func pollCredentials(generation: String, initial: [RelayCredentialSnapshot], socket: URLSessionWebSocketTask) async {
        var previous = initial
        var revision = 1
        while !Task.isCancelled && !stopped {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || stopped { break }
            let current: [RelayCredentialSnapshot]
            do { current = try credentials.relaySnapshot() }
            catch {
                reportSnapshotFailure()
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
            if current == previous { continue }
            revision += 1
            guard let frame = try? RelayWire.credentials(generation: generation, revision: revision, credentials: current) else {
                reportSnapshotFailure()
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
            do { try await send(frame, to: socket); previous = current }
            catch { socket.cancel(with: .goingAway, reason: nil); break }
        }
    }
    private func send(_ frame: Data, to task: URLSessionWebSocketTask) async throws {
        guard let text = String(data: frame, encoding: .utf8), frame.count <= RelayWire.frameLimit else { throw RelayWireError.invalidFrame }
        try await task.send(.string(text))
    }
    private func cancelDispatches() async {
        let tasks = Array(dispatches.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        dispatches.removeAll()
    }
    private func reportSnapshotFailure() {
        guard !snapshotUnavailable else { return }
        snapshotUnavailable = true
        FileHandle.standardError.write(Data("Relay credential metadata unavailable; waiting for a valid local snapshot\n".utf8))
    }
    private static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}
