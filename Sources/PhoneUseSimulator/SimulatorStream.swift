import CoreGraphics
import Foundation
import PhoneUseCapture
import PhoneUseCore

/// Splits `axe stream-video --format raw` output: each frame is a 4-byte big-endian
/// length followed by an encoded image.
struct LengthPrefixedFrames {
    static let maximumFrameBytes = 64 << 20
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maximumFrameBytes else { throw PhoneError.commandFailed("Simulator stream frame is too large (\(length) bytes)") }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

extension SimulatorPhone: LiveFrameSource {
    /// Streams screenshots through AXe. Roughly 8 frames per second at native size.
    public nonisolated func liveFrames() async throws -> AsyncStream<CGImage> {
        let process = Process()
        process.executableURL = try resolveExecutable(axe)
        process.arguments = ["stream-video", "--udid", info.id, "--format", "raw", "--fps", "30"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncStream.makeStream(of: CGImage.self, bufferingPolicy: .bufferingNewest(1))
        let parser = ParserBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let frames = try? parser.append(data) else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            // Decoding every frame is wasted work when the consumer lags; the newest wins anyway.
            if let latest = frames.last, let image = try? ImageEncoding.load(latest) { continuation.yield(image) }
        }
        process.terminationHandler = { _ in continuation.finish() }
        continuation.onTermination = { _ in if process.isRunning { process.terminate() } }
        try process.run()
        return stream
    }
}

private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = LengthPrefixedFrames()
    func append(_ data: Data) throws -> [Data] { try lock.withLock { try parser.append(data) } }
}
