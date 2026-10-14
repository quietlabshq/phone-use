import ArgumentParser
import MCP

struct Screenshot: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    @Option(name: [.short, .long], help: "Destination JPEG path.") var output: String
    mutating func run() async throws { try await options.call("screenshot", output: output) }
}
struct Tap: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    @Argument var x: Int
    @Argument var y: Int
    @Option var count = 1
    mutating func run() async throws { try await options.call("tap", ["x": .int(x), "y": .int(y), "count": .int(count)]) }
}
struct LongPress: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    @Argument var x: Int
    @Argument var y: Int
    @Option var durationMs = 800
    mutating func run() async throws { try await options.call("long_press", ["x": .int(x), "y": .int(y), "duration_ms": .int(durationMs)]) }
}
struct Swipe: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    @Argument var fromX: Int
    @Argument var fromY: Int
    @Argument var toX: Int
    @Argument var toY: Int
    @Option var durationMs = 300
    mutating func run() async throws { try await options.call("swipe", ["from_x": .int(fromX), "from_y": .int(fromY), "to_x": .int(toX), "to_y": .int(toY), "duration_ms": .int(durationMs)]) }
}
struct TypeText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type")
    @OptionGroup var options: ActionOptions
    @Argument var text: String
    mutating func run() async throws { try await options.call("type_text", ["text": .string(text)]) }
}
struct PressKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key")
    @OptionGroup var options: ActionOptions
    @Argument var name: String
    @Option(help: "Comma-separated control,shift,option,command.") var modifiers: String?
    @Option(name: .customLong("repeat")) var repeatCount = 1
    mutating func run() async throws {
        let values = modifiers.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } ?? []
        try await options.call("press_key", ["key": .string(name), "modifiers": .array(values.map(Value.string)), "repeat": .int(repeatCount)])
    }
}
struct Home: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    mutating func run() async throws { try await options.call("press_home") }
}
struct OpenApp: AsyncParsableCommand {
    @OptionGroup var options: ActionOptions
    @Argument var name: String
    mutating func run() async throws { try await options.call("open_app", ["name": .string(name)]) }
}
