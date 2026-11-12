import AppKit
import CoreImage
import SkljocCore

/// Draws a screenshot with its annotations, both on screen and when exporting.
/// All drawing happens in image points with a top-left origin.
@MainActor
final class AnnotationRenderer {
    private let image: CGImage
    private let scale: CGFloat
    private var imageSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    private static let ciContext = CIContext(options: nil)

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    private lazy var pixelated: CGImage? = filtered { input in
        input.applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: 10 * self.scale,
            kCIInputCenterKey: CIVector(x: 0, y: 0),
        ])
    }

    private lazy var blurred: CGImage? = filtered { input in
        input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14 * self.scale])
    }

    /// Draws into a context whose coordinates are image points, y pointing down.
    func draw(_ document: EditorDocument, in context: CGContext, excluding excludedID: UUID? = nil) {
        drawImage(image, in: context)
        let annotations = document.drawingOrder.filter { $0.id != excludedID }

        for annotation in annotations where annotation.kind == .redact {
            drawRedaction(annotation, in: context)
        }
        drawSpotlights(annotations.filter { $0.kind == .spotlight }, bounds: document.imageBounds, in: context)
        for annotation in annotations where annotation.kind != .redact && annotation.kind != .spotlight {
            drawShape(annotation, in: context)
        }
    }

    /// The visible (cropped) part of the document as an image with `scale` pixels per point.
    func export(_ document: EditorDocument, scale: CGFloat) -> CGImage? {
        let visible = document.visibleRect
        let width = Int((visible.width * scale).rounded())
        let height = Int((visible.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        withGraphicsContext(context) { draw(document, in: context) }
        return context.makeImage()
    }

    private func drawImage(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
    }

    private func drawRedaction(_ annotation: Annotation, in context: CGContext) {
        let rect = annotation.rect
        context.saveGState()
        context.clip(to: rect)
        switch annotation.redactStyle {
        case .pixelate:
            if let pixelated { drawImage(pixelated, in: context) } else { fill(rect, .black, in: context) }
        case .blur:
            if let blurred { drawImage(blurred, in: context) } else { fill(rect, .black, in: context) }
        case .solid:
            fill(rect, .black, in: context)
        }
        context.restoreGState()
    }

    private func drawSpotlights(_ spotlights: [Annotation], bounds: CGRect, in context: CGContext) {
        guard !spotlights.isEmpty else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fill(bounds)
        context.setBlendMode(.clear)
        for spotlight in spotlights {
            switch spotlight.spotlightShape {
            case .rectangle:
                context.addPath(CGPath(roundedRect: spotlight.rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            case .ellipse:
                context.addEllipse(in: spotlight.rect)
            }
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawShape(_ annotation: Annotation, in context: CGContext) {
        let color = annotation.color.cgColor
        let lineWidth = annotation.size.lineWidth
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case .rectangle:
            let path = CGPath(roundedRect: annotation.rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(path)
            annotation.filled ? context.fillPath() : context.strokePath()
        case .oval:
            context.addEllipse(in: annotation.rect)
            annotation.filled ? context.fillPath() : context.strokePath()
        case .line:
            context.move(to: annotation.start)
            context.addLine(to: annotation.end)
            context.strokePath()
        case .arrow:
            drawArrow(annotation, in: context)
        case .text:
            withGraphicsContext(context) { TextLayout.draw(annotation) }
        case .redact, .spotlight:
            break
        }
        context.restoreGState()
    }

    private func drawArrow(_ annotation: Annotation, in context: CGContext) {
        let head = Geometry.arrowHead(from: annotation.start, to: annotation.end, lineWidth: annotation.size.lineWidth)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.move(to: annotation.start)
        context.addLine(to: head.base)
        context.strokePath()
        context.move(to: head.tip)
        context.addLine(to: head.left)
        context.addLine(to: head.right)
        context.closePath()
        context.setLineWidth(max(1, annotation.size.lineWidth / 2))
        context.drawPath(using: .fillStroke)
        context.endTransparencyLayer()
    }

    private func fill(_ rect: CGRect, _ color: RGBAColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    private func filtered(_ transform: (CIImage) -> CIImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = transform(input).cropped(to: input.extent)
        return Self.ciContext.createCGImage(output, from: input.extent)
    }

    private func withGraphicsContext(_ context: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }
}

extension RGBAColor {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .red
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}
