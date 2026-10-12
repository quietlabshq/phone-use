import CoreGraphics
import Foundation
import ImageIO
import PhoneUseCore
import UniformTypeIdentifiers

public struct CoreGraphicsFrameJPEGEncoder: FrameJPEGEncoder {
    public init() {}

    public func jpeg(_ frame: PixelFrame, maxLongEdge: Int = 1344, quality: Double = 0.8) throws -> Data {
        try ImageEncoding.jpeg(PixelFrameImageAdapter.cgImage(from: frame), maxLongEdge: maxLongEdge, quality: quality)
    }
}

public enum ImageEncoding {
    public static func jpeg(_ image: CGImage, maxLongEdge: Int = 1344, quality: Double = 0.8) throws -> Data {
        guard maxLongEdge > 0, quality.isFinite, (0...1).contains(quality) else {
            throw PhoneError.commandFailed("Invalid JPEG encoding options")
        }
        let size = ScreenshotScaler(native: PixelSize(width: image.width, height: image.height),
                                    maxLongEdge: maxLongEdge).scaled
        guard let context = CGContext(data: nil, width: size.width, height: size.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PhoneError.commandFailed("Could not allocate image context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else {
            throw PhoneError.commandFailed("Could not scale image")
        }
        return try encode(scaled, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static func png(_ image: CGImage) throws -> Data {
        try encode(image, type: .png, options: [:])
    }

    public static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhoneError.commandFailed("Could not decode image")
        }
        return image
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PhoneError.commandFailed("Could not create image encoder")
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhoneError.commandFailed("Could not encode image")
        }
        return data as Data
    }
}
