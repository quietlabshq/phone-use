import Darwin
import Foundation

public enum RelayConfigurationError: Error, Sendable {
    case invalidOrigin, invalidMacID, invalidSecret, unsafeStorage, storageFailure(Int32)
}

public struct RelayConfiguration: Codable, Sendable, Equatable {
    public let origin: URL
    public let macID: String
    public let daemonSecret: String
    public let allowInsecureLoopback: Bool

    public init(origin: URL, macID: String, daemonSecret: String, allowInsecureLoopback: Bool = false) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (allowInsecureLoopback && scheme == "http" && ["127.0.0.1", "::1", "localhost"].contains(host)) else {
            throw RelayConfigurationError.invalidOrigin
        }
        let mac = Array(macID.utf8)
        guard (1...64).contains(mac.count), mac.first.map({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) == true,
              mac.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RelayConfigurationError.invalidMacID
        }
        guard (1...256).contains(daemonSecret.utf8.count), daemonSecret.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RelayConfigurationError.invalidSecret
        }
        var normalized = parts
        normalized.scheme = scheme
        normalized.host = host
        if (scheme == "https" && normalized.port == 443) || (scheme == "http" && normalized.port == 80) {
            normalized.port = nil
        }
        guard let canonicalOrigin = normalized.url else { throw RelayConfigurationError.invalidOrigin }
        self.origin = canonicalOrigin
        self.macID = macID
        self.daemonSecret = daemonSecret
        self.allowInsecureLoopback = allowInsecureLoopback
    }

    private enum CodingKeys: String, CodingKey { case origin, macID, daemonSecret, allowInsecureLoopback }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(origin: values.decode(URL.self, forKey: .origin), macID: values.decode(String.self, forKey: .macID), daemonSecret: values.decode(String.self, forKey: .daemonSecret), allowInsecureLoopback: values.decode(Bool.self, forKey: .allowInsecureLoopback))
    }

    public var publicAuthority: String {
        let host = origin.host!.contains(":") ? "[\(origin.host!)]" : origin.host!
        let standardPort = origin.scheme == "https" ? 443 : 80
        return host + (origin.port.flatMap { $0 == standardPort ? nil : ":\($0)" } ?? "")
    }
    public var pairURL: URL { origin.appending(path: "daemon/\(macID)/pair") }
    public var connectURL: URL {
        var parts = URLComponents(url: origin.appending(path: "daemon/\(macID)/connect"), resolvingAgainstBaseURL: false)!
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        return parts.url!
    }
}

/// A private directory and one atomic, private config file. All opens refuse symlinks.
public final class RelayConfigStore: Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try withDirectory { _ in () }
    }
    public func load() throws -> RelayConfiguration? {
        try withDirectory { dir in
            let fd = openat(dir, "relay.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { if errno == ENOENT { return nil }; throw RelayConfigurationError.storageFailure(errno) }
            defer { close(fd) }
            try Self.check(fd)
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw RelayConfigurationError.storageFailure(errno) }
                guard bytes.count + count <= 4096 else { throw RelayConfigurationError.unsafeStorage }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return try JSONDecoder().decode(RelayConfiguration.self, from: bytes)
        }
    }
    public func save(_ config: RelayConfiguration) throws {
        try withDirectory { dir in
            let data = try JSONEncoder().encode(config)
            let temporary = "relay-\(UUID().uuidString).tmp"
            let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RelayConfigurationError.storageFailure(errno) }
            defer { close(fd); unlinkat(dir, temporary, 0) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw RelayConfigurationError.storageFailure(errno) }
                    guard count > 0 else { throw RelayConfigurationError.storageFailure(EIO) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw RelayConfigurationError.storageFailure(errno) }
            let existing = openat(dir, "relay.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 { defer { close(existing) }; try Self.check(existing) }
            else if errno != ENOENT { throw RelayConfigurationError.storageFailure(errno) }
            guard renameat(dir, temporary, dir, "relay.json") == 0, fsync(dir) == 0 else { throw RelayConfigurationError.storageFailure(errno) }
        }
    }
    public func remove() throws {
        try withDirectory { dir in
            let fd = openat(dir, "relay.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { if errno == ENOENT { return }; throw RelayConfigurationError.storageFailure(errno) }
            defer { close(fd) }
            try Self.check(fd)
            guard unlinkat(dir, "relay.json", 0) == 0, fsync(dir) == 0 else { throw RelayConfigurationError.storageFailure(errno) }
        }
    }
    private func withDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RelayConfigurationError.storageFailure(errno) }
        defer { close(fd) }
        try Self.check(fd, directory: true)
        return try operation(fd)
    }
    private static func check(_ fd: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RelayConfigurationError.storageFailure(errno) }
        guard info.st_uid == geteuid(), info.st_mode & 0o777 == (directory ? 0o700 : 0o600), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw RelayConfigurationError.unsafeStorage }
    }
}
