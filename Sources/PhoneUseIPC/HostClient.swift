import Darwin
import Foundation
import MCP

public enum HostClientError: Error, CustomStringConvertible, Sendable {
    case appNotFound
    case appDidNotStart(String, String)

    public var description: String {
        switch self {
        case .appNotFound:
            "Phone Use.app is not running and could not be found. Install it in /Applications or set PHONE_USE_APP to its path, then retry."
        case let .appDidNotStart(path, detail):
            "Phone Use.app at \(path) did not start serving phones: \(detail). Open it to see its status."
        }
    }
}

/// Connects command-line clients to the app, launching it when it is not running.
public enum HostClient {
    public static let bundleIdentifier = "com.quietlabs.phone-use"

    /// Returns a connected socket descriptor. The caller owns and must close it.
    public static func connect(socket: URL = HostPaths.socket, launch: Bool = true, timeout: Duration = .seconds(10)) async throws -> Int32 {
        if let fd = try? UnixSocket.connect(path: socket.path) { return fd }
        guard launch else { return try UnixSocket.connect(path: socket.path) }
        guard let app = locateApp() else { throw HostClientError.appNotFound }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", app.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw HostClientError.appDidNotStart(app.path, "open exited \(open.terminationStatus)") }
        let deadline = ContinuousClock.now + timeout
        var lastError: any Error = SocketError("connect", ENOENT)
        while ContinuousClock.now < deadline {
            do { return try UnixSocket.connect(path: socket.path) }
            catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HostClientError.appDidNotStart(app.path, String(describing: lastError))
    }

    /// The app that contains this executable, then `PHONE_USE_APP`, then the registered bundle.
    public static func locateApp() -> URL? {
        if let override = ProcessInfo.processInfo.environment["PHONE_USE_APP"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        lookup.arguments = ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = FileHandle.nullDevice
        guard (try? lookup.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .first { $0.pathExtension == "app" }
    }

    /// Copies stdin to the socket and the socket to stdout until either side ends.
    public static func relay(socket fd: Int32, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        let done = DispatchSemaphore(value: 0)
        func pump(_ from: Int32, _ to: Int32) {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(from, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0, (try? UnixSocket.writeAll(to, Data(buffer[..<count]))) != nil else { break }
                }
                done.signal()
            }
        }
        pump(input, fd)
        pump(fd, output)
        done.wait()
    }

    /// Opens an MCP client session to the app.
    public static func session(socket: URL = HostPaths.socket) async throws -> Client {
        let fd = try await connect(socket: socket)
        let client = Client(name: "phone-use-cli", version: "0.1.0")
        try await client.connect(transport: SocketTransport(descriptor: fd))
        return client
    }
}
