import ArgumentParser
import Darwin
import Foundation
import PhoneUseRemote

nonisolated(unsafe) private var pairingSignalWriteFD: Int32 = -1

private func pairingSignalHandler(_ signalNumber: Int32) {
    var byte = UInt8(truncatingIfNeeded: signalNumber)
    if pairingSignalWriteFD >= 0 { _ = write(pairingSignalWriteFD, &byte, 1) }
}

private func readPrivatePairingToken() throws -> String {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw ValidationError("Cannot read terminal") }
    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else { throw ValidationError("Cannot prepare terminal input") }
    guard fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0,
          fcntl(pipeFDs[1], F_SETFL, O_NONBLOCK) == 0 else {
        close(pipeFDs[0]); close(pipeFDs[1])
        throw ValidationError("Cannot prepare terminal input")
    }
    pairingSignalWriteFD = pipeFDs[1]
    let watchedSignals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU]
    var oldActions = [Darwin.sigaction](repeating: Darwin.sigaction(), count: watchedSignals.count)
    var installed = 0
    var complete = false
    defer {
        if !complete { _ = tcflush(STDIN_FILENO, TCIFLUSH) }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        FileHandle.standardError.write(Data("\n".utf8))
        for index in 0..<installed { _ = sigaction(watchedSignals[index], &oldActions[index], nil) }
        pairingSignalWriteFD = -1
        close(pipeFDs[0]); close(pipeFDs[1])
    }
    var action = Darwin.sigaction()
    action.__sigaction_u.__sa_handler = pairingSignalHandler
    sigemptyset(&action.sa_mask)
    action.sa_flags = 0
    for index in watchedSignals.indices {
        guard sigaction(watchedSignals[index], &action, &oldActions[index]) == 0 else { throw ValidationError("Cannot protect terminal input") }
        installed += 1
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO | ICANON)
    withUnsafeMutableBytes(of: &hidden.c_cc) { control in
        control[Int(VMIN)] = 0
        control[Int(VTIME)] = 1
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else { throw ValidationError("Cannot hide terminal input") }
    FileHandle.standardError.write(Data("Pairing token: ".utf8))
    var bytes: [UInt8] = []
    defer { bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
    while true {
        var interrupted: UInt8 = 0
        if read(pipeFDs[0], &interrupted, 1) > 0 { throw ValidationError("Pairing interrupted") }
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        if count < 0 { if errno == EINTR { continue }; throw ValidationError("Cannot read pairing token") }
        if count == 0 { continue }
        if byte == 10 || byte == 13 { break }
        if byte == 127 || byte == 8 { if !bytes.isEmpty { bytes[bytes.count - 1] = 0; bytes.removeLast() }; continue }
        if byte == 21 { bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }; bytes.removeAll(keepingCapacity: true); continue }
        guard bytes.count < 256 else { throw ValidationError("Pairing token is too long") }
        bytes.append(byte)
    }
    complete = true
    return String(decoding: bytes, as: UTF8.self)
}

struct RelayOptions: ParsableArguments {
    @Option(help: "Private relay config directory.") var relayConfigDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/phone-use/relay").path
    func store() throws -> RelayConfigStore { try RelayConfigStore(directory: URL(fileURLWithPath: relayConfigDirectory)) }
}

struct Relay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage optional outbound relay pairing.", subcommands: [Pair.self, Status.self, Remove.self])

    struct Pair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pair with a user-owned relay using a token read from standard input.")
        @OptionGroup var options: RelayOptions
        @Option(help: "Relay HTTPS origin, without a path or secret.") var origin: String
        @Option(help: "Stable Mac identifier on the relay.") var macID: String
        @Flag(help: "Permit plain HTTP only to a loopback test relay.") var allowInsecureLoopback = false
        mutating func run() async throws {
            guard let url = URL(string: origin) else { throw ValidationError("Invalid relay origin") }
            // Check the endpoint before asking for a one-use secret.
            _ = try RelayConfiguration(origin: url, macID: macID, daemonSecret: "placeholder", allowInsecureLoopback: allowInsecureLoopback)
            if isatty(STDIN_FILENO) != 0 {
                try await performPair(url: url, token: readPrivatePairingToken())
            } else {
                try await performPair(url: url, token: readLine())
            }
        }
        private func performPair(url: URL, token: String?) async throws {
            guard let token, !token.isEmpty else { throw ValidationError("A pairing token is required on standard input") }
            let config = try await RelayPairing.pair(origin: url, macID: macID, token: token, allowInsecureLoopback: allowInsecureLoopback)
            try options.store().save(config)
            print("Relay paired for \(config.macID) at \(config.origin.absoluteString). Run phone-use serve --relay to connect.")
        }
    }
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show local relay configuration without its secret.")
        @OptionGroup var options: RelayOptions
        mutating func run() throws {
            guard let config = try options.store().load() else { print("Relay is not configured"); return }
            print("Relay configured for \(config.macID) at \(config.origin.absoluteString)")
        }
    }
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the local daemon credential and relay configuration.")
        @OptionGroup var options: RelayOptions
        mutating func run() throws { try options.store().remove(); print("Local relay configuration removed") }
    }
}
