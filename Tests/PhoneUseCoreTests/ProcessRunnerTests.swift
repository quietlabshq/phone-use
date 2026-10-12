import Foundation
import Testing
@testable import PhoneUseCore

@Test func runsEcho() async throws {
    let result = try await LiveProcessRunner().run("/bin/echo", ["hi"])
    #expect(result.status == 0)
    #expect(result.stdout == Data("hi\n".utf8))
    #expect(result.stderr.isEmpty)
}

@Test func resolvesBareExecutable() async throws {
    let result = try await LiveProcessRunner().run("echo", ["hi"])
    #expect(result.stdout == Data("hi\n".utf8))
}

@Test func rejectsMissingExecutable() async {
    await #expect(throws: PhoneError.toolUnavailable("phone-use-nonexistent-executable")) {
        try await LiveProcessRunner().run("phone-use-nonexistent-executable", [])
    }
}

@Test(.timeLimit(.minutes(1))) func drainsOutputWhileFeedingInput() async throws {
    let input = Data(repeating: 120, count: 1_048_576)
    let result = try await LiveProcessRunner().run("/bin/sh", ["-c",
        "dd if=/dev/zero bs=1048576 count=1 2>/dev/null; (dd if=/dev/zero bs=1048576 count=1 2>/dev/null | cat >&2); cat"], stdin: input)
    #expect(result.status == 0)
    #expect(result.stdout == Data(repeating: 0, count: 1_048_576) + input)
    #expect(result.stderr == Data(repeating: 0, count: 1_048_576))
}

@Test(.timeLimit(.minutes(1))) func survivesChildClosingInput() async {
    do {
        _ = try await LiveProcessRunner().run("/usr/bin/true", [], stdin: Data(repeating: 0, count: 1_048_576))
    } catch {
        #expect(!(error is CancellationError))
    }
}

@Test(.timeLimit(.minutes(1))) func cancelsRunningProcess() async throws {
    let task = Task { try await LiveProcessRunner().run("/bin/sleep", ["30"]) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.timeLimit(.minutes(1))) func cancellationEscalatesWhenTerminationIgnored() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        try await LiveProcessRunner().run("/usr/bin/perl", ["-e",
            "$SIG{TERM}='IGNORE'; open(my $f, '>', $ARGV[0]) or die $!; close($f); sleep 3;", marker.path], stdin: Data(repeating: 0, count: 1_048_576))
    }
    while !FileManager.default.fileExists(atPath: marker.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test(.timeLimit(.minutes(1))) func collectsRapidConcurrentProcessExits() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<32 {
                    let result = try await LiveProcessRunner().run("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
                    #expect(result.status == 7)
                    #expect(result.stdout == Data("out".utf8))
                    #expect(result.stderr == Data("err".utf8))
                }
            }
        }
        try await group.waitForAll()
    }
}
