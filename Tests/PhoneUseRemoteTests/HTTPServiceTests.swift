import Foundation
import Testing
import PhoneUseCore
import PhoneUseMCP
import PhoneUseCapture
@testable import PhoneUseRemote

private struct EmptyRegistry: PhoneRegistry {
    func discover() async -> (phones: [any Phone], hints: [String]) { ([], ["private hint"]) }
}
@Test func httpAuthenticationAndSessionOwnership() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let first = try store.create(phoneIDs: ["one"])
    let second = try store.create(phoneIDs: ["one"])
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: EmptyRegistry()), allowedHosts: ["localhost"])
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
    func request(_ secret: String, session: String? = nil) -> RemoteHTTPRequest {
        var headers = [("host", "localhost"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream"), ("authorization", "Bearer \(secret)")]
        if let session { headers.append(("mcp-session-id", session)); headers.append(("mcp-protocol-version", "2025-11-25")) }
        return .init(method: "POST", path: "/mcp", headers: headers, body: body)
    }
    #expect(await service.handle(request("wrong")).status == 401)
    let initialized = await service.handle(request(first.secret))
    #expect(initialized.status == 200)
    let session = try #require(initialized.headers["mcp-session-id"])
    #expect(await service.handle(request(second.secret, session: session)).status == 404)
    #expect(await service.handle(request(first.secret, session: session)).status == 400)
    try store.revoke(first.credential.id)
    #expect(await service.handle(request(first.secret, session: session)).status == 401)
    await service.shutdown()
}

import MCP

private actor RemotePhone: Phone {
    nonisolated let info = PhoneInfo(id: "one", name: "Fake", kind: .simulator, screenSize: .init(width: 100, height: 200))
    var actions: [PhoneAction] = []
    func perform(_ action: PhoneAction) async throws { actions.append(action) }
    func screenshot() async throws -> PixelFrame {
        try PixelFrame(width: 100, height: 200, rowStride: 400, pixels: Data(repeating: 0, count: 80_000))
    }
}
private struct RemoteRegistry: PhoneRegistry {
    let phone: RemotePhone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], ["private hint"]) }
}
private struct RemoteNoSleep: Sleeper { func sleep(milliseconds: Int) async throws {} }

@Test func realLoopbackSDKInitializationCatalogImagesAndActions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let phone = RemotePhone()
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RemoteRegistry(phone: phone), sleeper: RemoteNoSleep(), imageEncoder: CoreGraphicsFrameJPEGEncoder()), allowedHosts: [])
    let listener = try await HTTPListener.start(service: service, port: 0)
    let client = Client(name: "loopback-test", version: "1")
    let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!, streaming: false, requestModifier: { request in
        var request = request; request.setValue("Bearer \(issued.secret)", forHTTPHeaderField: "Authorization"); return request
    })
    do {
        let initialization = try await client.connect(transport: transport)
        #expect(initialization.protocolVersion == "2025-11-25")
        #expect(try await client.listTools().tools.count == MCPServer.tools.count)
        let listed = try await client.callTool(name: "list_phones")
        #expect(!String(describing: listed).contains("private hint"))
        let screenshot = try await client.callTool(name: "screenshot")
        guard case let .image(data, mimeType, _, _) = screenshot.content.first else { throw CocoaError(.fileReadCorruptFile) }
        #expect(mimeType == "image/jpeg")
        #expect(Data(base64Encoded: data)?.prefix(2) == Data([0xff, 0xd8]))
        let tapped = try await client.callTool(name: "tap", arguments: ["x": .int(10), "y": .int(20)])
        #expect(tapped.isError != true)
        #expect(await phone.actions.count == 1)
        await client.disconnect()
        await listener.shutdown()
    } catch {
        await client.disconnect(); await listener.shutdown(); throw error
    }
}

