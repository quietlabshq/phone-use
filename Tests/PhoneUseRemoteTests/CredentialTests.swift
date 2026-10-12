import Foundation
import Testing
@testable import PhoneUseRemote

@Test func credentialsAreScopedPrivateAndFresh() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try store.create(phoneIDs: ["one"])
    #expect(try store.authenticate(issued.secret).phoneIDs == ["one"])
    let bytes = try String(contentsOf: directory.appendingPathComponent("credentials.json"), encoding: .utf8)
    #expect(!bytes.contains(issued.secret))
    let other = try CredentialStore(directory: directory)
    try other.revoke(issued.credential.id)
    #expect(throws: (any Error).self) { try store.authenticate(issued.secret) }
    #expect(throws: (any Error).self) { try store.create(phoneIDs: []) }
    #expect(throws: (any Error).self) { try store.create(phoneIDs: ["*"]) }
    let expired = try store.create(phoneIDs: ["one"], expiresAt: .distantPast)
    #expect(throws: (any Error).self) { try store.authenticate(expired.secret) }
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let file = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("credentials.json").path)
    #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func concurrentCredentialWritersDoNotLoseUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CredentialStore(directory: directory)
    let issued = try await withThrowingTaskGroup(of: IssuedCredential.self) { group in
        for _ in 0..<20 {
            group.addTask { try CredentialStore(directory: directory).create(phoneIDs: ["one"]) }
        }
        var results: [IssuedCredential] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(try store.list().count == 20)
    #expect(Set(issued.map(\.credential.id)).count == 20)
    #expect(Set(issued.map(\.secret)).count == 20)
    for value in issued { #expect(try store.authenticate(value.secret).id == value.credential.id) }
}

@Test func credentialStoreRejectsUnsafeStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("store")
    let store = try CredentialStore(directory: directory)
    _ = try store.create(phoneIDs: ["one"])
    let dataFile = directory.appendingPathComponent("credentials.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dataFile.path)
    #expect(throws: (any Error).self) { try store.list() }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataFile.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    #expect(throws: (any Error).self) { try store.list() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let moved = root.appendingPathComponent("moved.json")
    try FileManager.default.moveItem(at: dataFile, to: moved)
    try FileManager.default.createSymbolicLink(at: dataFile, withDestinationURL: moved)
    #expect(throws: (any Error).self) { try store.list() }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    #expect(throws: (any Error).self) { try CredentialStore(directory: alias) }
}
