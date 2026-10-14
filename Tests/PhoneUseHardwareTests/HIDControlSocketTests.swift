import Darwin
import Testing
@testable import PhoneUseHardware

@Test func controlSocketAnswersSetupAndSurvivesOwnerDescriptorClosing() throws {
    var sockets: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer {
        if sockets[0] >= 0 { close(sockets[0]) }
        close(sockets[1])
    }
    let control = try HIDControlSocket(fd: sockets[0])
    defer { control.stop() }
    close(sockets[0])
    sockets[0] = -1
    var request: UInt8 = 0x71
    #expect(write(sockets[1], &request, 1) == 1)
    var ready = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
    #expect(poll(&ready, 1, 1000) == 1)
    var reply: UInt8 = 0xFF
    #expect(recv(sockets[1], &reply, 1, MSG_DONTWAIT) == 1)
    #expect(reply == 0)
}

@Test func closedHIDSocketThrowsInsteadOfRaisingSIGPIPE() throws {
    var sockets: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { close(sockets[0]) }
    close(sockets[1])
    #expect(throws: (any Error).self) { try HIDSocket.write([0], to: sockets[0]) }
}
