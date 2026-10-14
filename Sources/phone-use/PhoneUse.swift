import ArgumentParser
import Foundation
import PhoneUseIPC

@main
struct PhoneUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "phone-use", abstract: "Control iPhone simulators and configured physical iPhones.", version: "0.1.0", subcommands: [MCPCommand.self, Serve.self, Credentials.self, Relay.self, List.self, Screenshot.self, Tap.self, LongPress.self, Swipe.self, TypeText.self, PressKey.self, Home.self, OpenApp.self, Calibrate.self, Doctor.self])
}
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve MCP over standard input/output through Phone Use.app.")
    @OptionGroup(visibility: .hidden) var backend: BackendOptions
    mutating func run() async throws {
        // Phone Use.app serves every backend; the flags remain accepted for existing MCP configurations.
        let socket = try await HostClient.connect()
        HostClient.relay(socket: socket)
        close(socket)
    }
}
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List phone IDs and discovery hints.")
    mutating func run() async throws { try await AppTool.call("list_phones") }
}