private final class RemoteClock: @unchecked Sendable {
    let lock = NSLock()
    private var time: TimeInterval = 100
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ delta: TimeInterval) { lock.withLock { time += delta } }
}
private struct HTTPFixture {
    let directory: URL
    let store: CredentialStore
    let secret: String
    let service: HTTPService
    init(clock: RemoteClock = RemoteClock(), dispatcher: ToolDispatcher = ToolDispatcher(registry: EmptyRegistry())) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try CredentialStore(directory: directory)
        secret = try store.create(phoneIDs: ["one"]).secret
        service = HTTPService(credentials: store, dispatcher: dispatcher, allowedHosts: ["localhost"], idleTimeout: 10, clock: { clock.now })
    }
    func request(_ body: String, session: String? = nil, extra: [(String, String)] = [], method: String = "POST", path: String = "/mcp") -> RemoteHTTPRequest {
        var headers = [("host", "localhost"), ("authorization", "Bearer \(secret)"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")]
        if let session { headers += [("mcp-session-id", session), ("mcp-protocol-version", "2025-11-25")] }
        return .init(method: method, path: path, headers: headers + extra, body: Data(body.utf8))
    }
    func initialize() async throws -> String {
        let result = await service.handle(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#))
        return try #require(result.headers["mcp-session-id"])
    }
}
@Test func sessionExpiryAndProtocolValidationAreDeterministic() async throws {
    let clock = RemoteClock()
    let fixture = try HTTPFixture(clock: clock)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let sid = try await fixture.initialize()
    #expect(await fixture.service.handle(fixture.request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, session: sid)).status == 400)
    #expect(await fixture.service.handle(fixture.request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: sid)).status == 202)
    #expect(await fixture.service.handle(fixture.request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, session: sid)).status == 200)
    #expect(await fixture.service.handle(fixture.request("{}", session: sid, extra: [("MCP-Protocol-Version", "bad")])).status == 400)
    #expect(await fixture.service.handle(fixture.request("{}", session: sid), deadline: clock.now).status == 408)
    clock.advance(11)
    #expect(await fixture.service.handle(fixture.request("{}", session: sid)).status == 404)
    await fixture.service.shutdown()
}
@Test func endedSessionsDropTheirHelpRequests() async throws {
    let clock = RemoteClock()
    let dispatcher = ToolDispatcher(registry: RemoteRegistry(phone: RemotePhone()))
    let fixture = try HTTPFixture(clock: clock, dispatcher: dispatcher)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    for end in ["delete", "expire"] {
        let sid = try await fixture.initialize()
        #expect(await fixture.service.handle(fixture.request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: sid)).status == 202)
        let help = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_help","arguments":{"reason":"Passcode"}}}"#
        #expect(await fixture.service.handle(fixture.request(help, session: sid)).status == 200)
        #expect(await dispatcher.control(of: "one") == .helpRequested(reason: "Passcode", agent: .remote(sessionID: sid)))
        if end == "delete" {
            #expect(await fixture.service.handle(fixture.request("", session: sid, method: "DELETE")).status == 204)
        } else {
            clock.advance(11)
            _ = await fixture.service.handle(fixture.request("{}"))
        }
        #expect(await dispatcher.control(of: "one") == .agents)
    }
    await fixture.service.shutdown()
}
@Test func requestAndSessionLimitsRejectWithoutAllocationGrowth() async throws {
    let fixture = try HTTPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    #expect(await fixture.service.handle(fixture.request("{}", extra: [("Authorization", "Bearer other")])).status == 400)
    #expect(await fixture.service.handle(fixture.request("{}", extra: [("Origin", "https://evil.example")])).status == 403)
    #expect(await fixture.service.handle(fixture.request("{}", extra: [("Host", "evil.example")])).status == 400)
    #expect(await fixture.service.handle(fixture.request("{}", extra: [("x-large", String(repeating: "a", count: 16384))])).status == 431)
    #expect(await fixture.service.handle(fixture.request(String(repeating: "a", count: 262145))).status == 413)
    #expect(await fixture.service.handle(fixture.request("[]")).status == 400)
    #expect(await fixture.service.handle(fixture.request("{}", method: "GET")).status == 405)
    #expect(await fixture.service.handle(fixture.request("{}", path: "/mcp?secret=bad")).status == 404)
    for _ in 0..<64 { _ = try await fixture.initialize() }
    let overflow = await fixture.service.handle(fixture.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#))
    #expect(overflow.status == 503)
    await fixture.service.shutdown()
}

@Test func realLoopbackRejectsInvalidBearerAndOversizedBody() async throws {
    let fixture = try HTTPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let listener = try await HTTPListener.start(service: fixture.service, port: 0)
    do {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, missing) = try await URLSession.shared.data(for: request)
        #expect((missing as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer bad", forHTTPHeaderField: "Authorization")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 401)
        request.httpBody = Data(repeating: 0, count: 262145)
        let (_, oversized) = try await URLSession.shared.data(for: request)
        #expect((oversized as? HTTPURLResponse)?.statusCode == 413)
        await listener.shutdown()
    } catch { await listener.shutdown(); throw error }
}

private actor HTTPGate {
    private var entered = false
    private var open = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    func block() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !open { await withCheckedContinuation { exitWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        open = true
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
    }
}
private actor GatedRemotePhone: Phone {
    nonisolated let info = PhoneInfo(id: "one", name: "Gated", kind: .simulator, screenSize: .init(width: 10, height: 10))
    let gate: HTTPGate
    var count = 0
    var cancelledAfterBlock = false
    init(gate: HTTPGate) { self.gate = gate }
    func perform(_ action: PhoneAction) async throws { count += 1; await gate.block(); cancelledAfterBlock = Task.isCancelled }
    func screenshot() async throws -> PixelFrame { throw PhoneError.commandFailed("Unused screenshot") }
}
private struct SingleRemoteRegistry: PhoneRegistry {
    let phone: any Phone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], []) }
}
private func remoteRequest(secret: String, session: String? = nil, method: String, id: Value? = nil, params: Value = .object([:])) throws -> RemoteHTTPRequest {
    var object: [String: Value] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
    object["id"] = id
    var headers = [("host", "localhost"), ("authorization", "Bearer \(secret)"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")]
    if let session { headers += [("mcp-session-id", session), ("mcp-protocol-version", "2025-11-25")] }
    return .init(method: "POST", path: "/mcp", headers: headers, body: try JSONEncoder().encode(object))
}
private func remoteSession(_ service: HTTPService, _ secret: String) async throws -> String {
    let response = await service.handle(try remoteRequest(secret: secret, method: "initialize", id: .int(0), params: .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])])))
    let id = try #require(response.headers["mcp-session-id"])
    _ = await service.handle(try remoteRequest(secret: secret, session: id, method: "notifications/initialized"))
    return id
}
@Test(.timeLimit(.minutes(1))) func cancellationIDsAndQueuedRevocationAreIsolated() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = GatedRemotePhone(gate: gate)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: SingleRemoteRegistry(phone: phone), sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let a = try await remoteSession(service, issued.secret), b = try await remoteSession(service, issued.secret)
    let action = try remoteRequest(secret: issued.secret, session: a, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    let running = Task { await service.handle(action) }
    await gate.waitUntilEntered()
    #expect(await service.handle(action).status == 409)
    let otherSession = await service.handle(try remoteRequest(secret: issued.secret, session: b, method: "tools/list", id: .int(1)))
    #expect(otherSession.status == 200)
    let stringID = await service.handle(try remoteRequest(secret: issued.secret, session: a, method: "ping", id: .string("1")))
    #expect(stringID.status == 200)
    #expect(String(data: stringID.body, encoding: .utf8)?.contains("\"id\":\"1\"") == true)
    let queuedRequest = try remoteRequest(secret: issued.secret, session: a, method: "tools/call", id: .int(2), params: .object(["name": .string("press_home")]))
    let queued = Task { await service.handle(queuedRequest) }
    while await service.activeRequestCount < 2 { await Task.yield() }
    _ = await service.handle(try remoteRequest(secret: issued.secret, session: a, method: "notifications/cancelled", params: .object(["requestId": .int(2)])))
    let cancelled = await queued.value
    #expect(String(data: cancelled.body, encoding: .utf8)?.contains("isError") == true)
    #expect(await phone.count == 1)
    let revoked = Task { await service.handle(queuedRequest) }
    while await service.activeRequestCount < 2 { await Task.yield() }
    try store.revoke(issued.credential.id)
    await gate.release()
    _ = await running.value
    let rejected = await revoked.value
    #expect(String(data: rejected.body, encoding: .utf8)?.contains("isError") == true)
    #expect(await phone.count == 1)
    await service.shutdown()
}
@Test(.timeLimit(.minutes(1))) func shutdownWaitsForRunningMutationCleanup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = GatedRemotePhone(gate: gate)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: SingleRemoteRegistry(phone: phone), sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let session = try await remoteSession(service, issued.secret)
    let request = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    let running = Task { await service.handle(request) }
    await gate.waitUntilEntered()
    let shutdown = Task { await service.shutdown() }
    while await !service.isStopped { await Task.yield() }
    #expect(await service.activeRequestCount == 1)
    #expect(await service.handle(request).status == 503)
    await gate.release()
    let response = await running.value
    #expect(String(data: response.body, encoding: .utf8)?.contains("unknown") == true)
    await shutdown.value
    #expect(await service.activeRequestCount == 0)
}

