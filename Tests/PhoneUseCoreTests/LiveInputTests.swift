import Testing
@testable import PhoneUseCore

@Test func aspectFitMapsPillarboxedPortraitImage() {
    // 1000x2000 image in a 1000x1000 view: scale 0.5, 250-point bars left and right.
    let mapping = AspectFitMapping(image: .init(width: 1000, height: 2000), viewWidth: 1000, viewHeight: 1000)
    #expect(mapping.scale == 0.5)
    #expect(mapping.pixel(x: 250, y: 0) == PixelPoint(x: 0, y: 0))
    #expect(mapping.pixel(x: 500, y: 500) == PixelPoint(x: 500, y: 1000))
    #expect(mapping.pixel(x: 749.9, y: 999.9) == PixelPoint(x: 999, y: 1999))
    #expect(mapping.pixel(x: 100, y: 500) == nil)
    #expect(mapping.pixel(x: 750, y: 500) == nil)
    #expect(mapping.clampedPixel(x: 100, y: -50) == PixelPoint(x: 0, y: 0))
    #expect(mapping.clampedPixel(x: 900, y: 2000) == PixelPoint(x: 999, y: 1999))
}
@Test func aspectFitMapsLetterboxedLandscapeImage() {
    let mapping = AspectFitMapping(image: .init(width: 300, height: 100), viewWidth: 600, viewHeight: 600)
    #expect(mapping.originY == 200)
    #expect(mapping.pixel(x: 0, y: 199) == nil)
    #expect(mapping.pixel(x: 0, y: 200) == PixelPoint(x: 0, y: 0))
    #expect(mapping.pixel(x: 599, y: 399) == PixelPoint(x: 299, y: 99))
}
@Test func pointerGesturesClassifyTapLongPressAndSwipe() {
    let origin = PixelPoint(x: 100, y: 100)
    #expect(PointerGesture.action(from: origin, to: .init(x: 110, y: 110), milliseconds: 120) == .tap(origin, count: 1))
    #expect(PointerGesture.action(from: origin, to: origin, milliseconds: 900) == .longPress(origin, milliseconds: 900))
    #expect(PointerGesture.action(from: origin, to: origin, milliseconds: 90_000) == .longPress(origin, milliseconds: 60_000))
    #expect(PointerGesture.action(from: origin, to: .init(x: 100, y: 600), milliseconds: 40) == .swipe(from: origin, to: .init(x: 100, y: 600), milliseconds: 100))
    #expect(PointerGesture.action(from: origin, to: .init(x: 100, y: 600), milliseconds: 9_000) == .swipe(from: origin, to: .init(x: 100, y: 600), milliseconds: 2_000))
}
