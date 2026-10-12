public struct PixelPoint: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct ScreenshotScaler: Sendable {
    public let native: PixelSize
    public let scaled: PixelSize

    public init(native: PixelSize, maxLongEdge: Int = 1344) {
        precondition(native.width > 0 && native.height > 0 && maxLongEdge > 0)
        self.native = native
        let ratio = min(1, Double(maxLongEdge) / Double(max(native.width, native.height)))
        self.scaled = PixelSize(
            width: max(1, Int((Double(native.width) * ratio).rounded())),
            height: max(1, Int((Double(native.height) * ratio).rounded()))
        )
    }

    public func toNative(_ point: PixelPoint) throws -> PixelPoint {
        guard (0..<scaled.width).contains(point.x), (0..<scaled.height).contains(point.y) else {
            throw PhoneError.outOfBounds(point, scaled)
        }
        return PixelPoint(
            x: Int((Double(point.x) * Double(native.width) / Double(scaled.width)).rounded()),
            y: Int((Double(point.y) * Double(native.height) / Double(scaled.height)).rounded())
        )
    }
}
