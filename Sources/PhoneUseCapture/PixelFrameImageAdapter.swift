import CoreGraphics
import Foundation
import PhoneUseCore

public enum PixelFrameImageAdapter {
    public static func frame(from image: CGImage, sequence: UInt64 = 0) throws -> PixelFrame {
        let (rowStride, strideOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = rowStride.multipliedReportingOverflow(by: image.height)
        guard image.width > 0, image.height > 0, !strideOverflow, !countOverflow else {
            throw PhoneError.invalidFrame("Image dimensions overflow")
        }
        var pixels = [UInt8](repeating: 0, count: byteCount)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: rowStride,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return false }
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw PhoneError.invalidFrame("Could not copy image pixels") }
        return try PixelFrame(width: image.width, height: image.height, rowStride: rowStride,
                              pixels: Data(pixels), freshness: .now(sequence: sequence))
    }

    public static func cgImage(from source: PixelFrame) throws -> CGImage {
        let frame = try source.upright()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: frame.rowStride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw PhoneError.invalidFrame("Could not create image from pixels")
        }
        return image
    }
}
