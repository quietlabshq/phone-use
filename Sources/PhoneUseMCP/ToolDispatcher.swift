import Foundation
import PhoneUseCore

public actor ToolDispatcher {
    private let registry: any PhoneRegistry
    private let sleeper: any Sleeper
    private typealias DiscoveryResult = ([any Phone], [String])
    private var discovery: Task<Void, Never>?
    private var discovered: DiscoveryResult?
    private var discoveryWaiters: [UUID: CheckedContinuation<DiscoveryResult, any Error>] = [:]
    private var screenshotSizes: [String: PixelSize] = [:]
    private var lastMutationCompletedAt: [String: UInt64] = [:]
    private var busy: Set<String> = []
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct Owner: Equatable { let credential: String; let session: String }
    private struct Lease { let owner: Owner; let token: UUID; let expires: TimeInterval }
    private var leases: [String: Lease] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private let now: @Sendable () -> TimeInterval
    private let perPhoneLimit: Int
    private let globalLimit: Int
    private let imageEncoder: any FrameJPEGEncoder
    public init(registry: any PhoneRegistry, sleeper: any Sleeper = RealSleeper(),
                perPhoneQueueLimit: Int = 8, globalQueueLimit: Int = 32,
                imageEncoder: any FrameJPEGEncoder = UnavailableFrameJPEGEncoder(),
                now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now }) {
        precondition(perPhoneQueueLimit >= 0 && globalQueueLimit >= 0)
        self.perPhoneLimit = perPhoneQueueLimit
        self.globalLimit = globalQueueLimit
        self.now = now
        self.registry = registry
        self.sleeper = sleeper
        self.imageEncoder = imageEncoder
    }
    public func call(_ name: String, _ args: [String: ToolArg], context: InvocationContext? = nil) async -> ToolOutput {
        var mutationStarted = false
        var leaseToken: UUID?
        do {
            _ = try authorize(context)
            guard let spec = ToolCatalog.all.first(where: { $0.name == name }) else { throw invalid("Unknown tool: \(name)") }
            for (key, value) in args {
                guard let property = spec.properties[key] else { throw invalid("Unknown argument: \(key)") }
                switch (property.type, value) {
                case ("integer", .int), ("string", .string), ("array", .strings): break
                default: throw invalid("\(key) must be \(property.type)")
                }
            }
            for key in spec.required where args[key] == nil { throw invalid("Missing argument: \(key)") }
            let (discovered, discoveryHints) = try await discover(refresh: name == "list_phones")
            let scope = try authorize(context)
            let phones = discovered.filter { scope?.contains($0.info.id) ?? true }
            let hints = context == nil ? discoveryHints : []
            if name == "list_phones" {
                return .text((["id | name | kind | WxH"] + phones.map { "\($0.info.id) | \($0.info.name) | \($0.info.kind.rawValue) | \($0.info.screenSize.width)x\($0.info.screenSize.height)" } + hints).joined(separator: "\n"))
            }
            guard !phones.isEmpty else { throw invalid((["No phones available."] + hints).joined(separator: "\n")) }
            let phone: any Phone
            if case let .string(id) = args["phone_id"] {
                guard let selected = phones.first(where: { $0.info.id == id }) else { throw context == nil ? PhoneError.phoneNotFound(id) : invalid("Phone unavailable or unauthorized") }
                phone = selected
            } else {
                guard phones.count == 1 else { throw invalid("Specify phone_id. Available phones: \(phones.map { $0.info.id }.joined(separator: ", "))") }
                phone = phones[0]
            }
            try await acquire(phone.info.id)
            defer {
                if mutationStarted { lastMutationCompletedAt[phone.info.id] = FrameFreshness.now().capturedAtNanoseconds }
                if let leaseToken { finishMutation(phoneID: phone.info.id, token: leaseToken) }
                release(phone.info.id)
            }
            try validate(context, phoneID: phone.info.id)
            let size = screenshotSizes[phone.info.id] ?? phone.info.screenSize
            guard size.width > 0, size.height > 0 else { throw invalid("Invalid phone screen size") }
            let scaler = ScreenshotScaler(native: size)
            func integer(_ key: String, default fallback: Int = 0) -> Int { if case let .int(value) = args[key] { return value }; return fallback }
            func string(_ key: String) -> String { if case let .string(value) = args[key] { return value }; return "" }
            func bounded(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
                let value = integer(key, default: fallback)
                guard range.contains(value) else { throw invalid("\(key) must be \(range.lowerBound)-\(range.upperBound)") }
                return value
            }
            func point(_ x: String, _ y: String) throws -> PixelPoint { try scaler.toNative(.init(x: integer(x), y: integer(y))) }
            func text(_ key: String, nonempty: Bool = false) throws -> String {
                let value = string(key)
                _ = try KeyboardMap.strokes(for: value)
                guard value.utf8.count <= 100, !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("\(key) must be \(nonempty ? "1-100" : "0-100") ASCII characters") }
                return value
            }
            let action: PhoneAction
            switch name {
            case "screenshot":
                try validate(context, phoneID: phone.info.id)
                let frame = try await phone.screenshot().upright()
                if let completedAt = lastMutationCompletedAt[phone.info.id],
                   frame.freshness.capturedAtNanoseconds <= completedAt {
                    throw PhoneError.commandFailed("Capture returned a stale frame from before the last action")
                }
                let native = PixelSize(width: frame.width, height: frame.height)
                screenshotSizes[phone.info.id] = native
                let actual = ScreenshotScaler(native: native).scaled
                return .jpeg(try imageEncoder.jpeg(frame, maxLongEdge: 1344, quality: 0.8), note: "Screenshot \(actual.width)x\(actual.height). Coordinates: x 0-\(actual.width - 1), y 0-\(actual.height - 1).")
            case "tap": action = try .tap(point("x", "y"), count: bounded("count", default: 1, range: 1...3))
            case "long_press": action = try .longPress(point("x", "y"), milliseconds: bounded("duration_ms", default: 800, range: 1...60_000))
            case "swipe": action = try .swipe(from: point("from_x", "from_y"), to: point("to_x", "to_y"), milliseconds: bounded("duration_ms", default: 300, range: 1...60_000))
            case "type_text": action = try .typeText(text("text"))
            case "press_key":
                guard let key = Key(name: string("key")) else { throw invalid("Invalid key") }
                var modifiers: [Modifier] = []
                if case let .strings(values) = args["modifiers"] {
                    for value in values {
                        guard let modifier = Modifier(rawValue: value) else { throw invalid("Invalid modifier: \(value)") }
                        modifiers.append(modifier)
                    }
                }
                action = try .key(key, modifiers: modifiers, repeat: bounded("repeat", default: 1, range: 1...100))
            case "press_home":
                leaseToken = try admitMutation(context, phoneID: phone.info.id)
                mutationStarted = true
                try await Macros.home(on: phone, sleeper: sleeper)
                try Task.checkCancellation()
                return .text("OK")
            case "open_app":
                let appName = try text("name", nonempty: true)
                leaseToken = try admitMutation(context, phoneID: phone.info.id)
                mutationStarted = true
                try await Macros.openApp(appName, on: phone, sleeper: sleeper)
                try Task.checkCancellation()
                return .text("OK")
            default: throw invalid("Unknown tool: \(name)")
            }
            leaseToken = try admitMutation(context, phoneID: phone.info.id)
            mutationStarted = true
            try await phone.perform(action)
            try Task.checkCancellation()
            return .text("OK")
        } catch {
            if mutationStarted && (error is CancellationError || Task.isCancelled) {
                return .error("Action outcome unknown: cancellation occurred after execution started")
            }
            return .error(String(describing: error))
        }
    }
    private func discover(refresh: Bool) async throws -> DiscoveryResult {
        try Task.checkCancellation()
        if discovery == nil {
            if !refresh, let discovered { return discovered }
            let registry = registry
            discovery = Task {
                let result = await registry.discover()
                discovered = result
                discovery = nil
                let waiters = discoveryWaiters.values
                discoveryWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: result) }
            }
        }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { discoveryWaiters[token] = continuation }
            }
        } onCancel: {
            Task { await self.cancelDiscoveryWaiter(token) }
        }
    }
    private func cancelDiscoveryWaiter(_ token: UUID) {
        discoveryWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
    /// Ends backend discovery before the daemon releases process ownership.
    public func shutdown() async {
        discovery?.cancel()
        await discovery?.value
    }
    private func authorize(_ context: InvocationContext?) throws -> Set<String>? {
        try Task.checkCancellation()
        if let deadline = context?.deadline, now() >= deadline { throw invalid("Request deadline exceeded") }
        guard let context else { return nil }
        let scope: Set<String>
        do { scope = try context.authorize() }
        catch { throw invalid("Unauthorized") }
        try Task.checkCancellation()
        if let deadline = context.deadline, now() >= deadline { throw invalid("Request deadline exceeded") }
        return scope
    }
    private func validate(_ context: InvocationContext?, phoneID: String) throws {
        if let scope = try authorize(context), !scope.contains(phoneID) { throw invalid("Phone unavailable or unauthorized") }
    }
    private func owner(_ context: InvocationContext?) -> Owner {
        Owner(credential: context?.credentialID ?? "", session: context?.sessionID ?? "")
    }
    private func admitMutation(_ context: InvocationContext?, phoneID: String) throws -> UUID {
        try validate(context, phoneID: phoneID)
        let instant = now(), candidate = owner(context)
        if let lease = leases[phoneID], lease.expires > instant, lease.owner != candidate {
            throw invalid("Phone control lease is held by another session")
        }
        let token = UUID()
        leases[phoneID] = Lease(owner: candidate, token: token, expires: instant + 60)
        return token
    }
    private func finishMutation(phoneID: String, token: UUID) {
        guard let lease = leases[phoneID], lease.token == token else { return }
        leases[phoneID] = Lease(owner: lease.owner, token: token, expires: now() + 60)
    }
    public func releaseControl(phoneID: String, context: InvocationContext) throws {
        try validate(context, phoneID: phoneID)
        guard let lease = leases[phoneID] else { return }
        guard lease.owner == owner(context) else { throw invalid("Phone control lease is held by another session") }
        leases.removeValue(forKey: phoneID)
    }
    func queuedCount(for id: String) -> Int { waiters[id]?.count ?? 0 }

    private func acquire(_ id: String) async throws {
        try Task.checkCancellation()
        if busy.insert(id).inserted { return }
        guard waiters[id, default: []].count < perPhoneLimit,
              waiters.values.reduce(0, { $0 + $1.count }) < globalLimit else { throw invalid("Phone request queue is full") }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(Waiter(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, token: token) }
        }
    }
    private func cancelWaiter(_ id: String, token: UUID) {
        guard let index = waiters[id]?.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters[id]!.remove(at: index)
        if waiters[id]!.isEmpty { waiters.removeValue(forKey: id) }
        waiter.continuation.resume(throwing: CancellationError())
    }
    private func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            next.continuation.resume()
        } else { busy.remove(id); waiters.removeValue(forKey: id) }
    }
}
private func invalid(_ message: String) -> PhoneError { .commandFailed(message) }
