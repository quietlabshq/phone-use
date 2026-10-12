import CoreGraphics
import Foundation
import Testing
import PhoneUseCore
import PhoneUseCapture
@testable import PhoneUseSimulator

private actor Runner: ProcessRunner {
    struct Call: Equatable { let executable: String; let args: [String]; let input: Data? }
    var calls: [Call] = []
    let version: String
    let frame: String
    let status: Int32
    let empty: Bool
    let landscape: Bool
    let multitap: Bool
    init(version: String = "AXe 1.8.0", frame: String = "402", status: Int32 = 0, empty: Bool = false, landscape: Bool = false, multitap: Bool = true) {
        self.multitap = multitap
        self.landscape = landscape; self.empty = empty; self.version = version; self.frame = frame; self.status = status
    }
    func run(_ executable: String, _ args: [String], stdin: Data?) async throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, input: stdin))
        var output = ""
        if args == ["--version"] { output = version }
        if args == ["tap", "--help"] { output = multitap ? "OPTIONS: --count <count>" : "OPTIONS: -x -y" }
        if args == ["simctl", "list", "devices", "booted", "-j"] {
            output = #"{"devices":{"runtime":[{"name":"iPhone Test","udid":"U","state":"Booted"},{"name":"iPad Test","udid":"I","state":"Booted"}]}}"#
        }
        if empty && args.contains("list") { output = #"{"devices":{}}"# }
        if args.first == "describe-ui" { output = "[{\"frame\":{\"width\":\(frame)}}]" }
        if args.contains("screenshot") {
            let context = CGContext(data: nil, width: landscape ? 2622 : 1206, height: landscape ? 1206 : 2622, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            try ImageEncoding.png(context.makeImage()!).write(to: URL(fileURLWithPath: args.last!))
        }
        return ProcessResult(status: status, stdout: Data(output.utf8), stderr: Data("failed".utf8))
    }
}
private func phone(_ runner: Runner) -> SimulatorPhone {
    SimulatorPhone(udid: "U", name: "Test", screenSize: .init(width: 1206, height: 2622), pointScale: 3, axe: "axe", runner: runner)
}
@Test func simulatorNativeMultitapAndCapabilityCache() async throws {
    let runner = Runner(); let p = phone(runner)
    try await p.perform(.tap(.init(x: 603, y: 1311), count: 1))
    try await p.perform(.tap(.init(x: 603, y: 1311), count: 3))
    let calls = await runner.calls
    #expect(calls[0].args == ["tap", "-x", "201", "-y", "437", "--udid", "U"])
    #expect(calls[1].args == ["tap", "--help"])
    #expect(calls[2].args == ["tap", "-x", "201", "-y", "437", "--count", "3", "--udid", "U"])
    try await p.perform(.tap(.init(x: 603, y: 1311), count: 2))
    #expect(await runner.calls.last?.args == ["tap", "-x", "201", "-y", "437", "--count", "2", "--udid", "U"])
    #expect(await runner.calls.count == 4)
}
@Test func simulatorKeysAndTyping() async throws {
    let runner = Runner(); let p = phone(runner)
    try await p.perform(.key(.letter("h"), modifiers: [.command], repeat: 1))
    try await p.perform(.key(.enter, modifiers: [], repeat: 2))
    try await p.perform(.typeText("hello\nworld"))
    let calls = await runner.calls
    #expect(calls[0].args == ["key-combo", "--modifiers", "227", "--key", "11", "--udid", "U"])
    #expect(calls[1].args == ["key", "40", "--udid", "U"])
    #expect(calls[2] == calls[1])
    #expect(calls[3].args == ["type", "--stdin", "--udid", "U"])
    #expect(calls[3].input == Data("hello\nworld".utf8))
}
@Test func simulatorDurations() async throws {
    let runner = Runner(); let p = phone(runner)
    try await p.perform(.longPress(.init(x: 1, y: 2), milliseconds: 1250))
    try await p.perform(.swipe(from: .init(x: 0, y: 0), to: .init(x: 603, y: 1311), milliseconds: 500))
    let calls = await runner.calls
    #expect(calls[0].args == ["touch", "-x", "0.33", "-y", "0.67", "--down", "--up", "--delay", "1.25", "--udid", "U"])
    #expect(calls[1].args == ["swipe", "--start-x", "0", "--start-y", "0", "--end-x", "201", "--end-y", "437", "--duration", "0.5", "--udid", "U"])
}
@Test func simulatorRejectsInvalidActionsWithoutProcesses() async {
    let runner = Runner(); let p = phone(runner)
    let invalid: [PhoneAction] = [.typeText("helloé"), .tap(.init(x: 0, y: 0), count: 0),
        .tap(.init(x: -1, y: 0), count: 1), .longPress(.init(x: 0, y: 0), milliseconds: -1),
        .swipe(from: .init(x: 0, y: 0), to: .init(x: 0, y: 0), milliseconds: 0),
        .key(.enter, modifiers: [], repeat: 0), .key(.letter("é"), modifiers: [], repeat: 1)]
    for action in invalid { await #expect(throws: (any Error).self) { try await p.perform(action) } }
    #expect(await runner.calls.isEmpty)
}
@Test func simulatorCommandFailure() async {
    await #expect(throws: PhoneError.commandFailed("failed")) {
        try await phone(Runner(status: 1)).perform(.typeText("a"))
    }
}
@Test func simulatorDiscoveryAndScreenshotCleanup() async throws {
    let runner = Runner(); let result = await SimulatorRegistry(axe: "axe", runner: runner).discover()
    #expect(result.hints.isEmpty)
    let p = try #require(result.phones.first)
    #expect(p.info.screenSize == PixelSize(width: 1206, height: 2622))
    try await p.perform(.tap(.init(x: 603, y: 1311), count: 1))
    #expect(await runner.calls.last?.args == ["tap", "-x", "201", "-y", "437", "--udid", "U"])
    let calls = await runner.calls
    for call in calls where call.args.contains("screenshot") { #expect(!FileManager.default.fileExists(atPath: call.args.last!)) }
}
@Test func simulatorUnavailableAndInvalidFrameHints() async {
    for runner in [Runner(version: "1.7.9"), Runner(version: "garbage"), Runner(status: 1)] {
        let result = await SimulatorRegistry(axe: "axe", runner: runner).discover()
        #expect(result.phones.isEmpty)
        #expect(result.hints == ["AXe >= 1.8.0 is required (set PHONE_USE_AXE)"])
    }
    let result = await SimulatorRegistry(axe: "axe", runner: Runner(frame: "0")).discover()
    #expect(result.phones.isEmpty)
    #expect(!result.hints.isEmpty)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["PHONE_USE_SIM_UDID"] != nil))
func SimulatorIntegration() async throws {
    let udid = try #require(ProcessInfo.processInfo.environment["PHONE_USE_SIM_UDID"])
    let result = await SimulatorRegistry().discover()
    let p = try #require(result.phones.first { $0.info.id == udid })
    // This opt-in UI assertion requires an English-language simulator.
    try await Macros.home(on: p, sleeper: RealSleeper())
    try await expectApplication(" ", udid: udid)
    try await RealSleeper().sleep(milliseconds: 800)
    try await p.perform(.key(.space, modifiers: [.command], repeat: 1))
    try await RealSleeper().sleep(milliseconds: 800)
    try await p.perform(.typeText("Settings"))
    try await expectApplication("Spotlight", udid: udid, query: "Settings")
    try await Macros.openApp("Settings", on: p, sleeper: RealSleeper())
    try await expectApplication("Settings", udid: udid)
    let image = try await p.screenshot()
    #expect(image.width > 0 && image.height > 0)
    try await Macros.home(on: p, sleeper: RealSleeper())
    try await expectApplication(" ", udid: udid)
    try await RealSleeper().sleep(milliseconds: 800)
    try await p.perform(.key(.space, modifiers: [.command], repeat: 1))
    try await RealSleeper().sleep(milliseconds: 800)
    try await p.perform(.typeText("Settings"))
    try await expectApplication("Spotlight", udid: udid, query: "Settings")
    try await Macros.home(on: p, sleeper: RealSleeper())
    // SpringBoard exposes the Home screen as an application with a blank label.
    try await expectApplication(" ", udid: udid)
}

private struct MissingAXeRunner: ProcessRunner {
    func run(_ executable: String, _ args: [String], stdin: Data?) async throws -> ProcessResult {
        throw PhoneError.toolUnavailable(executable)
    }
}
@Test func missingAxeGivesHint() async {
    let result = await SimulatorRegistry(axe: "missing-axe", runner: MissingAXeRunner()).discover()
    #expect(result.phones.isEmpty)
    #expect(result.hints == ["AXe >= 1.8.0 is required (set PHONE_USE_AXE)"])
}

@Test func simulatorEmptyDiscoverySuggestsBooting() async {
    let result = await SimulatorRegistry(axe: "axe", runner: Runner(empty: true)).discover()
    #expect(result.phones.isEmpty)
    #expect(result.hints.contains { $0.contains("Boot one with: xcrun simctl boot <udid>") })
}

@Test func simulatorTracksScreenshotRotation() async throws {
    let runner = Runner(landscape: true)
    let p = phone(runner)
    let image = try await p.screenshot()
    #expect(image.width == 2622 && image.height == 1206)
    try await p.perform(.tap(.init(x: 2000, y: 600), count: 1))
    #expect(await runner.calls.last?.args == ["tap", "-x", "666.67", "-y", "200", "--udid", "U"])
    await #expect(throws: PhoneError.outOfBounds(.init(x: 600, y: 2000), .init(width: 2622, height: 1206))) {
        try await p.perform(.tap(.init(x: 600, y: 2000), count: 1))
    }
    #expect(p.info.screenSize == PixelSize(width: 1206, height: 2622))
    #expect(p.pointScale == 3)
}

private func expectApplication(_ name: String, udid: String, query: String? = nil) async throws {
    let axe = ProcessInfo.processInfo.environment["PHONE_USE_AXE"] ?? "axe"
    var labels: [String] = []
    for _ in 0..<20 {
        let result = try await LiveProcessRunner().run(axe, ["describe-ui", "--udid", udid], stdin: nil)
        #expect(result.status == 0)
        let roots = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])
        labels = roots.filter { $0["type"] as? String == "Application" }.compactMap { $0["AXLabel"] as? String }
        func hasQuery(_ nodes: [[String: Any]], _ query: String) -> Bool {
            nodes.contains { node in
                (node["type"] as? String == "TextField" && node["AXValue"] as? String == query)
                    || hasQuery(node["children"] as? [[String: Any]] ?? [], query)
            }
        }
        if labels == [name], query.map({ hasQuery(roots, $0) }) ?? true { return }
        try await RealSleeper().sleep(milliseconds: 250)
    }
    try #require(Bool(false), "Expected foreground application \(name) with query \(query ?? "<none>"), got \(labels)")
}

@Test func stockAxeRejectsMultitapBeforeSendingTouches() async throws {
    let runner = Runner(multitap: false)
    let p = phone(runner)
    await #expect(throws: PhoneError.commandFailed("Multi-tap requires the patched AXe. Run scripts/build-axe.sh, then set PHONE_USE_AXE to .build/tools/axe/bin/axe.")) {
        try await p.perform(.tap(.init(x: 100, y: 100), count: 2))
    }
    #expect(await runner.calls.map(\.args) == [["tap", "--help"]])
    try await p.perform(.tap(.init(x: 100, y: 100), count: 1))
    #expect(await runner.calls.count == 2)
}

@Test func simulatorHomeUsesNativeButton() async throws {
    let runner = Runner()
    try await phone(runner).perform(.home)
    #expect(await runner.calls.map(\.args) == [["batch", "--udid", "U", "--step", "button home", "--step", "sleep 0.8", "--step", "button home"]])
}
