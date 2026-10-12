import Foundation
import PhoneUseCore

public struct Blob: Equatable, Sendable {
    public let centroid: (Double, Double)
    public let pixelCount: Int
    public init(centroid: (Double, Double), pixelCount: Int) {
        self.centroid = centroid
        self.pixelCount = pixelCount
    }
    public static func == (lhs: Blob, rhs: Blob) -> Bool {
        lhs.centroid.0 == rhs.centroid.0 && lhs.centroid.1 == rhs.centroid.1 && lhs.pixelCount == rhs.pixelCount
    }
}

public enum CursorLocator {
    public static func grayscale(_ source: PixelFrame) -> [UInt8] {
        guard let frame = try? source.upright() else { return [] }
        let rgba = [UInt8](frame.pixels)
        var grayscale = [UInt8](repeating: 0, count: frame.width * frame.height)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let pixel = y * frame.rowStride + x * 4
                let gray = (299 * Int(rgba[pixel]) + 587 * Int(rgba[pixel + 1]) + 114 * Int(rgba[pixel + 2]) + 500) / 1000
                grayscale[y * frame.width + x] = UInt8(gray)
            }
        }
        return grayscale
    }

    public static func changedBlobs(before: [UInt8], after: [UInt8], width: Int, height: Int, threshold: UInt8 = 40, minPixels: Int = 30) -> [Blob] {
        let (size, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, before.count == size, after.count == size,
              minPixels > 0 else { return [] }
        var changed = zip(before, after).map { abs(Int($0) - Int($1)) > Int(threshold) }
        var blobs: [Blob] = []
        for seed in 0..<size where changed[seed] {
            var queue = [seed]
            changed[seed] = false
            var index = 0
            var sumX = 0.0
            var sumY = 0.0
            while index < queue.count {
                let pixel = queue[index]
                index += 1
                let x = pixel % width
                let y = pixel / width
                sumX += Double(x)
                sumY += Double(y)
                var neighbors: [Int] = []
                if x > 0 { neighbors.append(pixel - 1) }
                if x + 1 < width { neighbors.append(pixel + 1) }
                if y > 0 { neighbors.append(pixel - width) }
                if y + 1 < height { neighbors.append(pixel + width) }
                for neighbor in neighbors where changed[neighbor] {
                    changed[neighbor] = false
                    queue.append(neighbor)
                }
            }
            if queue.count >= minPixels {
                blobs.append(Blob(centroid: (sumX / Double(queue.count), sumY / Double(queue.count)), pixelCount: queue.count))
            }
        }
        return blobs.sorted { $0.pixelCount > $1.pixelCount }
    }
}
