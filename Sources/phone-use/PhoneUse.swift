import ArgumentParser
import PhoneUseMCP
import PhoneUseCore

@main
struct PhoneUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "phone-use", abstract: "Control iPhone simulators and configured physical iPhones.", version: "0.1.0", subcommands: [MCPCommand.self, Serve.self, Credentials.self, Relay.self, List.self, Screenshot.self, Tap.self, LongPress.self, Swipe.self, TypeText.self, PressKey.self, Home.self, OpenApp.self, Calibrate.self, Doctor.self])
}
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve MCP over standard input/output.")
    @OptionGroup var backend: BackendOptions
    mutating func run() async throws {
        let ownership = try ProcessOwnership()
        defer { withExtendedLifetime(ownership) {} }
        try await MCPServer.run(dispatcher: Runtime.dispatcher(backend))
    }
}
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List phone IDs and discovery hints.")
    @OptionGroup var backend: BackendOptions
    mutating func run() async throws {
        let ownership = try ProcessOwnership()
        defer { withExtendedLifetime(ownership) {} }
        switch await Runtime.dispatcher(backend).call("list_phones", [:]) {
        case let .text(message): print(message)
        case let .error(message): throw ValidationError(message)
        case .jpeg: throw ValidationError("Unexpected image from list")
        }
    }
}
