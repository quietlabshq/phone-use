import CryptoKit
import Darwin
import Foundation
import Security

public struct Credential: Codable, Sendable, Equatable {
    public let id: String
    public let phoneIDs: Set<String>
    public let expiresAt: Date?
    public var revoked: Bool
    fileprivate let digest: String
}

public struct CredentialMetadata: Sendable, Equatable {
    public let id: String
    public let phoneIDs: Set<String>
    public let expiresAt: Date?
    public let revoked: Bool
}

/// The relay receives only an advisory digest snapshot. The local store remains authoritative.
public struct RelayCredentialSnapshot: Codable, Sendable, Equatable {
    public let digest: String
    public let scopes: [String]
    public let expiresAt: Int64?

    private enum CodingKeys: String, CodingKey { case digest, scopes, expiresAt }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(digest, forKey: .digest)
        try values.encode(scopes, forKey: .scopes)
        if let expiresAt {
            try values.encode(expiresAt, forKey: .expiresAt)
        } else {
            try values.encodeNil(forKey: .expiresAt)
        }
    }
}

public struct IssuedCredential: Sendable {
    public let credential: Credential
    /// Returned only at creation. Persist only the credential, never this value.
    public let secret: String
}

public enum CredentialError: Error, Sendable {
    case unauthorized, invalidScope, unsafeStorage, storageFailure(Int32), randomFailure
}

/// Each operation locks and reloads the store, including authentication and authorization.
public final class CredentialStore: Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try transaction { _ in () }
    }

    public func create(phoneIDs: Set<String>, expiresAt: Date? = nil) throws -> IssuedCredential {
        guard !phoneIDs.isEmpty, phoneIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "*" }) else { throw CredentialError.invalidScope }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CredentialError.randomFailure }
        let secret = Data(bytes).base64EncodedString()
        let credential = Credential(id: UUID().uuidString, phoneIDs: phoneIDs, expiresAt: expiresAt, revoked: false, digest: Self.digest(secret))
        try transaction(write: true) { $0.append(credential) }
        return IssuedCredential(credential: credential, secret: secret)
    }

    public func authenticate(_ secret: String, now: Date = Date()) throws -> Credential {
        let digest = Self.digest(secret)
        return try transaction { credentials in
            guard let credential = credentials.first(where: { Self.equal($0.digest, digest) }), Self.valid(credential, now: now) else { throw CredentialError.unauthorized }
            return credential
        }
    }

    public func authorize(credentialID: String, now: Date = Date()) throws -> Set<String> {
        try transaction { credentials in
            guard let credential = credentials.first(where: { $0.id == credentialID }), Self.valid(credential, now: now) else { throw CredentialError.unauthorized }
            return credential.phoneIDs
        }
    }

    public func list() throws -> [CredentialMetadata] {
        try transaction { $0.map { CredentialMetadata(id: $0.id, phoneIDs: $0.phoneIDs, expiresAt: $0.expiresAt, revoked: $0.revoked) } }
    }

    public func relaySnapshot(now: Date = Date()) throws -> [RelayCredentialSnapshot] {
        try transaction { credentials in
            let active = credentials.filter { Self.valid($0, now: now) }
            guard active.count <= 256 else { throw CredentialError.invalidScope }
            let snapshot = try active.map { credential in
                let scopes = credential.phoneIDs.sorted()
                guard !scopes.isEmpty, scopes.count <= 64,
                      scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0 != "*" }) else { throw CredentialError.invalidScope }
                let expiry = credential.expiresAt.map { $0.timeIntervalSince1970 * 1_000 }
                guard expiry.map({ $0.isFinite && $0 > 0 && $0 <= 9_007_199_254_740_991 }) ?? true else { throw CredentialError.invalidScope }
                return RelayCredentialSnapshot(digest: credential.digest, scopes: scopes, expiresAt: expiry.map(Int64.init))
            }.sorted { $0.digest < $1.digest }
            guard try JSONEncoder().encode(snapshot).count <= 120 * 1024 else { throw CredentialError.invalidScope }
            return snapshot
        }
    }

    public func revoke(_ id: String) throws {
        try transaction(write: true) { credentials in
            guard let index = credentials.firstIndex(where: { $0.id == id }) else { throw CredentialError.unauthorized }
            credentials[index].revoked = true
        }
    }

    private static func valid(_ credential: Credential, now: Date) -> Bool {
        !credential.revoked && (credential.expiresAt.map { $0 > now } ?? true)
    }
    private static func digest(_ secret: String) -> String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func transaction<T>(write: Bool = false, _ operation: (inout [Credential]) throws -> T) throws -> T {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw CredentialError.storageFailure(errno) }
        defer { close(dir) }
        try Self.check(dir, directory: true)
        let lock = openat(dir, "credentials.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CredentialError.storageFailure(errno) }
        defer { close(lock) }
        try Self.check(lock)
        while flock(lock, LOCK_EX) != 0 { if errno != EINTR { throw CredentialError.storageFailure(errno) } }
        defer { flock(lock, LOCK_UN) }
        var credentials: [Credential] = []
        let input = openat(dir, "credentials.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if input >= 0 {
            defer { close(input) }
            try Self.check(input)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(input, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw CredentialError.storageFailure(errno) }
                data.append(contentsOf: buffer.prefix(count))
            }
            credentials = try JSONDecoder().decode([Credential].self, from: data)
        } else if errno != ENOENT { throw CredentialError.storageFailure(errno) }
        let result = try operation(&credentials)
        if write {
            let temporary = "credentials-\(UUID().uuidString).tmp"
            let output = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw CredentialError.storageFailure(errno) }
            defer { close(output); unlinkat(dir, temporary, 0) }
            let data = try JSONEncoder().encode(credentials)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw CredentialError.storageFailure(errno) }
                    guard count > 0 else { throw CredentialError.storageFailure(EIO) }
                    offset += count
                }
            }
            guard fsync(output) == 0, renameat(dir, temporary, dir, "credentials.json") == 0, fsync(dir) == 0 else { throw CredentialError.storageFailure(errno) }
        }
        return result
    }
    private static func check(_ fd: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CredentialError.storageFailure(errno) }
        guard info.st_uid == geteuid(), info.st_mode & 0o777 == (directory ? 0o700 : 0o600), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw CredentialError.unsafeStorage }
    }
}
