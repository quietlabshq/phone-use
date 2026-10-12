import Foundation
import Testing
import PhoneUseCore
@testable import PhoneUseMCP

private final class Policy: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var allowed = true
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func revoke() { lock.withLock { allowed = false } }
    func scope() throws -> Set<String> {
        try lock.withLock { guard allowed else { throw CancellationError() }; return ["one", "two"] }
    }
    func context(_ session: String = "a", deadline: TimeInterval? = nil) -> InvocationContext {
        InvocationContext(credentialID: "credential", sessionID: session, deadline: deadline, authorize: { try self.scope() })
    }
}
private actor GatedPhone: Phone {
    nonisolated let info: PhoneInfo
    var calls: [PhoneAction] = []
    var blocked = true
    var shouldFail = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ id: String = "one") { info = .init(id: id, name: id, kind: .simulator, screenSize: .init(width: 100, height: 100)) }
    func perform(_ action: PhoneAction) async throws {
        calls.append(action)
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if shouldFail { throw PhoneError.commandFailed("Backend failed after activity") }
    }
    func failAfterActivity() { shouldFail = true }
    func unblock() { blocked = false; continuation?.resume(); continuation = nil }
    func screenshot() async throws -> PixelFrame {
        try PixelFrame(width: 100, height: 100, rowStride: 400, pixels: Data(repeating: 0, count: 40_000))
    }
}
private struct RemoteRegistry: PhoneRegistry {
    let phones: [any Phone]
    func discover() async -> (phones: [any Phone], hints: [String]) { (phones, ["private hint"]) }
}
private let tapArgs: [String: ToolArg] = ["x": .int(0), "y": .int(0)]
private func waitUntil(_ predicate: () async -> Bool) async {
    for _ in 0..<100_000 { if await predicate() { return }; await Task.yield() }
    Issue.record("Condition did not become true")
}
private func message(_ output: ToolOutput) -> String { if case let .error(value) = output { return value }; Issue.record("Expected error"); return "" }

@Test func remoteLeasesRequireValidMutationAndRespectSessions() async throws {
    let phone = GatedPhone(), policy = Policy()
    await phone.unblock()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
    _ = await dispatcher.call("tap", ["x": .int(-1), "y": .int(0)], context: policy.context())
    _ = await dispatcher.call("screenshot", [:], context: policy.context())
    _ = await dispatcher.call("tap", tapArgs, context: policy.context("b"))
    #expect(await phone.calls.count == 1)
    #expect(message(await dispatcher.call("tap", tapArgs, context: policy.context())).contains("lease"))
    await #expect(throws: (any Error).self) { try await dispatcher.releaseControl(phoneID: "one", context: policy.context()) }
    try await dispatcher.releaseControl(phoneID: "one", context: policy.context("b"))
    _ = await dispatcher.call("tap", tapArgs, context: policy.context())
    policy.advance(59)
    _ = await dispatcher.call("screenshot", [:], context: policy.context())
    _ = await dispatcher.call("tap", ["x": .int(-1), "y": .int(0)], context: policy.context())
    policy.advance(1)
    _ = await dispatcher.call("tap", tapArgs, context: policy.context("b"))
    #expect(await phone.calls.count == 3)
}

@Test func queuedRevocationAndDeadlinesPreventExecution() async {
    for revoke in [true, false] {
        let phone = GatedPhone(), policy = Policy()
        let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
        let first = Task { await dispatcher.call("tap", tapArgs, context: policy.context()) }
        await waitUntil { await phone.calls.count == 1 }
        let queued = Task { await dispatcher.call("tap", tapArgs, context: policy.context(deadline: 10)) }
        await waitUntil { await dispatcher.queuedCount(for: "one") == 1 }
        if revoke { policy.revoke() } else { policy.advance(10) }
        await phone.unblock()
        _ = await first.value
        let error = message(await queued.value)
        #expect(error.contains(revoke ? "Unauthorized" : "deadline"))
        #expect(await phone.calls.count == 1)
    }
}

@Test func leaseExpiryDoesNotUnlockRunningAction() async {
    let phone = GatedPhone(), policy = Policy()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
    let first = Task { await dispatcher.call("tap", tapArgs, context: policy.context()) }
    await waitUntil { await phone.calls.count == 1 }
    policy.advance(61)
    let second = Task { await dispatcher.call("tap", tapArgs, context: policy.context("b")) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 1 }
    #expect(await phone.calls.count == 1)
    await phone.unblock()
    _ = await first.value
    #expect(message(await second.value).contains("lease"))
    #expect(await phone.calls.count == 1)
    policy.advance(59)
    #expect(message(await dispatcher.call("tap", tapArgs, context: policy.context("b"))).contains("lease"))
    policy.advance(1)
    _ = await dispatcher.call("tap", tapArgs, context: policy.context("b"))
    #expect(await phone.calls.count == 2)
}

