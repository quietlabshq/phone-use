import Darwin
import Foundation
import Logging
import MCP

/// Newline-delimited MCP JSON-RPC over a connected stream socket. The transport owns
/// the descriptor and closes it only after the last write has finished, so a late
/// response can never reach a descriptor number reused by another connection.
public actor SocketTransport: Transport {
    public nonisolated let logger = Logger(label: "phone-use.socket", factory: { _ in SwiftLogNoOpLogHandler() })
    private nonisolated let io: SocketIO
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    public init(descriptor: Int32) {
        (messages, continuation) = AsyncThrowingStream.makeStream()
        io = SocketIO(fd: descriptor)
    }

    public func connect() async throws {
        let continuation = continuation
        try io.start { message in continuation.yield(message) } finished: { continuation.finish() }
    }
    public func disconnect() async { io.close() }
    public func send(_ data: Data) async throws {
        var line = data
        line.append(UInt8(ascii: "\n"))
        try await io.write(line)
    }
    public func receive() -> AsyncThrowingStream<Data, any Error> { messages }
}

final class SocketIO: @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "phone-use.socket.read")
    private let writeQueue = DispatchQueue(label: "phone-use.socket.write")
    private var source: (any DispatchSourceRead)?
    private var closed = false // Guarded by writeQueue.
    private let descriptorLock = NSLock()
    private var descriptorClosed = false // Guarded by descriptorLock.
    private var pending = Data() // Guarded by readQueue.

    init(fd: Int32) { self.fd = fd }

    func start(message: @escaping @Sendable (Data) -> Void, finished: @escaping @Sendable () -> Void) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw SocketError("configure socket") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    pending.append(contentsOf: buffer[..<count])
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = pending[pending.startIndex..<newline]
                        pending = Data(pending[pending.index(after: newline)...])
                        if !line.isEmpty { message(Data(line)) }
                    }
                } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    return
                } else {
                    finished()
                    close()
                    return
                }
            }
        }
        source.setCancelHandler { [self] in
            // Close after any queued write has finished.
            writeQueue.async { self.closeDescriptor() }
        }
        writeQueue.sync { self.source = source }
        source.resume()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [self] in
                guard !closed else { continuation.resume(throwing: SocketError("write to closed socket", ENOTCONN)); return }
                do { try UnixSocket.writeAll(fd, data); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() {
        // Wake a write blocked on a peer that stopped reading; the descriptor itself is
        // closed on writeQueue, after that write gives up.
        descriptorLock.withLock { if !descriptorClosed { _ = Darwin.shutdown(fd, SHUT_RDWR) } }
        writeQueue.async { [self] in
            guard !closed else { return }
            closed = true
            if let source { source.cancel() } else { closeDescriptor() }
        }
    }

    private func closeDescriptor() {
        descriptorLock.withLock {
            guard !descriptorClosed else { return }
            descriptorClosed = true
            Darwin.close(fd)
        }
    }
}
