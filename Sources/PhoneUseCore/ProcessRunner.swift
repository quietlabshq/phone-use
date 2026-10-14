import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ args: [String], stdin: Data?) async throws -> ProcessResult
}

extension ProcessRunner {
    public func run(_ executable: String, _ args: [String]) async throws -> ProcessResult {
        try await run(executable, args, stdin: nil)
    }
}

public struct LiveProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ args: [String], stdin: Data? = nil) async throws -> ProcessResult {
        let lifetime = ProcessLifetime()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            let input = Pipe()
            #if canImport(Darwin)
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw PhoneError.commandFailed("Could not configure process input pipe")
            }
            #endif
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input
            process.arguments = args
            try await blocking {
                process.executableURL = try resolveExecutable(executable)
                try lifetime.start(process)
            }
            async let stdout = blocking { try output.fileHandleForReading.readToEnd() ?? Data() }
            async let stderr = blocking { try errors.fileHandleForReading.readToEnd() ?? Data() }
            async let feed: Void = blocking {
                defer { try? input.fileHandleForWriting.close() }
                if let stdin { try writeWithoutSIGPIPE(stdin, to: input.fileHandleForWriting) }
            }
            async let status = lifetime.waitForExit()
            do {
                let result = try await ProcessResult(status: status, stdout: stdout, stderr: stderr)
                try await feed
                try Task.checkCancellation()
                return result
            } catch {
                lifetime.cancel()
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            lifetime.cancel()
        }
    }
}

private func writeWithoutSIGPIPE(_ data: Data, to handle: FileHandle) throws {
    #if os(Linux)
    var blockedSignals = sigset_t()
    guard sigemptyset(&blockedSignals) == 0, sigaddset(&blockedSignals, SIGPIPE) == 0 else {
        throw PhoneError.commandFailed("Could not prepare process input pipe")
    }
    var originalSignals = sigset_t()
    guard pthread_sigmask(SIG_BLOCK, &blockedSignals, &originalSignals) == 0 else {
        throw PhoneError.commandFailed("Could not protect process input pipe")
    }
    var pendingBeforeWrite = sigset_t()
    _ = sigpending(&pendingBeforeWrite)
    let alreadyPending = sigismember(&pendingBeforeWrite, SIGPIPE) == 1
    let wasBlocked = sigismember(&originalSignals, SIGPIPE) == 1
    defer {
        if !wasBlocked && !alreadyPending {
            var timeout = timespec()
            _ = sigtimedwait(&blockedSignals, nil, &timeout)
        }
        _ = pthread_sigmask(SIG_SETMASK, &originalSignals, nil)
    }
    #endif
    try handle.write(contentsOf: data)
}

private func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try operation() })
        }
    }
}

private final class ProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var status: Int32?
    private var exitContinuation: CheckedContinuation<Int32, Never>?

    func start(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process.terminationHandler = { [self] process in
                finish(status: process.terminationStatus)
            }
            try process.run()
            self.process = process
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus = lock.withLock { () -> Int32? in
                if let status { return status }
                exitContinuation = continuation
                return nil
            }
            if let completedStatus { continuation.resume(returning: completedStatus) }
        }
    }

    private func finish(status: Int32) {
        let continuation = lock.withLock {
            self.status = status
            process = nil
            let continuation = exitContinuation
            exitContinuation = nil
            return continuation
        }
        continuation?.resume(returning: status)
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                lock.withLock {
                    guard let process = self.process, process.isRunning else { return }
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}

/// Resolves a bare command through `PATH`; paths containing `/` are used as given.
public func resolveExecutable(_ executable: String) throws -> URL {
    let path: String
    if executable.contains("/") {
        path = executable
    } else {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard let match = paths.map({ URL(fileURLWithPath: $0.isEmpty ? "." : String($0))
            .appendingPathComponent(executable).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PhoneError.toolUnavailable(executable)
        }
        path = match
    }
    guard FileManager.default.isExecutableFile(atPath: path) else { throw PhoneError.toolUnavailable(executable) }
    return URL(fileURLWithPath: path)
}
