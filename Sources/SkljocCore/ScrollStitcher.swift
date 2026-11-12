import Foundation

/// A grayscale picture of one scrolling-capture frame, row by row from the top.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match the size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Finds how far content moved between two frames of a scrolling page, ignoring sticky headers and footers.
public enum ScrollStitcher {
    /// Each row is summarized as the average brightness of this many column bands.
    static let bands = 48
    /// Every this many rows are compared in the first pass over all shifts.
    static let sampleStep = 3

    /// Rows at the top and bottom that didn't change at all, like a sticky header or toolbar.
    public static func fixedEdges(_ previous: GrayImage, _ current: GrayImage, maxFraction: Double = 0.35) -> (top: Int, bottom: Int) {
        guard previous.width == current.width, previous.height == current.height else { return (0, 0) }
        let limit = Int(Double(previous.height) * maxFraction)
        var top = 0
        while top < limit, rowsEqual(previous, top, current, top) { top += 1 }
        var bottom = 0
        while bottom < limit, rowsEqual(previous, previous.height - 1 - bottom, current, current.height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    /// How many rows the content moved up from `previous` to `current`: 0 when it didn't move,
    /// nil when no convincing overlap was found (scrolled too far, or the page changed).
    public static func scrollOffset(from previous: GrayImage, to current: GrayImage, top: Int, bottom: Int, minimumOverlap: Int = 24) -> Int? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let regionHeight = previous.height - top - bottom
        guard regionHeight > minimumOverlap * 2 else { return nil }

        let old = signatures(of: previous, from: top, count: regionHeight)
        let new = signatures(of: current, from: top, count: regionHeight)
        if difference(old, new, shift: 0, rows: regionHeight) < 1.0 { return 0 }

        // Every shift on a sample of the rows, then the few best candidates on all rows.
        let maxShift = regionHeight - minimumOverlap
        var candidates: [(shift: Int, error: Float)] = []
        for shift in 1...maxShift {
            let error = difference(old, new, shift: shift, rows: regionHeight, rowStep: sampleStep)
            candidates.append((shift, error))
        }
        let best = candidates
            .sorted { $0.error < $1.error }
            .prefix(4)
            .map { ($0.shift, difference(old, new, shift: $0.shift, rows: regionHeight)) }
            .min { $0.1 < $1.1 }
        guard let best, best.1 < 6 else { return nil }
        return best.0
    }

    // MARK: Helpers

    private static func rowsEqual(_ a: GrayImage, _ rowA: Int, _ b: GrayImage, _ rowB: Int) -> Bool {
        let startA = rowA * a.width
        let startB = rowB * b.width
        var total = 0
        for x in stride(from: 0, to: a.width, by: 2) {
            total += abs(Int(a.pixels[startA + x]) - Int(b.pixels[startB + x]))
        }
        return Double(total) / Double((a.width + 1) / 2) < 1.5
    }

    /// Band averages for `count` rows starting at `start`.
    private static func signatures(of image: GrayImage, from start: Int, count: Int) -> [Float] {
        let bandWidth = max(1, image.width / bands)
        var result = [Float](repeating: 0, count: count * bands)
        for row in 0..<count {
            let offset = (start + row) * image.width
            for band in 0..<bands {
                let from = band * bandWidth
                let to = band == bands - 1 ? image.width : min(image.width, from + bandWidth)
                guard to > from else { continue }
                var sum = 0
                for x in from..<to { sum += Int(image.pixels[offset + x]) }
                result[row * bands + band] = Float(sum) / Float(to - from)
            }
        }
        return result
    }

    /// Mean difference between `old` shifted up by `shift` rows and `new`, over the rows they share.
    private static func difference(_ old: [Float], _ new: [Float], shift: Int, rows: Int, rowStep: Int = 1) -> Float {
        let overlap = rows - shift
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        var total: Float = 0
        var count = 0
        for row in stride(from: 0, to: overlap, by: rowStep) {
            let a = (row + shift) * bands
            let b = row * bands
            for band in 0..<bands {
                total += abs(old[a + band] - new[b + band])
            }
            count += bands
        }
        return total / Float(max(count, 1))
    }
}
