import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32
    public init(_ operation: String, _ code: Int32 = errno) { self.operation = operation; self.code = code }
    public var description: String { "Could not \(operation): \(String(cString: strerror(code)))" }
}

/// Paths shared by the app (server) and the CLI (client).
public enum HostPaths {
    public static var runDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/phone-use/run", isDirectory: true)
    }
    public static var socket: URL { runDirectory.appendingPathComponent("app.sock") }

    /// Creates the private run directory and refuses one another user could write to.
    public static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw SocketError("inspect \(directory.path)") }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw SocketError("use \(directory.path): it must be a private directory owned by the current user (mode 0700)", EPERM)
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError("use socket path \(path): too long", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("create socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Binds a listening socket, replacing a stale socket file. Callers must already
    /// hold process ownership so no live server can own the path.
    static func listen(path: String) throws -> Int32 {
        var address = try address(path)
        unlink(path)
        let fd = try make()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw SocketError("bind \(path)", code) }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else { let code = errno; close(fd); throw SocketError("listen on \(path)", code) }
        return fd
    }

    static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try make()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { let code = errno; close(fd); throw SocketError("connect to \(path)", code) }
        return fd
    }

    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    /// Writes all bytes, waiting on `poll` while a nonblocking socket is full.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written; remaining -= written
                } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 1000)
                } else {
                    throw SocketError("write to socket")
                }
            }
        }
    }
}