@Test func releasingInFlightLeaseDoesNotRecreateItOnCompletion() async throws {
    let phone = GatedPhone(), policy = Policy()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
    let first = Task { await dispatcher.call("tap", tapArgs, context: policy.context()) }
    await waitUntil { await phone.calls.count == 1 }
    try await dispatcher.releaseControl(phoneID: "one", context: policy.context())
    let second = Task { await dispatcher.call("tap", tapArgs, context: policy.context("b")) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 1 }
    #expect(await phone.calls.count == 1)
    await phone.unblock()
    _ = await first.value; _ = await second.value
    #expect(await phone.calls.count == 2)
}

@Test func boundedFIFOQueueRemovesCancelledWaiters() async {
    let phone = GatedPhone()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), perPhoneQueueLimit: 2)
    let first = Task { await dispatcher.call("tap", tapArgs) }
    await waitUntil { await phone.calls.count == 1 }
    let cancelled = Task { await dispatcher.call("tap", ["x": .int(1), "y": .int(0)]) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 1 }
    let second = Task { await dispatcher.call("tap", ["x": .int(2), "y": .int(0)]) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 2 }
    #expect(message(await dispatcher.call("tap", tapArgs)).contains("queue is full"))
    cancelled.cancel()
    _ = await cancelled.value
    #expect(await dispatcher.queuedCount(for: "one") == 1)
    let third = Task { await dispatcher.call("tap", ["x": .int(3), "y": .int(0)]) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 2 }
    await phone.unblock()
    _ = await first.value; _ = await second.value; _ = await third.value
    #expect(await phone.calls == [.tap(.init(x: 0, y: 0), count: 1), .tap(.init(x: 2, y: 0), count: 1), .tap(.init(x: 3, y: 0), count: 1)])
}

@Test func globalQueueLimitAndStartedCancellation() async {
    let one = GatedPhone(), two = GatedPhone("two")
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [one, two]), globalQueueLimit: 1)
    let argsOne = tapArgs.merging(["phone_id": .string("one")]) { _, new in new }
    let argsTwo = tapArgs.merging(["phone_id": .string("two")]) { _, new in new }
    let first = Task { await dispatcher.call("tap", argsOne) }
    let second = Task { await dispatcher.call("tap", argsTwo) }
    await waitUntil { let a = await one.calls.count; let b = await two.calls.count; return a == 1 && b == 1 }
    let queued = Task { await dispatcher.call("tap", argsOne) }
    await waitUntil { await dispatcher.queuedCount(for: "one") == 1 }
    #expect(message(await dispatcher.call("tap", argsTwo)).contains("queue is full"))
    first.cancel()
    await one.unblock(); await two.unblock()
    #expect(message(await first.value).contains("outcome unknown"))
    _ = await second.value; _ = await queued.value
}

@Test func deadlineIsRecheckedAfterAuthorizationImmediatelyBeforeExecution() async {
    let phone = GatedPhone(), policy = Policy()
    await phone.unblock()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
    let context = InvocationContext(credentialID: "credential", sessionID: "a", deadline: 4) {
        policy.advance(1)
        return ["one"]
    }
    #expect(message(await dispatcher.call("tap", tapArgs, context: context)).contains("deadline"))
    #expect(await phone.calls.isEmpty)
}

@Test(arguments: [false, true]) func failedOrCancelledMutationStartsIdlePeriodAtCompletion(cancel: Bool) async {
    let phone = GatedPhone(), policy = Policy()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phones: [phone]), now: { policy.now() })
    let first = Task { await dispatcher.call("tap", tapArgs, context: policy.context()) }
    await waitUntil { await phone.calls.count == 1 }
    policy.advance(61)
    if cancel { first.cancel() } else { await phone.failAfterActivity() }
    await phone.unblock()
    let error = message(await first.value)
    #expect(error.contains(cancel ? "outcome unknown" : "Backend failed"))
    #expect(message(await dispatcher.call("tap", tapArgs, context: policy.context("b"))).contains("lease"))
    #expect(await phone.calls.count == 1)
}

private actor BlockedDiscovery: PhoneRegistry {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func discover() async -> (phones: [any Phone], hints: [String]) {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return ([], [])
    }
    func unblock() { continuation?.resume(); continuation = nil }
}
@Test(.timeLimit(.minutes(1))) func discoveryWaitersCancelIndependentlyAndRefreshCoalesces() async {
    let registry = BlockedDiscovery()
    let dispatcher = ToolDispatcher(registry: registry)
    let first = Task { await dispatcher.call("list_phones", [:]) }
    await waitUntil { await registry.continuation != nil }
    let second = Task { await dispatcher.call("list_phones", [:]) }
    first.cancel()
    #expect(message(await first.value).contains("CancellationError"))
    #expect(await registry.calls == 1)
    second.cancel()
    #expect(message(await second.value).contains("CancellationError"))
    await registry.unblock()
    await dispatcher.shutdown()
}
