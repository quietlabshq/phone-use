import Foundation
import PhoneUseCore
import PhoneUseMCP
import PhoneUseCapture
import Testing
@testable import PhoneUseRemote

private struct RelayEmptyRegistry: PhoneRegistry {
    func discover() async -> (phones: [any Phone], hints: [String]) { ([], []) }
}
private actor SlowRelayPhone: Phone {
    nonisolated let info = PhoneInfo(id: "phone-one", name: "Slow", kind: .simulator, screenSize: .init(width: 100, height: 200))
    var started = false
    var cancelled = false
    func screenshot() async throws -> PixelFrame {
        try PixelFrame(width: 100, height: 200, rowStride: 400, pixels: Data(repeating: 0, count: 80_000))
    }
    func perform(_ action: PhoneAction) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
    }
}
private struct SlowRelayRegistry: PhoneRegistry {
    let phone: SlowRelayPhone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], []) }
}
private actor NoisyRelayPhone: Phone {
    nonisolated let info = PhoneInfo(id: "phone-one", name: "Image", kind: .simulator, screenSize: .init(width: 618, height: 1344))
    func perform(_ action: PhoneAction) async throws {}
    func screenshot() async throws -> PixelFrame {
        let width = 618, height = 1344
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var random: UInt32 = 1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            pixels[index] = UInt8(truncatingIfNeeded: random)
            pixels[index + 1] = UInt8(truncatingIfNeeded: random >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: random >> 16)
            pixels[index + 3] = 255
        }
        return try PixelFrame(width: width, height: height, rowStride: width * 4, pixels: Data(pixels))
    }
}
private struct NoisyRelayRegistry: PhoneRegistry {
    let phone: NoisyRelayPhone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], []) }
}

@Test func relayConnectorUsesRealPeerAndDirectServiceSurvivesDisconnect() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let client = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    let hello = try await peer.waitFor(type: "hello")
    #expect(hello["generation"] as? String == peer.generation)
    let credentials = try #require(hello["credentials"] as? [[String: Any]])
    #expect(credentials.count == 1)
    #expect(credentials[0]["scopes"] as? [String] == ["phone-one"])
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"peer","version":"1"}}}"#.utf8)
    try await peer.dispatch(body: body, headers: [["host", config.publicAuthority], ["authorization", "Bearer \(client.secret)"], ["content-type", "application/json"], ["accept", "application/json, text/event-stream"]])
    let start = try await peer.waitFor(type: "result_start")
    #expect(start["status"] as? Int == 200)
    _ = try await peer.waitFor(type: "result_end")
    try await peer.disconnect()
    let direct = await service.handle(.init(method: "POST", path: "/mcp", headers: [("host", config.publicAuthority), ("authorization", "Bearer \(client.secret)"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")], body: body))
    #expect(direct.status == 200)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayPairingSendsTokenInHeaderAndKeepsDaemonSecretPrivate() async throws {
    let peer = try await RelayTestPeer.start()
    let origin = URL(string: "http://127.0.0.1:\(peer.port)")!
    let config = try await RelayPairing.pair(origin: origin, macID: "test-mac", token: "single-use-token", allowInsecureLoopback: true)
    #expect(config.daemonSecret == "daemon-secret")
    #expect(peer.pairAuthorization == "Bearer single-use-token")
    #expect(peer.pairPath == "/daemon/test-mac/pair")
    await peer.shutdown()
}

@Test func relayConnectorReplacesCredentialSnapshotsAfterCLIStoreChanges() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    try CredentialStore(directory: directory).revoke(issued.credential.id)
    let removed = try await peer.waitFor(type: "credentials", timeout: .seconds(3))
    #expect(removed["revision"] as? Int == 2)
    #expect((removed["credentials"] as? [[String: Any]])?.isEmpty == true)
    _ = try CredentialStore(directory: directory).create(phoneIDs: ["phone-two"])
    let added = try await peer.waitFor(type: "credentials", timeout: .seconds(3))
    #expect(added["revision"] as? Int == 3)
    #expect((added["credentials"] as? [[String: Any]])?.count == 1)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relaySnapshotFailureClosesSocketUntilMetadataIsValidAgain() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let valid = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    let invalid = try CredentialStore(directory: directory).create(phoneIDs: [String(repeating: "x", count: 129)])
    try await peer.waitUntil(timeout: .seconds(3)) { !peer.isConnected }
    #expect(!peer.isConnected)
    let directBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"direct","version":"1"}}}"#.utf8)
    let directRequest = RemoteHTTPRequest(method: "POST", path: "/mcp", headers: [("host", config.publicAuthority), ("authorization", "Bearer \(valid.secret)"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")], body: directBody)
    #expect(await service.handle(directRequest).status == 200)
    try await Task.sleep(for: .seconds(1))
    #expect(peer.connectionCount == 1)
    try CredentialStore(directory: directory).revoke(invalid.credential.id)
    let replacement = try await peer.waitFor(type: "hello", timeout: .seconds(5))
    #expect(peer.connectionCount == 2)
    let snapshots = try #require(replacement["credentials"] as? [[String: Any]])
    #expect(snapshots.count == 1)
    #expect(snapshots[0]["scopes"] as? [String] == ["phone-one"])
    let revokedRequest = RemoteHTTPRequest(method: "POST", path: "/mcp", headers: [("host", config.publicAuthority), ("authorization", "Bearer \(invalid.secret)"), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")], body: directBody)
    #expect(await service.handle(revokedRequest).status == 401)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayConnectorRejectsExpiredWorkAndPreservesDuplicateHeaders() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let client = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"peer","version":"1"}}}"#.utf8)
    let headers = [["host", config.publicAuthority], ["authorization", "Bearer \(client.secret)"], ["content-type", "application/json"], ["accept", "application/json, text/event-stream"]]
    try await peer.dispatch(body: body, headers: headers, deadlineMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) - 1)
    #expect(try await peer.waitFor(type: "failure")["outcome"] as? String == "not_started")
    try await peer.dispatch(body: body, headers: headers + [["authorization", "Bearer other"]])
    #expect(try await peer.waitFor(type: "result_start")["status"] as? Int == 400)
    _ = try await peer.waitFor(type: "result_end")
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayConnectorStopsAfterRevocationClose() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    try await peer.revokeConnection()
    try await Task.sleep(for: .seconds(1))
    #expect(peer.connectionCount == 1)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayConnectorReconnectsAfterOrdinarySocketLoss() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    try await peer.disconnect()
    _ = try await peer.waitFor(type: "hello", timeout: .seconds(3))
    #expect(peer.connectionCount == 2)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayConnectorReconnectsAfterSilentPeerStopsAnsweringPings() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service,
                                   heartbeatInterval: .milliseconds(100), pongTimeout: .milliseconds(100))
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    _ = try await peer.waitFor(type: "hello", timeout: .seconds(3))
    #expect(peer.connectionCount >= 2)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayConnectorStopsAfterUnauthorizedHandshake() async throws {
    let peer = try await RelayTestPeer.start(rejectConnect401: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: RelayEmptyRegistry()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    try await peer.waitUntil { peer.connectionCount >= 1 }
    try await Task.sleep(for: .seconds(1))
    #expect(peer.connectionCount == 1)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayBackoffGrowsWithCapAndJitter() {
    #expect(RelayBackoff.seconds(attempt: 0, random: 0) == 0.25)
    #expect(RelayBackoff.seconds(attempt: 1, random: 1) == 1)
    #expect(RelayBackoff.seconds(attempt: 100, random: 1) == 30)
}

@Test func relayDisconnectCancelsRunningActionAndWaitsForCleanup() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let client = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let phone = SlowRelayPhone()
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: SlowRelayRegistry(phone: phone)), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    let common = [["host", config.publicAuthority], ["authorization", "Bearer \(client.secret)"], ["content-type", "application/json"], ["accept", "application/json, text/event-stream"]]
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"peer","version":"1"}}}"#.utf8), headers: common)
    let start = try await peer.waitFor(type: "result_start")
    let headers = try #require(start["headers"] as? [[String]])
    let session = try #require(headers.first(where: { $0.first == "mcp-session-id" })?.last)
    _ = try await peer.waitFor(type: "result_end")
    let withSession = common + [["mcp-session-id", session], ["mcp-protocol-version", "2025-11-25"]]
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), headers: withSession)
    _ = try await peer.waitFor(type: "result_end")
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tap","arguments":{"phone_id":"phone-one","x":1,"y":1}}}"#.utf8), headers: withSession)
    try await peer.waitUntil { await phone.started }
    try await peer.disconnect()
    try await peer.waitUntil {
        let cancelled = await phone.cancelled
        let count = await service.activeRequestCount
        return cancelled && count == 0
    }
    #expect(await phone.cancelled)
    #expect(await service.activeRequestCount == 0)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}

