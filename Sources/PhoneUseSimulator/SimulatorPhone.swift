import CoreGraphics
import Foundation
import PhoneUseCore
import PhoneUseCapture

public actor SimulatorPhone: Phone {
    public nonisolated let info: PhoneInfo
    public nonisolated let pointScale: Double
    private var currentScreenSize: PixelSize
    let axe: String
    private let runner: any ProcessRunner
    private var supportsMultitap: Bool?

    public init(udid: String, name: String, screenSize: PixelSize, pointScale: Double,
                axe: String = "axe", runner: any ProcessRunner = LiveProcessRunner()) {
        info = PhoneInfo(id: udid, name: name, kind: .simulator, screenSize: screenSize)
        currentScreenSize = screenSize
        self.pointScale = pointScale
        self.axe = axe
        self.runner = runner
    }

    public func screenshot() async throws -> PixelFrame {
        let image = try await simulatorScreenshot(udid: info.id, runner: runner)
        let frame = try PixelFrameImageAdapter.frame(from: image)
        currentScreenSize = PixelSize(width: frame.width, height: frame.height)
        return frame
    }

    public func perform(_ action: PhoneAction) async throws {
        let suffix = ["--udid", info.id]
        switch action {
        case .home:
            // The first Home can restore Spotlight behind an app; the second dismisses it.
            try await execute(["batch"] + suffix + ["--step", "button home", "--step", "sleep 0.8", "--step", "button home"])
        case let .tap(point, count):
            guard (1...3).contains(count) else { throw invalid("Tap count must be 1...3") }
            let (x, y) = try coordinates(point)
            if count == 1 {
                try await execute(["tap", "-x", x, "-y", y] + suffix)
            } else {
                if supportsMultitap == nil {
                    let help = try await checkedRun(runner, axe, ["tap", "--help"])
                    supportsMultitap = String(decoding: help, as: UTF8.self).contains("--count")
                }
                guard supportsMultitap == true else {
                    throw invalid("Multi-tap requires the patched AXe. Run scripts/build-axe.sh, then set PHONE_USE_AXE to .build/tools/axe/bin/axe.")
                }
                try await execute(["tap", "-x", x, "-y", y, "--count", String(count)] + suffix)
            }
        case let .longPress(point, milliseconds):
            let duration = try seconds(milliseconds)
            let (x, y) = try coordinates(point)
            try await execute(["touch", "-x", x, "-y", y, "--down", "--up", "--delay", duration] + suffix)
        case let .swipe(from, to, milliseconds):
            let duration = try seconds(milliseconds)
            let (x1, y1) = try coordinates(from)
            let (x2, y2) = try coordinates(to)
            try await execute(["swipe", "--start-x", x1, "--start-y", y1, "--end-x", x2,
                               "--end-y", y2, "--duration", duration] + suffix)
        case let .typeText(text):
            _ = try KeyboardMap.strokes(for: text)
            try await execute(["type", "--stdin"] + suffix, input: Data(text.utf8))
        case let .key(key, modifiers, repetitions):
            guard (1...100).contains(repetitions) else { throw invalid("Key repeat must be 1...100") }
            if case let .letter(character) = key {
                guard Key(name: String(character)) != nil else { throw invalid("Key must be a lowercase ASCII letter") }
            }
            let usage = String(KeyboardMap.usage(for: key))
            let args = modifiers.isEmpty ? ["key", usage] : ["key-combo", "--modifiers",
                modifiers.map { String(KeyboardMap.modifierUsage($0)) }.joined(separator: ","), "--key", usage]
            for _ in 0..<repetitions { try await execute(args + suffix) }
        }
    }

    private func coordinates(_ point: PixelPoint) throws -> (String, String) {
        guard pointScale.isFinite, pointScale > 0 else { throw invalid("Invalid simulator point scale") }
        guard point.x >= 0, point.y >= 0, point.x < currentScreenSize.width, point.y < currentScreenSize.height else {
            throw PhoneError.outOfBounds(point, currentScreenSize)
        }
        return (decimal(Double(point.x) / pointScale), decimal(Double(point.y) / pointScale))
    }

    private func seconds(_ milliseconds: Int) throws -> String {
        guard (1...60_000).contains(milliseconds) else { throw invalid("Duration must be 1...60000 milliseconds") }
        return String(Double(milliseconds) / 1000)
    }

    private func execute(_ args: [String], input: Data? = nil) async throws {
        _ = try await checkedRun(runner, axe, args, input: input)
    }

    private func invalid(_ message: String) -> PhoneError { .commandFailed(message) }
}

private func decimal(_ value: Double) -> String {
    let formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    return formatted.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
}

func checkedRun(_ runner: any ProcessRunner, _ executable: String, _ args: [String], input: Data? = nil) async throws -> Data {
    let result = try await runner.run(executable, args, stdin: input)
    guard result.status == 0 else { throw PhoneError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
    return result.stdout
}

func simulatorScreenshot(udid: String, runner: any ProcessRunner) async throws -> CGImage {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-use-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await checkedRun(runner, "xcrun", ["simctl", "io", udid, "screenshot", "--type=png", url.path])
    return try ImageEncoding.load(Data(contentsOf: url))
}
