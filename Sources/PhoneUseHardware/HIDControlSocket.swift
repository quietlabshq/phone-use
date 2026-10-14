import Darwin
import Foundation
import PhoneUseCore
import PhoneUseHID

/// Owns a duplicate of the control socket so cancellation cannot read a reused FD.
final class HIDControlSocket: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let fd: Int32
    private let lock = NSLock()
    private var session = HIDControlSession()

    init(fd: Int32) throws {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw PhoneError.commandFailed("Cannot retain HID control socket: \(errno)") }
        self.fd = copy
        source = DispatchSource.makeReadSource(fileDescriptor: copy, queue: DispatchQueue(label: "phone-use.hid-control"))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(copy) }
        source.resume()
    }

    func didSend(_ report: HIDReport) {
        lock.lock()
        session.didSend(report)
        lock.unlock()
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
        guard count > 0 else {
            if count == 0 || (errno != EAGAIN && errno != EINTR) { stop() }
            return
        }
        let packet = Array(buffer.prefix(count))
        lock.lock()
        let reply = session.reply(to: packet)
        lock.unlock()
        Self.log("control received \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
        guard let reply else { return }
        do {
            try HIDSocket.write(reply, to: fd)
            Self.log("control replied \(reply.map { String(format: "%02x", $0) }.joined(separator: " "))")
        } catch {
            Self.log("control reply failed: \(error)")
            stop()
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("phone-use hid: \(message)\n".utf8))
    }
}
