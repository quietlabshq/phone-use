import Foundation
import Testing
@testable import PhoneUseCore

import Darwin

@Test func ownershipRejectsContentionAndPreservesInode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("ownership", isDirectory: true)
    var owner: ProcessOwnership? = try ProcessOwnership(directory: directory)
    let path = directory.appendingPathComponent("owner.lock").path
    let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
    do {
        _ = try ProcessOwnership(directory: directory)
        Issue.record("Concurrent ownership unexpectedly succeeded")
    } catch {
        #expect(String(describing: error).contains("daemon endpoint"))
    }
    withExtendedLifetime(owner) {}
    owner = nil
    let replacement = try ProcessOwnership(directory: directory)
    #expect(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber == inode)
    withExtendedLifetime(replacement) {}
}

@Test func ownershipRejectsUnsafePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("ownership", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
    #expect(throws: (any Error).self) { try ProcessOwnership(directory: directory) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("owner.lock").path, withDestinationPath: "/dev/null")
    #expect(throws: (any Error).self) { try ProcessOwnership(directory: directory) }
}

@Test(.timeLimit(.minutes(1))) func ownershipCrashReleaseAndChildExec() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PhoneUseCore/ProcessOwnership.swift")
    let helper = root.appendingPathComponent("main.swift")
    try """
    import Foundation
    import Darwin
    let owner = try ProcessOwnership(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
    var child: pid_t = 0
    let arguments = [strdup("sleep"), strdup("20"), nil]
    let status = arguments.withUnsafeBufferPointer { buffer in
        posix_spawn(&child, "/bin/sleep", nil, nil, buffer.baseAddress!, environ)
    }
    guard status == 0 else { exit(1) }
    print(child)
    fflush(stdout)
    withExtendedLifetime(owner) { while true { sleep(1) } }
    """.write(to: helper, atomically: true, encoding: .utf8)
    let executable = root.appendingPathComponent("owner")
    let compile = try await LiveProcessRunner().run("/usr/bin/swiftc", [source.path, helper.path, "-o", executable.path])
    #expect(compile.status == 0, "\(String(decoding: compile.stderr, as: UTF8.self))")
    guard compile.status == 0 else { return }
    let output = Pipe()
    let process = Process()
    process.executableURL = executable
    let lockDirectory = root.appendingPathComponent("ownership")
    process.arguments = [lockDirectory.path]
    process.standardOutput = output
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    let data = output.fileHandleForReading.availableData
    let child = try #require(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(child, SIGKILL) }
    #expect(throws: (any Error).self) { try ProcessOwnership(directory: lockDirectory) }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    #expect(kill(child, 0) == 0)
    let replacement = try ProcessOwnership(directory: lockDirectory)
    withExtendedLifetime(replacement) {}
}

@Test(.timeLimit(.minutes(1))) func ownershipReleaseDoesNotWaitForInheritedDescriptor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PhoneUseCore/ProcessOwnership.swift")
    let forkSource = root.appendingPathComponent("inherited.c")
    try """
    #include <unistd.h>
    #include <sys/types.h>
    pid_t hold_inherited_descriptors(void) {
        pid_t child = fork();
        if (child == 0) {
            for (;;) pause();
        }
        return child;
    }
    """.write(to: forkSource, atomically: true, encoding: .utf8)
    let forkObject = root.appendingPathComponent("inherited.o")
    let compileC = try await LiveProcessRunner().run("/usr/bin/clang", ["-c", forkSource.path, "-o", forkObject.path])
    #expect(compileC.status == 0, "\(String(decoding: compileC.stderr, as: UTF8.self))")
    guard compileC.status == 0 else { return }
    let helper = root.appendingPathComponent("main.swift")
    try """
    import Foundation
    import Darwin
    @_silgen_name("hold_inherited_descriptors") func holdInheritedDescriptors() -> pid_t
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    var owner: ProcessOwnership? = try ProcessOwnership(directory: directory)
    let child = holdInheritedDescriptors()
    guard child > 0 else { exit(2) }
    defer { kill(child, SIGKILL); waitpid(child, nil, 0) }
    withExtendedLifetime(owner) {}
    owner = nil
    do {
        let replacement = try ProcessOwnership(directory: directory)
        guard kill(child, 0) == 0 else { exit(3) }
        withExtendedLifetime(replacement) {}
    } catch {
        print(error)
        kill(child, SIGKILL)
        waitpid(child, nil, 0)
        exit(1)
    }
    """.write(to: helper, atomically: true, encoding: .utf8)
    let executable = root.appendingPathComponent("owner")
    let compileSwift = try await LiveProcessRunner().run("/usr/bin/swiftc", [source.path, helper.path, forkObject.path, "-o", executable.path])
    #expect(compileSwift.status == 0, "\(String(decoding: compileSwift.stderr, as: UTF8.self))")
    guard compileSwift.status == 0 else { return }
    let result = try await LiveProcessRunner().run(executable.path, [root.appendingPathComponent("ownership").path])
    #expect(result.status == 0, "\(String(decoding: result.stdout + result.stderr, as: UTF8.self))")
}
