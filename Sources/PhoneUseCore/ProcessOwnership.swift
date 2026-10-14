import Foundation

import Darwin

/// Conservatively serializes all local phone access for a user. Keep this object alive
/// for the entire operation, including backend discovery and asynchronous cleanup.
public final class ProcessOwnership: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/phone-use/ownership", isDirectory: true)
    }

    private let descriptor: Int32
    private let ownerPID: pid_t

    public init(directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parentFD = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw OwnershipError.system("open ownership parent", errno) }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0 else { throw OwnershipError.system("inspect ownership parent", errno) }
        guard parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o022 == 0 else {
            throw OwnershipError.unsafePath("Ownership parent must belong to the current user and must not be writable by other users")
        }
        if mkdirat(parentFD, directory.lastPathComponent, 0o700) != 0 && errno != EEXIST {
            throw OwnershipError.system("create ownership directory", errno)
        }
        let directoryFD = openat(parentFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw OwnershipError.system("open ownership directory", errno) }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0 else { throw OwnershipError.system("inspect ownership directory", errno) }
        guard directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw OwnershipError.unsafePath("Ownership directory must belong to the current user and have mode 0700: \(directory.path)")
        }
        let fd = openat(directoryFD, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OwnershipError.system("open ownership lock", errno) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw OwnershipError.system("inspect ownership lock", errno) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
                throw OwnershipError.unsafePath("Ownership lock must be a private regular file owned by the current user")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw OwnershipError.conflict }
                throw OwnershipError.system("acquire ownership lock", errno)
            }
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
        ownerPID = getpid()
    }

    // Never unlink the file: every contender must lock the same inode.
    deinit {
        // A pre-exec child may still hold this open file description.
        if getpid() == ownerPID { flock(descriptor, LOCK_UN) }
        close(descriptor)
    }
}

public enum OwnershipError: Error, CustomStringConvertible, Sendable {
    case conflict
    case unsafePath(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .conflict:
            "Another phone-use process owns local phone access. Use the daemon endpoint or stop the owning process before retrying."
        case let .unsafePath(message): message
        case let .system(operation, code): "Could not \(operation): \(String(cString: strerror(code)))"
        }
    }
}
