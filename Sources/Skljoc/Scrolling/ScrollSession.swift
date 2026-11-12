import CoreGraphics
import SkljocCore

/// Collects the frames of a scrolling capture and stitches the new rows of each one onto the result.
actor ScrollSession {
    struct Update: Sendable {
        var moved: Bool
        var lostTrack: Bool
        var reachedLimit: Bool
        var height: Int
        /// The stitched result so far, small enough for the live preview.
        var preview: [CGImage]
    }

    static let maxHeight = 30_000
    private static let grayWidth = 240
    private static let previewWidth = 150

    private var first: CGImage?
    private var last: CGImage?
    private var previousGray: GrayImage?
    private var edges: (top: Int, bottom: Int)?
    private var strips: [CGImage] = []
    private var previewStrips: [CGImage] = []
    private var height = 0

    func add(_ frame: CGImage) -> Update {
        let gray = Self.gray(frame)
        guard let previousGray, let first else {
            self.first = frame
            last = frame
            self.previousGray = gray
            height = frame.height
            previewStrips = [Self.scaled(frame)].compactMap { $0 }
            return update(moved: false, lostTrack: false)
        }
        guard first.width == frame.width, first.height == frame.height else {
            return update(moved: false, lostTrack: true)
        }

        if edges == nil {
            let found = ScrollStitcher.fixedEdges(previousGray, gray)
            // Nearly everything equal means the page hasn't moved yet, so the edges aren't known.
            if found.top + found.bottom > Int(Double(frame.height) * 0.7) {
                return update(moved: false, lostTrack: false)
            }
            edges = found
        }
        guard let edges else { return update(moved: false, lostTrack: false) }

        guard let offset = ScrollStitcher.scrollOffset(from: previousGray, to: gray, top: edges.top, bottom: edges.bottom) else {
            return update(moved: false, lostTrack: true)
        }
        guard offset > 0 else { return update(moved: false, lostTrack: false) }

        let rows = min(offset, Self.maxHeight - height)
        let stripRect = CGRect(x: 0, y: frame.height - edges.bottom - offset, width: frame.width, height: rows)
        if rows > 0, let strip = frame.cropping(to: stripRect) {
            strips.append(strip)
            if let small = Self.scaled(strip) { previewStrips.append(small) }
            height += rows
        }
        self.previousGray = gray
        last = frame
        return update(moved: true, lostTrack: false)
    }

    /// The full-resolution result: the first frame (without its footer), every new strip, then the footer.
    func compose() -> CGImage? {
        guard let first, let last else { return nil }
        let bottom = edges?.bottom ?? 0
        let width = first.width
        let total = (first.height - bottom) + strips.reduce(0) { $0 + $1.height } + bottom
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        var y = 0
        func drawTopDown(_ image: CGImage) {
            context.draw(image, in: CGRect(x: 0, y: total - y - image.height, width: image.width, height: image.height))
            y += image.height
        }
        if let head = first.cropping(to: CGRect(x: 0, y: 0, width: width, height: first.height - bottom)) { drawTopDown(head) }
        strips.forEach(drawTopDown)
        if bottom > 0, let footer = last.cropping(to: CGRect(x: 0, y: last.height - bottom, width: width, height: bottom)) {
            drawTopDown(footer)
        }
        return context.makeImage()
    }

    private func update(moved: Bool, lostTrack: Bool) -> Update {
        Update(moved: moved, lostTrack: lostTrack, reachedLimit: height >= Self.maxHeight, height: height, preview: previewStrips)
    }

    /// Full height, squeezed to a narrow width: rows stay comparable one to one.
    private static func gray(_ image: CGImage) -> GrayImage {
        let width = grayWidth
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    private static func scaled(_ image: CGImage) -> CGImage? {
        let scale = CGFloat(previewWidth) / CGFloat(image.width)
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: previewWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: previewWidth, height: height))
        return context.makeImage()
    }
}
