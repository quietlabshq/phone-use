import Darwin
import Foundation
import MCP
import PhoneUseCore
import PhoneUseMCP
import Testing
@testable import PhoneUseIPC

private struct HintRegistry: PhoneRegistry {
    func discover() async -> (phones: [any Phone], hints: [String]) { ([], ["socket hint"]) }
}

/// Socket paths must stay under the 104-byte `sun_path` limit, so avoid the long
/// per-user temporary directory.
private func temporarySocket() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp/pu-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try HostPaths.preparePrivateDirectory(directory)
    return directory.appendingPathComponent("app.sock")
}

private func text(_ content: [Tool.Content]) -> String {
    content.compactMap { if case let .text(text, _, _) = $0 { text } else { nil } }.joined()
}

@Test func socketSessionsServeConcurrentClients() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let listener = try HostListener(socket: socket, dispatcher: ToolDispatcher(registry: HintRegistry()))
    defer { listener.stop() }
    try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<3 {
            group.addTask {
                let client = try await HostClient.session(socket: socket)
                defer { Task { await client.disconnect() } }
                let tools = try await client.listTools().tools
                #expect(tools.count == 9)
                let result = try await client.callTool(name: "list_phones")
                #expect(result.isError != true)
                return text(result.content)
            }
        }
        for try await output in group { #expect(output.contains("socket hint")) }
    }
}

@Test func socketReportsToolErrors() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let listener = try HostListener(socket: socket, dispatcher: ToolDispatcher(registry: HintRegistry()))
    defer { listener.stop() }
    let client = try await HostClient.session(socket: socket)
    let result = try await client.callTool(name: "tap", arguments: ["x": .int(1), "y": .int(1)])
    #expect(result.isError == true)
    #expect(text(result.content).contains("No phones available"))
    await client.disconnect()
}

@Test func relayCarriesStdioMCPToTheApp() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let listener = try HostListener(socket: socket, dispatcher: ToolDispatcher(registry: HintRegistry()))
    defer { listener.stop() }
    let input = Pipe(), output = Pipe()
    let fd = try await HostClient.connect(socket: socket, launch: false)
    let relay = Thread {
        HostClient.relay(socket: fd, input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
        close(fd)
        try? output.fileHandleForWriting.close()
    }
    relay.start()
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
    input.fileHandleForWriting.write(Data((initialize + "\n").utf8))
    var received = Data()
    while !received.contains(UInt8(ascii: "\n")) {
        let chunk = output.fileHandleForReading.availableData
        guard !chunk.isEmpty else { break }
        received.append(chunk)
    }
    let response = try JSONSerialization.jsonObject(with: received.prefix { $0 != UInt8(ascii: "\n") }) as? [String: Any]
    #expect(response?["id"] as? Int == 1)
    #expect((response?["result"] as? [String: Any])?["serverInfo"] != nil)
    // Closing stdin ends the relay and the app-side session.
    try input.fileHandleForWriting.close()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    for _ in 0..<100 where listener.sessionCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(listener.sessionCount == 0)
}

@Test func stopRemovesSocketAndRefusesConnections() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let listener = try HostListener(socket: socket, dispatcher: ToolDispatcher(registry: HintRegistry()))
    #expect(FileManager.default.fileExists(atPath: socket.path))
    listener.stop()
    #expect(!FileManager.default.fileExists(atPath: socket.path))
    await #expect(throws: SocketError.self) { _ = try await HostClient.connect(socket: socket, launch: false) }
}

@Test func listenerReplacesStaleSocketFile() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    FileManager.default.createFile(atPath: socket.path, contents: Data())
    let listener = try HostListener(socket: socket, dispatcher: ToolDispatcher(registry: HintRegistry()))
    defer { listener.stop() }
    let client = try await HostClient.session(socket: socket)
    #expect(try await client.listTools().tools.count == 9)
    await client.disconnect()
}

@Test func privateDirectoryRejectsSharedPermissions() throws {
    let directory = URL(fileURLWithPath: "/tmp/pu-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: SocketError.self) { try HostPaths.preparePrivateDirectory(directory) }
}

@Test(.timeLimit(.minutes(1))) func closingUnblocksAWriteToAPeerThatStoppedReading() async throws {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { close(pair[1]) }
    var on: Int32 = 1
    setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let io = SocketIO(fd: pair[0])
    try io.start(message: { _ in }, finished: {})
    // pair[1] never reads, so this fills the socket buffer and blocks.
    let write = Task { try await io.write(Data(count: 64 << 20)) }
    try await Task.sleep(for: .milliseconds(200))
    let start = ContinuousClock.now
    io.close()
    await #expect(throws: (any Error).self) { try await write.value }
    #expect(ContinuousClock.now - start < .seconds(5))
}
