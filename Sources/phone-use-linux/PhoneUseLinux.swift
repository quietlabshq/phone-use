import ArgumentParser
import Foundation
import PhoneUseCore
import PhoneUseMCP

@main
struct PhoneUseLinux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phone-use",
        abstract: "Exercise the portable phone-use MCP interface on Linux.",
        version: "0.1.0",
        subcommands: [MCPCommand.self]
    )
}

private struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve MCP over standard input/output.")

    @Flag(help: "Attach the deterministic fake phone for Linux smoke testing.")
    var fake = false

    mutating func run() async throws {
        let registry: any PhoneRegistry = fake ? FakePhoneRegistry() : UnavailableLinuxRegistry()
        let dispatcher = ToolDispatcher(registry: registry, imageEncoder: FakeJPEGEncoder())
        try await MCPServer.run(dispatcher: dispatcher)
    }
}

private struct UnavailableLinuxRegistry: PhoneRegistry {
    func discover() async -> (phones: [any Phone], hints: [String]) {
        ([], ["This Linux build has no device backend yet. Use --fake for MCP smoke testing."])
    }
}

private struct FakePhoneRegistry: PhoneRegistry {
    func discover() async -> (phones: [any Phone], hints: [String]) {
        ([FakePhone()], [])
    }
}

private actor FakePhone: Phone {
    nonisolated let info = PhoneInfo(id: "fake-iphone", name: "Fake iPhone", kind: .simulator,
                                    screenSize: PixelSize(width: 2, height: 2))
    private var sequence: UInt64 = 0
    private var lastAction = "idle"

    func screenshot() async throws -> PixelFrame {
        sequence &+= 1
        let color: [UInt8] = lastAction == "idle" ? [24, 96, 180, 255] : [180, 96, 24, 255]
        var pixels = [UInt8](repeating: 0, count: 16)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels.replaceSubrange(offset..<(offset + 4), with: color)
        }
        return try PixelFrame(width: 2, height: 2, rowStride: 8, pixels: Data(pixels),
                              freshness: .now(sequence: sequence))
    }

    func perform(_ action: PhoneAction) async throws {
        lastAction = String(describing: action)
        sequence &+= 1
    }
}

private struct FakeJPEGEncoder: FrameJPEGEncoder {
    // The fixture is used only to exercise MCP image transport; Linux image encoding is selected after Task 15.
    func jpeg(_ frame: PixelFrame, maxLongEdge: Int, quality: Double) throws -> Data {
        guard let url = Bundle.module.url(forResource: "fake-screenshot", withExtension: "jpg") else {
            throw PhoneError.toolUnavailable("Linux fake screenshot fixture")
        }
        return try Data(contentsOf: url)
    }
}
