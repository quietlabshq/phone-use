import Testing
@testable import PhoneUseCore

@Test func scalesScreenshotToMaximumLongEdge() {
    let scaler = ScreenshotScaler(native: PixelSize(width: 1206, height: 2622))
    #expect(scaler.scaled == PixelSize(width: 618, height: 1344))
}

@Test func doesNotUpscaleScreenshot() {
    let size = PixelSize(width: 400, height: 800)
    #expect(ScreenshotScaler(native: size).scaled == size)
}

@Test func mapsScreenshotCoordinatesToNativePixels() throws {
    let scaler = ScreenshotScaler(native: PixelSize(width: 1206, height: 2622))
    #expect(try scaler.toNative(PixelPoint(x: 309, y: 672)) == PixelPoint(x: 603, y: 1311))
}

@Test func rejectsCoordinatesOutsideScreenshot() {
    let scaler = ScreenshotScaler(native: PixelSize(width: 1206, height: 2622))
    for point in [PixelPoint(x: 618, y: 0), PixelPoint(x: -1, y: 0), PixelPoint(x: 0, y: 1344)] {
        #expect(throws: PhoneError.outOfBounds(point, scaler.scaled)) {
            try scaler.toNative(point)
        }
    }
}

@Test func parsesKeyNames() {
    #expect(Key(name: "arrow_up") == .up)
    #expect(Key(name: "h") == .letter("h"))
    #expect(Key(name: "f1") == nil)
}
