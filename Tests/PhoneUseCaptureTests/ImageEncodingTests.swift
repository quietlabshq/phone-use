import CoreGraphics
import Foundation
import Testing
import PhoneUseCore
@testable import PhoneUseCapture

@Test func jpegScalesScreenshot() throws {
    let context = try #require(CGContext(data: nil, width: 1206, height: 2622,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let decoded = try ImageEncoding.load(ImageEncoding.jpeg(image))
    #expect(decoded.width == 618)
    #expect(decoded.height == 1344)
    let png = try ImageEncoding.load(ImageEncoding.png(image))
    #expect(png.width == 1206)
    #expect(png.height == 2622)
}

@Test func frameAdapterAndEncoderPreserveDimensionsAndOrientation() throws {
    let context = try #require(CGContext(data: nil, width: 3, height: 2,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let frame = try PixelFrameImageAdapter.frame(from: image)
    #expect(frame.width == 3 && frame.height == 2)
    #expect(frame.rowStride == 12)
    #expect(frame.orientation == .up)
    let decoded = try ImageEncoding.load(CoreGraphicsFrameJPEGEncoder().jpeg(frame, maxLongEdge: 10, quality: 0.8))
    #expect(decoded.width == 3 && decoded.height == 2)
}

@Test func rejectsInvalidImageData() {
    #expect(throws: (any Error).self) { try ImageEncoding.load(Data("invalid".utf8)) }
}
