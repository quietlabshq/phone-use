import Foundation
import Darwin
import Testing
@testable import PhoneUseRemote

@Test func serveRelayRejectsInvalidCredentialSnapshotBeforeListening() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentialDirectory = root.appendingPathComponent("credentials")
    let relayDirectory = root.appendingPathComponent("relay")
    _ = try CredentialStore(directory: credentialDirectory).create(phoneIDs: [String(repeating: "x", count: 129)])
    let config = try RelayConfiguration(origin: URL(string: "https://relay.example")!, macID: "mac", daemonSecret: "daemon-secret")
    try RelayConfigStore(directory: relayDirectory).save(config)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/phone-use")
    let process = Process()
    process.executableURL = executable
    process.arguments = ["serve", "--relay", "--simulator", "--port", "0", "--credentials-directory", credentialDirectory.path, "--relay-config-directory", relayDirectory.path]
    let output = Pipe()
    process.standardError = output
    process.standardOutput = Pipe()
    try process.run()
    for _ in 0..<200 {
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let stillRunning = process.isRunning
    if stillRunning { process.terminate() }
    process.waitUntilExit()
    let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(!stillRunning)
    #expect(process.terminationStatus != 0)
    #expect(message.contains("Local credential metadata exceeds relay limits"))
    #expect(!message.contains("Listening on"))
}

@Test func relayPairRestoresTerminalEchoAfterSIGTERM() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = root.appendingPathComponent("check-echo.sh")
    let transcript = root.appendingPathComponent("terminal.log")
    try Data("""
        #!/bin/sh
        echo BEFORE:$(stty -g </dev/tty)
        echo SHELL:$$
        "$1" relay pair --origin https://relay.example --mac-id test-mac </dev/tty
        echo AFTER:$(stty -g </dev/tty)
        """.utf8).write(to: shell)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/phone-use")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    process.arguments = ["-q", "-F", transcript.path, "/bin/sh", shell.path, executable.path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    var child: pid_t?
    for _ in 0..<300 {
        let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        if text.contains("Pairing token: "), let range = text.range(of: #"SHELL:([0-9]+)"#, options: .regularExpression),
           let shellPID = Int32(text[range].dropFirst("SHELL:".count)) {
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            children.arguments = ["-P", String(shellPID)]
            let output = Pipe()
            children.standardOutput = output
            children.standardError = Pipe()
            try children.run()
            children.waitUntilExit()
            child = Int32(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            if child != nil { break }
        }
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if let child {
        try input.fileHandleForWriting.write(contentsOf: Data("partial-canary".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        _ = kill(child, SIGTERM)
    }
    for _ in 0..<300 {
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
    let before = lines.first { $0.hasPrefix("BEFORE:") }?.dropFirst("BEFORE:".count)
    let after = lines.first { $0.contains("AFTER:") }?.split(separator: ":", maxSplits: 1).last
    #expect(child != nil)
    #expect(before != nil)
    #expect(after != nil)
    let originalFlags = before.flatMap { $0.split(separator: ":").dropFirst(3).first }.flatMap { UInt64($0, radix: 16) }
    let restoredFlags = after.flatMap { $0.split(separator: ":").dropFirst(3).first }.flatMap { UInt64($0, radix: 16) }
    #expect(originalFlags != nil)
    #expect(restoredFlags != nil)
    #expect(restoredFlags.map { $0 & UInt64(ECHO) } == originalFlags.map { $0 & UInt64(ECHO) })
    #expect(!text.contains("partial-canary"))
}
