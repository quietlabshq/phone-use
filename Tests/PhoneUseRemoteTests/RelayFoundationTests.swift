import CryptoKit
import Foundation
import Testing
@testable import PhoneUseRemote

@Test func relaySnapshotIsDigestOnlyAndReflectsStoreChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["phone-b", "phone-a"], expiresAt: Date(timeIntervalSince1970: 2_000))
    let expired = try store.create(phoneIDs: ["phone-a"], expiresAt: Date(timeIntervalSince1970: 1_000))
    let snapshot = try store.relaySnapshot(now: Date(timeIntervalSince1970: 1_500))
    #expect(snapshot.count == 1)
    #expect(snapshot[0].digest == SHA256.hash(data: Data(issued.secret.utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(snapshot[0].scopes == ["phone-a", "phone-b"])
    #expect(snapshot[0].expiresAt == 2_000_000)
    #expect(!String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!.contains(issued.secret))
    #expect(!snapshot.contains { $0.digest == expired.credential.id })
    try CredentialStore(directory: directory).revoke(issued.credential.id)
    #expect(try store.relaySnapshot(now: Date(timeIntervalSince1970: 1_500)).isEmpty)
}

@Test func relayCredentialSnapshotEncodesAbsentExpiryAsExplicitNull() throws {
    let credential = RelayCredentialSnapshot(digest: String(repeating: "a", count: 64), scopes: ["phone"], expiresAt: nil)
    let frame = try RelayWire.hello(generation: "00000000-0000-0000-0000-000000000001", credentials: [credential])
    let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    let credentials = try #require(object["credentials"] as? [[String: Any]])
    #expect(credentials.count == 1)
    #expect(credentials[0]["expiresAt"] is NSNull)
}

@Test func relaySnapshotRefusesMetadataBeyondWorkerBounds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    _ = try store.create(phoneIDs: [String(repeating: "x", count: 129)])
    #expect(throws: (any Error).self) { try store.relaySnapshot() }
}

@Test func relayConfigRequiresSafeEndpointAndPrivateStorage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayConfigStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "https://relay.example")!, macID: "mac_1", daemonSecret: "secret-value")
    try store.save(config)
    #expect(try store.load() == config)
    let defaultPort = try RelayConfiguration(origin: URL(string: "https://relay.example:443")!, macID: "mac_1", daemonSecret: "secret-value")
    #expect(defaultPort.publicAuthority == "relay.example")
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
    let file = directory.appendingPathComponent("relay.json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "https://evil.example/@relay.example")!, macID: "mac", daemonSecret: "secret") }
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "https://relay.example?token=x")!, macID: "mac", daemonSecret: "secret") }
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "http://relay.example")!, macID: "mac", daemonSecret: "secret") }
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "https://user:password@relay.example")!, macID: "mac", daemonSecret: "secret") }
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "https://relay.example/#fragment")!, macID: "mac", daemonSecret: "secret") }
    #expect(throws: (any Error).self) { try RelayConfiguration(origin: URL(string: "http://192.0.2.1")!, macID: "mac", daemonSecret: "secret", allowInsecureLoopback: true) }
    try store.remove()
    #expect(try store.load() == nil)
}

@Test func uppercaseHTTPSOriginCannotDowngradeDaemonWebSocket() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = try RelayConfiguration(origin: URL(string: "HTTPS://Relay.Example:443")!, macID: "mac", daemonSecret: "secret")
    #expect(config.origin.scheme == "https")
    #expect(config.origin.host == "relay.example")
    #expect(config.connectURL.scheme == "wss")
    #expect(config.connectURL.host == "relay.example")
    #expect(config.pairURL.scheme == "https")
    #expect(config.publicAuthority == "relay.example")
    let store = try RelayConfigStore(directory: directory)
    try store.save(config)
    let loaded = try #require(try store.load())
    #expect(loaded.connectURL.scheme == "wss")
    #expect(loaded.publicAuthority == "relay.example")
}

@Test func relayConfigRejectsSymlinkAndLoosePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent("relay")
    let store = try RelayConfigStore(directory: directory)
    let config = try RelayConfiguration(origin: URL(string: "https://relay.example")!, macID: "mac", daemonSecret: "secret")
    try store.save(config)
    let file = directory.appendingPathComponent("relay.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try store.load() }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("real.json"))
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("real.json"))
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(config) }
}

@Test func relayDispatchValidationAndChunks() throws {
    let generation = UUID().uuidString.lowercased()
    let dispatchID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let body = Data("{}".utf8)
    let frame = """
    {"v":1,"type":"dispatch","generation":"\(generation)","dispatchID":"\(dispatchID)","requestID":"\(requestID)","deadline":2000,"method":"POST","path":"/mcp","headers":[["host","relay.example"],["authorization","Bearer abc"]],"body":"\(body.base64EncodedString())"}
    """
    let dispatch = try RelayWire.parseDispatch(Data(frame.utf8), generation: generation, nowMilliseconds: 1_000)
    #expect(dispatch.request.headers.map(\.0) == ["host", "authorization"])
    #expect(dispatch.request.body == body)
    #expect(dispatch.deadlineInterval == 1)
    #expect(throws: (any Error).self) { try RelayWire.parseDispatch(Data(frame.replacingOccurrences(of: generation, with: UUID().uuidString.lowercased()).utf8), generation: generation, nowMilliseconds: 1_000) }
    #expect(throws: (any Error).self) { try RelayWire.parseDispatch(Data(frame.utf8), generation: generation, nowMilliseconds: 2_000) }
    let response = RemoteHTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(repeating: 42, count: 200_000))
    let frames = try RelayWire.resultFrames(for: dispatch, response: response)
    #expect(frames.count == 4)
    #expect(frames.allSatisfy { $0.count <= 384 * 1024 })
    let duplicated = frame.replacingOccurrences(of: #"["authorization","Bearer abc"]"#, with: #"["authorization","Bearer abc"],["authorization","Bearer other"]"#)
    #expect(try RelayWire.parseDispatch(Data(duplicated.utf8), generation: generation, nowMilliseconds: 1_000).request.headers.count == 3)
}

@Test func relayCatalogMatchesSharedGoldenFixture() throws {
    let frame = try RelayWire.hello(generation: "00000000-0000-0000-0000-000000000001", credentials: [])
    let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    let catalog = try #require(object["catalog"] as? [String: Any])
    let canonical = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("relay/fixtures/catalog.json")
    if ProcessInfo.processInfo.environment["UPDATE_RELAY_CATALOG_GOLDEN"] == "1" {
        try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try canonical.write(to: fixture)
    }
    let expected = try Data(contentsOf: fixture)
    #expect(canonical == expected)
}
