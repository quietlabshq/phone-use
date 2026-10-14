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
    private var controls: [String: PhoneControl] = [:]
    private var tasks: [String: TaskLabel] = [:]
    /// Calls, control changes, tasks, and agent sessions, for one local observer such as the app.
    public nonisolated let events: AsyncStream<DispatcherEvent>
    private nonisolated let eventSink: AsyncStream<DispatcherEvent>.Continuation
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
        (events, eventSink) = AsyncStream.makeStream(of: DispatcherEvent.self, bufferingPolicy: .bufferingNewest(512))
    }
    deinit { eventSink.finish() }
    public func call(_ name: String, _ args: [String: ToolArg], context: InvocationContext? = nil, agent: AgentIdentity? = nil) async -> ToolOutput {
        let agent = agent ?? context.map { AgentIdentity.remote(sessionID: $0.sessionID) } ?? AgentIdentity(id: "", name: "agent")
        var record: ToolCallRecord?
        let output = await perform(name, args, context: context, agent: agent, record: &record)
        if let record { finish(record, output) }
        return output
    }
    private func perform(_ name: String, _ args: [String: ToolArg], context: InvocationContext?, agent: AgentIdentity, record: inout ToolCallRecord?) async -> ToolOutput {
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
            record = begin(phoneID: phone.info.id, source: .agent(agent), tool: name, arguments: Self.describe(name, args),
                           touches: Self.touchKeys[name, default: []].compactMap { try? scaler.toNative(.init(x: args[$0.x]?.int ?? 0, y: args[$0.y]?.int ?? 0)) })
            if Self.mutations.contains(name) { try checkControl(phone.info.id, agent: agent) }
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
                let jpeg = try imageEncoder.jpeg(frame, maxLongEdge: 1344, quality: 0.8)
                record?.outcome = .succeeded("\(actual.width)×\(actual.height) · \(max(1, jpeg.count / 1024)) KB")
                return .jpeg(jpeg, note: "Screenshot \(actual.width)x\(actual.height). Coordinates: x 0-\(actual.width - 1), y 0-\(actual.height - 1).")
            // These change who drives the phone, so they need the control lease like actions do.
            case "request_help":
                let reason = string("reason").trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...200).contains(reason.count) else { throw invalid("reason must be 1-200 characters") }
                leaseToken = try admitMutation(context, phoneID: phone.info.id)
                return .text(try requestHelp(phone.info.id, reason: reason, agent: agent))
            case "cancel_help":
                leaseToken = try admitMutation(context, phoneID: phone.info.id)
                return .text(try cancelHelp(phone.info.id, agent: agent))
            case "set_task":
                let title = string("title").trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.count <= 80 else { throw invalid("title must be at most 80 characters") }
                leaseToken = try admitMutation(context, phoneID: phone.info.id)
                setTask(phone.info.id, title.isEmpty ? nil : TaskLabel(title: title, agent: agent, since: Date()))
                return .text(title.isEmpty ? "Task cleared." : "Task set.")
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
    /// Phones from the shared discovery, for local UIs.
    public func phones(refresh: Bool = false) async throws -> (phones: [any Phone], hints: [String]) {
        try await discover(refresh: refresh)
    }
    /// Runs local input (native pixel coordinates) through the same per-phone queue as tool calls.
    public func run(_ command: DirectCommand, phoneID: String) async throws {
        let (phones, _) = try await discover(refresh: false)
        guard let phone = phones.first(where: { $0.info.id == phoneID }) else { throw PhoneError.phoneNotFound(phoneID) }
        try await acquire(phoneID)
        var token: UUID?
        var record: ToolCallRecord? = begin(phoneID: phoneID, source: .person, tool: command.tool, arguments: command.arguments, touches: command.touches)
        defer {
            if let record { finish(record, .text("OK")) }
            if let token {
                lastMutationCompletedAt[phoneID] = FrameFreshness.now().capturedAtNanoseconds
                finishMutation(phoneID: phoneID, token: token)
            }
            release(phoneID)
        }
        do {
            token = try admitMutation(nil, phoneID: phoneID)
            switch command {
            case let .action(action): try await phone.perform(action)
            case .home: try await Macros.home(on: phone, sleeper: sleeper)
            case let .openApp(name): try await Macros.openApp(name, on: phone, sleeper: sleeper)
            }
        } catch {
            if let started = record { finish(started, .error(String(describing: error))); record = nil }
            throw error
        }
    }

    // MARK: Control

    /// Tools that change the phone, and so honor pause, take over, and help requests.
    static let mutations: Set<String> = ["tap", "long_press", "swipe", "type_text", "press_key", "press_home", "open_app"]
    private static let touchKeys: [String: [(x: String, y: String)]] = [
        "tap": [("x", "y")], "long_press": [("x", "y")], "swipe": [("from_x", "from_y"), ("to_x", "to_y")],
    ]

    public func control(of phoneID: String) -> PhoneControl { controls[phoneID] ?? .agents }
    public func task(of phoneID: String) -> TaskLabel? { tasks[phoneID] }

    /// Stops agents from changing the phone until `resume`. Only phones agents control can be paused.
    public func pause(phoneID: String) { if control(of: phoneID) == .agents { setControl(phoneID, .paused) } }
    public func resume(phoneID: String) { if control(of: phoneID) == .paused { setControl(phoneID, .agents) } }
    /// Gives the person exclusive control, ending any pause or help request.
    public func takeOver(phoneID: String) { setControl(phoneID, .person) }
    public func handBack(phoneID: String) { if control(of: phoneID) == .person { setControl(phoneID, .agents) } }

    public func agentConnected(_ agent: AgentIdentity) { eventSink.yield(.agentConnected(agent)) }
    /// Drops the agent's tasks and help requests; nobody is waiting for them any more.
    public func agentDisconnected(_ agent: AgentIdentity) {
        for (phoneID, control) in controls { if case let .helpRequested(_, owner) = control, owner == agent { setControl(phoneID, .agents) } }
        for (phoneID, task) in tasks where task.agent == agent { setTask(phoneID, nil) }
        eventSink.yield(.agentDisconnected(agent))
    }

    private func checkControl(_ phoneID: String, agent: AgentIdentity) throws {
        switch control(of: phoneID) {
        case .agents: return
        case .paused: throw invalid(ControlMessage.paused)
        case .person: throw invalid(ControlMessage.person)
        case let .helpRequested(reason, owner): throw invalid(ControlMessage.help(reason, own: owner == agent))
        }
    }
    private func requestHelp(_ phoneID: String, reason: String, agent: AgentIdentity) throws -> String {
        switch control(of: phoneID) {
        case .paused: throw invalid(ControlMessage.paused)
        case .person: throw invalid(ControlMessage.person)
        case let .helpRequested(other, owner) where owner != agent: throw invalid(ControlMessage.help(other, own: false))
        case .agents, .helpRequested:
            setControl(phoneID, .helpRequested(reason: reason, agent: agent))
            return "Asked the user for help. Actions on this phone fail until the user takes over and hands it back, or you call cancel_help. Take screenshots to see when the problem is solved."
        }
    }
    private func cancelHelp(_ phoneID: String, agent: AgentIdentity) throws -> String {
        switch control(of: phoneID) {
        case .person: throw invalid(ControlMessage.person)
        case let .helpRequested(reason, owner):
            guard owner == agent else { throw invalid(ControlMessage.help(reason, own: false)) }
            setControl(phoneID, .agents)
            return "Help request withdrawn."
        case .agents, .paused: return "No help request was pending."
        }
    }
    private func setControl(_ phoneID: String, _ control: PhoneControl) {
        guard self.control(of: phoneID) != control else { return }
        controls[phoneID] = control == .agents ? nil : control
        eventSink.yield(.control(phoneID: phoneID, control))
    }
    private func setTask(_ phoneID: String, _ task: TaskLabel?) {
        guard tasks[phoneID] != task else { return }
        tasks[phoneID] = task
        eventSink.yield(.task(phoneID: phoneID, task))
    }

    // MARK: Activity

    private func begin(phoneID: String, source: ToolCallRecord.Source, tool: String, arguments: String, touches: [PixelPoint]) -> ToolCallRecord {
        let record = ToolCallRecord(id: UUID(), phoneID: phoneID, source: source, tool: tool, arguments: arguments, touches: touches, started: Date())
        eventSink.yield(.call(record))
        return record
    }
    private func finish(_ record: ToolCallRecord, _ output: ToolOutput) {
        var record = record
        let finished = Date()
        record.finished = finished
        switch output {
        case let .error(message): record.outcome = .failed(message)
        case let .text(text) where record.outcome == .running:
            let seconds = finished.timeIntervalSince(record.started)
            record.outcome = .succeeded(text != "OK" ? text : record.tool == "type_text" ? "\(record.arguments.count - 2) keys"
                                        : seconds >= 1 ? String(format: "Done in %.1f s", seconds) : "Done")
        case .text, .jpeg: break
        }
        eventSink.yield(.call(record))
    }
    static func describe(_ name: String, _ args: [String: ToolArg]) -> String {
        func int(_ key: String) -> String { args[key]?.int.map(String.init) ?? "?" }
        func quoted(_ key: String) -> String { if case let .string(value) = args[key] { return "\"\(value)\"" }; return "" }
        switch name {
        case "tap": return "\(int("x")), \(int("y"))" + ((args["count"]?.int ?? 1) > 1 ? " ×\(int("count"))" : "")
        case "long_press": return "\(int("x")), \(int("y"))" + (args["duration_ms"] != nil ? " · \(int("duration_ms")) ms" : "")
        case "swipe": return "\(int("from_x")), \(int("from_y")) → \(int("to_x")), \(int("to_y"))"
        case "type_text": return quoted("text")
        case "press_key":
            var modifiers: [String] = []
            if case let .strings(values) = args["modifiers"] { modifiers = values }
            return (modifiers + [args["key"].flatMap { if case let .string(key) = $0 { key } else { nil } } ?? "?"]).joined(separator: "+")
                + ((args["repeat"]?.int ?? 1) > 1 ? " ×\(int("repeat"))" : "")
        case "open_app": return quoted("name")
        case "request_help": return quoted("reason")
        case "set_task": return quoted("title")
        default: return ""
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

/// Input from a local UI, already in native pixel coordinates.
public enum DirectCommand: Sendable, Equatable {
    case action(PhoneAction)
    case home
    case openApp(String)

    var tool: String {
        switch self {
        case let .action(action):
            switch action {
            case .tap: "tap"
            case .longPress: "long_press"
            case .swipe: "swipe"
            case .typeText: "type_text"
            case .key: "press_key"
            case .home: "press_home"
            }
        case .home: "press_home"
        case .openApp: "open_app"
        }
    }
    var arguments: String {
        switch self {
        case let .action(.tap(point, count)): "\(point.x), \(point.y)" + (count > 1 ? " ×\(count)" : "")
        case let .action(.longPress(point, milliseconds)): "\(point.x), \(point.y) · \(milliseconds) ms"
        case let .action(.swipe(from, to, _)): "\(from.x), \(from.y) → \(to.x), \(to.y)"
        case let .action(.typeText(text)): "\"\(text)\""
        case let .action(.key(key, modifiers, count)): (modifiers.map(\.rawValue) + [key.name]).joined(separator: "+") + (count > 1 ? " ×\(count)" : "")
        case .home, .action(.home): ""
        case let .openApp(name): "\"\(name)\""
        }
    }
    var touches: [PixelPoint] {
        switch self {
        case let .action(.tap(point, _)), let .action(.longPress(point, _)): [point]
        case let .action(.swipe(from, to, _)): [from, to]
        default: []
        }
    }
}

private extension ToolArg {
    var int: Int? { if case let .int(value) = self { return value }; return nil }
}
