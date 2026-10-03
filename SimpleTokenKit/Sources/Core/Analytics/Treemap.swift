import Foundation
import CoreGraphics

/// Squarified treemap: splits a rectangle into tiles whose areas are proportional to the values and
/// as close to squares as the order allows.
public enum Treemap {
    /// One rectangle per value, in the same order. Pass the values biggest first; values of zero or
    /// less get an empty rectangle.
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0) { $0 + max(0, $1) }
        var out = [CGRect](repeating: .zero, count: values.count)
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0) * scale }
        var free = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }
            // Grow the row for as long as its worst tile gets closer to a square
            var row = [areas[i]], sum = areas[i]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], sum + areas[j], side) <= worst(row, sum, side) {
                row.append(areas[j])
                sum += areas[j]
                j += 1
            }
            // The row runs along the shorter side and takes a strip off the free rectangle
            let thickness = sum / side
            let alongHeight = free.width >= free.height
            var offset = 0.0
            for (k, area) in row.enumerated() {
                let length = thickness > 0 ? area / thickness : 0
                out[i + k] = alongHeight
                    ? CGRect(x: Double(free.minX), y: Double(free.minY) + offset, width: thickness, height: length)
                    : CGRect(x: Double(free.minX) + offset, y: Double(free.minY), width: length, height: thickness)
                offset += length
            }
            free = alongHeight
                ? CGRect(x: free.minX + thickness, y: free.minY, width: max(0, free.width - thickness), height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: max(0, free.height - thickness))
            i = j
        }
        return out
    }

    /// The worst aspect ratio in a row of the given areas laid along a side
    private static func worst(_ row: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let largest = row.max(), let smallest = row.min(), smallest > 0, sum > 0 else { return .infinity }
        let side2 = side * side, sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}
