import Testing
import CoreGraphics
@testable import PhoneUseCapture
@Test func frameStoreRequiresFreshFrame() {
    let store = FrameStore()
    let version = store.version
    #expect(store.frame(after: version) == nil)
    let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    store.publish(image)
    #expect(store.frame(after: version)?.width == 2)
    #expect(store.frame(after: store.version) == nil)
}

@Test func deniedCameraAccessHasActionableGuidance() throws {
    #expect(throws: (any Error).self) { try CaptureSource.checkAuthorization(.denied) }
    #expect(throws: (any Error).self) { try CaptureSource.checkAuthorization(.restricted) }
    try CaptureSource.checkAuthorization(.notDetermined)
    try CaptureSource.checkAuthorization(.authorized)
    do {
        try CaptureSource.checkAuthorization(.denied)
    } catch {
        #expect(String(describing: error).contains("System Settings > Privacy & Security > Camera"))
    }
}
