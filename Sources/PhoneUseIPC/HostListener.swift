import Darwin
import Foundation
import MCP
import PhoneUseMCP

/// Serves one MCP session per accepted connection on the app's private socket.
public final class HostListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let source: any DispatchSourceRead
    private let lock = NSLock()
    private var sessions: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public var sessionCount: Int { lock.withLock { sessions.count } }

    /// - Parameter session: Runs one connection to completion; the transport is
    ///   disconnected afterwards.
    public init(socket: URL, session: @escaping @Sendable (SocketTransport) async -> Void) throws {
        try HostPaths.preparePrivateDirectory(socket.deletingLastPathComponent())
        path = socket.path
        fd = try UnixSocket.listen(path: path)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "phone-use.host.accept"))
        source.setEventHandler { [weak self] in self?.acceptPending(session) }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
    }

    /// Serves MCP for `dispatcher` on each connection.
    public convenience init(socket: URL, dispatcher: ToolDispatcher) throws {
        try self.init(socket: socket) { transport in
            try? await MCPServer.serve(transport: transport, dispatcher: dispatcher)
        }
    }

    private func acceptPending(_ session: @escaping @Sendable (SocketTransport) async -> Void) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                // Out of descriptors: the connection stays queued, so pause instead of spinning.
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard UnixSocket.peerIsCurrentUser(client) else { close(client); continue }
            let transport = SocketTransport(descriptor: client)
            let id = UUID()
            lock.withLock {
                guard !stopped else { close(client); return }
                sessions[id] = Task { [weak self] in
                    await session(transport)
                    await transport.disconnect()
                    self?.finish(id)
                }
            }
        }
    }

    private func finish(_ id: UUID) { lock.withLock { _ = sessions.removeValue(forKey: id) } }

    /// Stops accepting, cancels live sessions, and removes the socket file.
    public func stop() {
        let running: [Task<Void, Never>] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        source.cancel()
        unlink(path)
        for task in running { task.cancel() }
    }

    deinit { stop() }
}
