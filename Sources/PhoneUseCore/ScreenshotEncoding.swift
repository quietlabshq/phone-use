import Foundation

public protocol FrameJPEGEncoder: Sendable {
    func jpeg(_ frame: PixelFrame, maxLongEdge: Int, quality: Double) throws -> Data
}

public struct UnavailableFrameJPEGEncoder: FrameJPEGEncoder {
    public init() {}

    public func jpeg(_ frame: PixelFrame, maxLongEdge: Int, quality: Double) throws -> Data {
        throw PhoneError.toolUnavailable("JPEG encoding is not configured for this host")
    }
}
