import ArgumentParser
import Foundation
import MCP
import PhoneUseIPC
import PhoneUseMCP
import PhoneUseRuntime

struct BackendOptions: ParsableArguments {
    @Flag(help: "Discover simulators (both backends when neither flag is given).") var simulator = false
    @Flag(help: "Discover configured USB hardware phones.") var hardware = false
    var usesSimulator: Bool { simulator || !hardware }
    var usesHardware: Bool { hardware || !simulator }
    func dispatcher() -> ToolDispatcher { Runtime.dispatcher(simulator: usesSimulator, hardware: usesHardware) }
}

struct ActionOptions: ParsableArguments {
    @Option(help: "Phone ID from list; optional when exactly one phone is available.") var phone: String?
    func call(_ name: String, _ arguments: [String: Value] = [:], output: String? = nil) async throws {
        var arguments = arguments
        if let phone { arguments["phone_id"] = .string(phone) }
        try await AppTool.call(name, arguments, output: output)
    }
}

/// A tool call the app rejected; unlike a usage error, the command line was fine.
struct ToolError: Error, CustomStringConvertible {
    let description: String
}

/// Runs one tool call through Phone Use.app, which owns phone access.
enum AppTool {
    static func call(_ name: String, _ arguments: [String: Value] = [:], output: String? = nil) async throws {
        let client = try await HostClient.session()
        let result: (content: [Tool.Content], isError: Bool?)
        do { result = try await client.callTool(name: name, arguments: arguments) }
        catch { await client.disconnect(); throw error }
        await client.disconnect()
        var messages: [String] = []
        var image: Data?
        for content in result.content {
            switch content {
            case let .text(text, _, _): messages.append(text)
            case let .image(data, _, _, _): image = Data(base64Encoded: data)
            default: break
            }
        }
        if result.isError == true { throw ToolError(description: messages.joined(separator: "\n")) }
        if let image {
            guard let output else { throw ValidationError("Screenshot requires --output") }
            try image.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Saved \(output). \(messages.joined(separator: " "))")
        } else {
            print(messages.joined(separator: "\n"))
        }
    }
}