private actor GatedRemoteRegistry: PhoneRegistry {
    let gate: HTTPGate
    let phone: RemotePhone
    var count = 0
    init(gate: HTTPGate, phone: RemotePhone) { self.gate = gate; self.phone = phone }
    func discover() async -> (phones: [any Phone], hints: [String]) { count += 1; await gate.block(); return ([phone], []) }
}
@Test(.timeLimit(.minutes(1))) func discoveryCancellationReturnsWithoutCancellingOtherClients() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = RemotePhone()
    let registry = GatedRemoteRegistry(gate: gate, phone: phone)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: registry, sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let session = try await remoteSession(service, issued.secret)
    let request = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    let running = Task { await service.handle(request) }
    await gate.waitUntilEntered()
    let otherRequest = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(2), params: .object(["name": .string("list_phones")]))
    let other = Task { await service.handle(otherRequest) }
    while await service.activeRequestCount < 2 { await Task.yield() }
    _ = await service.handle(try remoteRequest(secret: issued.secret, session: session, method: "notifications/cancelled", params: .object(["requestId": .int(1)])))
    let cancelled = await running.value
    #expect(String(data: cancelled.body, encoding: .utf8)?.contains("isError") == true)
    #expect(await service.activeRequestCount == 1)
    let thirdRequest = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(3), params: .object(["name": .string("press_home")]))
    let externalCancellation = Task { await service.handle(thirdRequest) }
    while await service.activeRequestCount < 2 { await Task.yield() }
    externalCancellation.cancel()
    let externallyCancelled = await externalCancellation.value
    #expect(String(data: externallyCancelled.body, encoding: .utf8)?.contains("isError") == true)
    #expect(await service.activeRequestCount == 1)
    await gate.release()
    #expect(await other.value.status == 200)
    #expect(await registry.count == 1)
    #expect(await phone.actions.isEmpty)
    await service.shutdown()
}

