import Dispatch
import Foundation

public enum PixelFormat: String, Hashable, Sendable {
    /// Eight-bit premultiplied-alpha RGBA in sRGB color space.
    case rgba8PremultipliedSRGB

    fileprivate var bytesPerPixel: Int { 4 }
}

/// The orientation of the pixel buffer relative to the upright phone display.
public enum FrameOrientation: String, Hashable, Sendable {
    case up
    case down
    case left
    case right
}

/// Monotonic capture metadata. A zero sequence means that the capture provider does not expose a frame index.
public struct FrameFreshness: Hashable, Sendable {
    public let sequence: UInt64
    public let capturedAtNanoseconds: UInt64

    public init(sequence: UInt64, capturedAtNanoseconds: UInt64) {
        self.sequence = sequence
        self.capturedAtNanoseconds = capturedAtNanoseconds
    }

    public static func now(sequence: UInt64 = 0) -> Self {
        Self(sequence: sequence, capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

/// An owned top-to-bottom pixel buffer. `rowStride` includes any row padding.
public struct PixelFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rowStride: Int
    public let pixelFormat: PixelFormat
    public let orientation: FrameOrientation
    public let pixels: Data
    public let freshness: FrameFreshness

    public init(width: Int, height: Int, rowStride: Int, pixelFormat: PixelFormat = .rgba8PremultipliedSRGB,
                orientation: FrameOrientation = .up, pixels: Data, freshness: FrameFreshness = .now()) throws {
        guard width > 0, height > 0 else { throw PhoneError.invalidFrame("Frame dimensions must be positive") }
        let (minimumStride, strideOverflow) = width.multipliedReportingOverflow(by: pixelFormat.bytesPerPixel)
        guard !strideOverflow, rowStride >= minimumStride else {
            throw PhoneError.invalidFrame("Frame row stride is too small or overflows")
        }
        let (requiredBytes, sizeOverflow) = rowStride.multipliedReportingOverflow(by: height)
        guard !sizeOverflow, pixels.count == requiredBytes else {
            throw PhoneError.invalidFrame("Frame buffer length does not match its dimensions and row stride")
        }
        self.width = width
        self.height = height
        self.rowStride = rowStride
        self.pixelFormat = pixelFormat
        self.orientation = orientation
        self.pixels = pixels
        self.freshness = freshness
    }

    /// Returns a top-to-bottom buffer rotated into display coordinates.
    public func upright() throws -> Self {
        guard orientation != .up else { return self }

        let swapsAxes = orientation == .left || orientation == .right
        let outputWidth = swapsAxes ? height : width
        let outputHeight = swapsAxes ? width : height
        let outputStride = try outputWidth.multipliedReportingOverflowChecked(by: pixelFormat.bytesPerPixel)
        let outputCount = try outputStride.multipliedReportingOverflowChecked(by: outputHeight)
        var output = [UInt8](repeating: 0, count: outputCount)
        let source = [UInt8](pixels)

        for y in 0..<height {
            for x in 0..<width {
                let (targetX, targetY): (Int, Int)
                switch orientation {
                case .up: (targetX, targetY) = (x, y)
                case .down: (targetX, targetY) = (width - 1 - x, height - 1 - y)
                case .left: (targetX, targetY) = (y, width - 1 - x)
                case .right: (targetX, targetY) = (height - 1 - y, x)
                }
                let sourceOffset = y * rowStride + x * pixelFormat.bytesPerPixel
                let targetOffset = targetY * outputStride + targetX * pixelFormat.bytesPerPixel
                for channel in 0..<pixelFormat.bytesPerPixel {
                    output[targetOffset + channel] = source[sourceOffset + channel]
                }
            }
        }

        return try Self(width: outputWidth, height: outputHeight, rowStride: outputStride,
                        pixelFormat: pixelFormat, orientation: .up, pixels: Data(output), freshness: freshness)
    }
}

private extension Int {
    func multipliedReportingOverflowChecked(by other: Int) throws -> Int {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        guard !overflow else { throw PhoneError.invalidFrame("Frame dimensions overflow") }
        return value
    }
}
