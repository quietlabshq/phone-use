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

private func image(width: Int) -> CGImage {
    CGContext(data: nil, width: width, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
}
@Test func frameStoreStreamsCurrentThenNewestFrames() async {
    let store = FrameStore()
    store.publish(image(width: 1))
    var iterator = store.subscribe().makeAsyncIterator()
    #expect(await iterator.next()?.width == 1)
    // A slow consumer sees only the newest frame.
    store.publish(image(width: 2))
    store.publish(image(width: 3))
    #expect(await iterator.next()?.width == 3)
}
@Test func frameStoreDropsFinishedSubscribers() {
    let store = FrameStore()
    var stream: AsyncStream<CGImage>? = store.subscribe()
    #expect(stream != nil && store.subscriberCount == 1)
    stream = nil
    #expect(store.subscriberCount == 0)
}
