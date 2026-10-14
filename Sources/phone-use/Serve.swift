import ArgumentParser
import Darwin
import Foundation
import PhoneUseCore
import PhoneUseRemote

struct CredentialOptions: ParsableArguments {
    @Option(help: "Private credential directory.") var credentialsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/phone-use/credentials").path
    func store() throws -> CredentialStore { try CredentialStore(directory: URL(fileURLWithPath: credentialsDirectory)) }
}
struct Credentials: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage local scoped remote credentials.", subcommands: [Create.self, ListCredentials.self, Revoke.self])
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a credential and print its secret exactly once.")
        @OptionGroup var options: CredentialOptions
        @Option(name: .long, parsing: .singleValue, help: "Explicit phone ID; repeat to permit multiple phones.") var phone: [String] = []
        @Option(help: "Expiration as ISO 8601 date/time.") var expiresAt: String?
        mutating func run() throws {
            let expiry = expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            if expiresAt != nil && (expiry == nil || expiry! <= Date()) { throw ValidationError("--expires-at must be a future ISO 8601 date/time") }
            guard !phone.isEmpty else { throw ValidationError("At least one --phone is required") }
            let issued = try options.store().create(phoneIDs: Set(phone), expiresAt: expiry)
            print("Credential ID: \(issued.credential.id)\nBearer secret: \(issued.secret)")
        }
    }
    struct ListCredentials: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List credential metadata without secrets.")
        @OptionGroup var options: CredentialOptions
        mutating func run() throws {
            for credential in try options.store().list() {
                print("\(credential.id) phones=\(credential.phoneIDs.sorted().joined(separator: ",")) revoked=\(credential.revoked) expires=\(credential.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
            }
        }
    }
    struct Revoke: ParsableCommand {
        @OptionGroup var options: CredentialOptions
        @Argument var id: String
        mutating func run() throws { try options.store().revoke(id); print("Credential revoked") }
    }
}
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve authenticated MCP over bounded HTTP.")
    @OptionGroup var backend: BackendOptions
    @OptionGroup var credentials: CredentialOptions
    @Option var host = "127.0.0.1"
    @Option var port = 8765
    @Flag var allowRemote = false
    @Flag var insecureDevelopmentHTTP = false
    @Flag(help: "Connect to a previously paired outbound relay.") var relay = false
    @OptionGroup var relayOptions: RelayOptions
    @Option(parsing: .singleValue, help: "Exact additional Host authority, including port when present; repeatable.") var allowedHost: [String] = []
    @Option(parsing: .singleValue, help: "Exact allowed browser Origin; repeatable. Browsers are denied by default.") var allowedOrigin: [String] = []
    mutating func run() async throws {
        guard (0...65535).contains(port) else { throw ValidationError("Invalid port") }
        guard ["127.0.0.1", "::1", "localhost"].contains(host) || (allowRemote && insecureDevelopmentHTTP) else {
            throw ValidationError("Non-loopback HTTP requires --allow-remote --insecure-development-http; use a TLS proxy to loopback in production")
        }
        let store = try credentials.store()
        let relayConfig: RelayConfiguration?
        if relay {
            let config: RelayConfiguration?
            do { config = try relayOptions.store().load() }
            catch { throw ValidationError("Invalid or unsafe relay configuration; run phone-use relay pair again") }
            guard let config else { throw ValidationError("No relay configuration; run phone-use relay pair first") }
            do { _ = try store.relaySnapshot() }
            catch { throw ValidationError("Local credential metadata exceeds relay limits") }
            relayConfig = config
        } else { relayConfig = nil }
        let ownership = try ProcessOwnership()
        defer { withExtendedLifetime(ownership) {} }
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let service = HTTPService(credentials: store, dispatcher: backend.dispatcher(), allowedHosts: Set(allowedHost.map { $0.lowercased() } + [authority.lowercased()]), allowedOrigins: Set(allowedOrigin))
        if let relayConfig { await service.allowHost(relayConfig.publicAuthority) }
        let listener = try await HTTPListener.start(service: service, host: host, port: port)
        let connector = relayConfig.map { RelayConnector(config: $0, credentials: store, service: service) }
        if let connector { await connector.start() }
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { value in
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { signals.continuation.yield(()) }
            source.resume()
            return source
        }
        FileHandle.standardError.write(Data("Listening on \(host):\(listener.port)/mcp\n".utf8))
        for await _ in signals.stream { break }
        for source in sources { source.cancel() }
        if let connector { await connector.stop() }
        await listener.shutdown()
    }
}