@Test(.timeLimit(.minutes(1))) func activeRequestLimitAndDiscoveryDeadline() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = RemotePhone()
    let registry = GatedRemoteRegistry(gate: gate, phone: phone)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: registry), allowedHosts: ["localhost"])
    let session = try await remoteSession(service, issued.secret)
    let request = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    let expired = Task { await service.handle(request, deadline: MonotonicClock.now + 0.05) }
    await gate.waitUntilEntered()
    let expiration = await expired.value
    #expect(String(data: expiration.body, encoding: .utf8)?.contains("isError") == true)
    #expect(await phone.actions.isEmpty)
    var tasks: [Task<RemoteHTTPResponse, Never>] = []
    for id in 0..<32 {
        let next = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(id), params: .object(["name": .string("list_phones")]))
        tasks.append(Task { await service.handle(next) })
    }
    while await service.activeRequestCount < 32 { await Task.yield() }
    let overflow = try remoteRequest(secret: issued.secret, session: session, method: "ping", id: .int(33))
    #expect(await service.handle(overflow).status == 503)
    #expect(await registry.count == 1)
    await gate.release()
    for task in tasks { #expect(await task.value.status == 200) }
    #expect(await phone.actions.isEmpty)
    await service.shutdown()
}

@Test func HTTPLeasesReleaseAndDeleteUseSessionIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let phone = RemotePhone()
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RemoteRegistry(phone: phone), sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let first = try await remoteSession(service, issued.secret), second = try await remoteSession(service, issued.secret)
    func call(_ session: String) throws -> RemoteHTTPRequest { try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")])) }
    #expect(await service.handle(try call(first)).status == 200)
    let conflict = await service.handle(try call(second))
    #expect(String(data: conflict.body, encoding: .utf8)?.contains("lease") == true)
    let template = try call(first)
    let release = RemoteHTTPRequest(method: "POST", path: "/leases/release", headers: template.headers, body: Data(#"{"phone_id":"one"}"#.utf8))
    #expect(await service.handle(release).status == 204)
    #expect(await service.handle(try call(second)).status == 200)
    #expect(await phone.actions.count == 2)
    let other = try call(second)
    #expect(await service.handle(.init(method: "DELETE", path: "/mcp", headers: other.headers)).status == 204)
    _ = await service.handle(try call(first))
    #expect(await phone.actions.count == 3)
    await service.shutdown()
}

@Test func boundedResponseDoesNotSerializeUnboundedCatalogToClient() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: EmptyRegistry()), allowedHosts: ["localhost"], maximumResponseBytes: 512)
    let session = try await remoteSession(service, issued.secret)
    let response = await service.handle(try remoteRequest(secret: issued.secret, session: session, method: "tools/list", id: .int(1)))
    #expect(response.body.count <= 512)
    #expect(String(data: response.body, encoding: .utf8)?.contains("Response exceeds server limit") == true)
    await service.shutdown()
}
@Test(.timeLimit(.minutes(1))) func realLoopbackInputIdleTimeoutDoesNotInterruptRunningAction() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = GatedRemotePhone(gate: gate)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: SingleRemoteRegistry(phone: phone), sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let listener = try await HTTPListener.start(service: service, port: 0, inputIdleTimeout: 0.01)
    let session = try await remoteSession(service, issued.secret)
    let template = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!)
    request.httpMethod = "POST"; request.httpBody = template.body
    for (name, value) in template.headers { request.setValue(value, forHTTPHeaderField: name) }
    let response = Task { try await URLSession.shared.data(for: request) }
    await gate.waitUntilEntered()
    // This delay tests elapsed idle time after entry, not scheduling a race.
    try await Task.sleep(for: .milliseconds(50))
    await gate.release()
    do {
        let (body, result) = try await response.value
        #expect((result as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("isError") != true)
        await listener.shutdown()
    } catch { await listener.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func HTTPDisconnectDoesNotCancelExecutionOrReplayInput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    let gate = HTTPGate(), phone = GatedRemotePhone(gate: gate)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: SingleRemoteRegistry(phone: phone), sleeper: RemoteNoSleep()), allowedHosts: ["localhost"])
    let listener = try await HTTPListener.start(service: service, port: 0)
    let session = try await remoteSession(service, issued.secret)
    let template = try remoteRequest(secret: issued.secret, session: session, method: "tools/call", id: .int(1), params: .object(["name": .string("press_home")]))
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!)
    request.httpMethod = "POST"; request.httpBody = template.body
    for (name, value) in template.headers { request.setValue(value, forHTTPHeaderField: name) }
    let response = Task { try await URLSession.shared.data(for: request) }
    await gate.waitUntilEntered()
    response.cancel()
    _ = try? await response.value
    #expect(await service.activeRequestCount == 1)
    await gate.release()
    while await service.activeRequestCount > 0 { await Task.yield() }
    #expect(await phone.count == 1)
    #expect(await !phone.cancelledAfterBlock)
    await listener.shutdown()
}
