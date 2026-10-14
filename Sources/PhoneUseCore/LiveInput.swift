/// Maps points in a view that shows an image aspect-fit (letterboxed) to image pixels.
public struct AspectFitMapping: Sendable, Equatable {
    public let image: PixelSize
    public let originX: Double
    public let originY: Double
    public let scale: Double

    /// `viewWidth`/`viewHeight` are in view points, with the origin at the top left.
    public init(image: PixelSize, viewWidth: Double, viewHeight: Double) {
        precondition(image.width > 0 && image.height > 0)
        self.image = image
        scale = min(viewWidth / Double(image.width), viewHeight / Double(image.height))
        originX = (viewWidth - Double(image.width) * scale) / 2
        originY = (viewHeight - Double(image.height) * scale) / 2
    }

    /// The image pixel under a view point, or nil in the letterbox bars.
    public func pixel(x: Double, y: Double) -> PixelPoint? {
        guard scale > 0 else { return nil }
        let px = Int(((x - originX) / scale).rounded(.down))
        let py = Int(((y - originY) / scale).rounded(.down))
        guard (0..<image.width).contains(px), (0..<image.height).contains(py) else { return nil }
        return PixelPoint(x: px, y: py)
    }

    /// Like `pixel`, but clamps points outside the image to its nearest edge pixel.
    public func clampedPixel(x: Double, y: Double) -> PixelPoint {
        let px = scale > 0 ? Int(((x - originX) / scale).rounded(.down)) : 0
        let py = scale > 0 ? Int(((y - originY) / scale).rounded(.down)) : 0
        return PixelPoint(x: min(max(0, px), image.width - 1), y: min(max(0, py), image.height - 1))
    }
}

/// Turns one pointer press (down, optional drag, up) into a phone gesture.
public enum PointerGesture {
    /// Movement below this many image pixels still counts as a tap.
    public static let slopPixels = 24
    public static let longPressMilliseconds = 500

    public static func action(from start: PixelPoint, to end: PixelPoint, milliseconds: Int) -> PhoneAction {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        if (dx * dx + dy * dy).squareRoot() < Double(slopPixels) {
            return milliseconds >= longPressMilliseconds
                ? .longPress(start, milliseconds: min(milliseconds, 60_000))
                : .tap(start, count: 1)
        }
        return .swipe(from: start, to: end, milliseconds: min(max(milliseconds, 100), 2_000))
    }
}