@Test func relayScreenshotStreamsSequentialBoundedResultChunks() async throws {
    let peer = try await RelayTestPeer.start()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let client = try store.create(phoneIDs: ["phone-one"])
    let config = try RelayConfiguration(origin: URL(string: "http://127.0.0.1:\(peer.port)")!, macID: "test-mac", daemonSecret: "daemon-secret", allowInsecureLoopback: true)
    let service = HTTPService(credentials: store, dispatcher: ToolDispatcher(registry: NoisyRelayRegistry(phone: NoisyRelayPhone()), imageEncoder: CoreGraphicsFrameJPEGEncoder()), allowedHosts: [config.publicAuthority])
    let connector = RelayConnector(config: config, credentials: store, service: service)
    await connector.start()
    _ = try await peer.waitFor(type: "hello")
    let common = [["host", config.publicAuthority], ["authorization", "Bearer \(client.secret)"], ["content-type", "application/json"], ["accept", "application/json, text/event-stream"]]
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"peer","version":"1"}}}"#.utf8), headers: common)
    let start = try await peer.waitFor(type: "result_start")
    let session = try #require((start["headers"] as? [[String]])?.first(where: { $0.first == "mcp-session-id" })?.last)
    _ = try await peer.waitFor(type: "result_end")
    _ = peer.drain(type: "result_chunk")
    let withSession = common + [["mcp-session-id", session], ["mcp-protocol-version", "2025-11-25"]]
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), headers: withSession)
    _ = try await peer.waitFor(type: "result_start")
    _ = try await peer.waitFor(type: "result_end")
    try await peer.dispatch(body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"phone_id":"phone-one"}}}"#.utf8), headers: withSession)
    #expect(try await peer.waitFor(type: "result_start")["status"] as? Int == 200)
    _ = try await peer.waitFor(type: "result_end", timeout: .seconds(10))
    let chunks = peer.drain(type: "result_chunk")
    #expect(chunks.count > 1)
    #expect(chunks.enumerated().allSatisfy { $0.element["sequence"] as? Int == $0.offset })
    let body = chunks.reduce(into: Data()) { result, chunk in
        if let encoded = chunk["body"] as? String, let data = Data(base64Encoded: encoded) {
            #expect(data.count <= RelayWire.chunkLimit)
            result.append(data)
        }
    }
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["result"] != nil)
    await connector.stop()
    await service.shutdown()
    await peer.shutdown()
}
