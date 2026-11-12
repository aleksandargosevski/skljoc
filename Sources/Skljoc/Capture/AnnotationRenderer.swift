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
        for annotation in annotations where annotation.kind == .highlight {
            drawHighlight(annotation, in: context)
        }
        for annotation in annotations where ![.redact, .spotlight, .highlight].contains(annotation.kind) {
            drawShape(annotation, number: document.counterNumber(for: annotation.id), in: context)
        }
    }

    /// The document as an image with `scale` pixels per point: the crop, framed by the background if there is one.
    func export(_ document: EditorDocument, scale: CGFloat) -> CGImage? {
        guard let content = exportContent(document, scale: scale) else { return nil }
        guard let background = document.background else { return content }
        return frame(content, contentSize: document.visibleRect.size, in: background, scale: scale)
    }

    private func exportContent(_ document: EditorDocument, scale: CGFloat) -> CGImage? {
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

    /// Draws the screenshot on the background: fill, shadow, then the image with rounded corners.
    private func frame(_ content: CGImage, contentSize: CGSize, in style: ScreenshotBackground, scale: CGFloat) -> CGImage? {
        let layout = style.layout(for: contentSize)
        let width = Int((layout.canvas.width * scale).rounded())
        let height = Int((layout.canvas.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        let canvas = CGRect(origin: .zero, size: layout.canvas)

        switch style.fill {
        case .gradient(let index):
            let colors = ScreenshotBackground.gradients[min(max(index, 0), ScreenshotBackground.gradients.count - 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1]) {
                // Bottom-left origin here, so top-left to bottom-right runs from maxY to minY.
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: canvas.maxX, y: 0), options: [])
            }
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        case .transparent:
            break
        }

        // Layout is top-left based; flip the content rect into this bottom-left context.
        let rect = CGRect(x: layout.content.minX, y: layout.canvas.height - layout.content.maxY, width: layout.content.width, height: layout.content.height)
        let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow {
            context.saveGState()
            let strength = CGFloat(style.shadowStrength)
            context.setShadow(offset: CGSize(width: 0, height: -8 * strength - 2), blur: 30 * strength + 4, color: CGColor(gray: 0, alpha: 0.25 + 0.35 * strength))
            context.addPath(path)
            context.setFillColor(.white)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(content, in: rect)
        context.restoreGState()
        return context.makeImage()
    }

    private func drawHighlight(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setAlpha(0.45)
        if annotation.isFreehand {
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(annotation.size.highlightWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addLines(between: annotation.points)
            context.strokePath()
        } else {
            context.setFillColor(annotation.color.cgColor)
            context.fill(Geometry.rect(from: annotation.start, to: annotation.end))
        }
        context.restoreGState()
    }

    private func drawCounter(_ annotation: Annotation, number: Int, in context: CGContext) {
        let radius = annotation.size.counterRadius
        let center = annotation.start
        if annotation.hasCounterArrow {
            let angle = atan2(annotation.end.y - center.y, annotation.end.x - center.x)
            let edge = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            var arrow = annotation
            arrow.kind = .arrow
            arrow.start = edge
            context.saveGState()
            context.setLineWidth(annotation.size.lineWidth)
            drawArrow(arrow, in: context)
            context.restoreGState()
        }
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(max(1.5, radius * 0.12))
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))

        withGraphicsContext(context) {
            let font = NSFont.systemFont(ofSize: radius * (number > 9 ? 0.95 : 1.15), weight: .bold)
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: font,
                .foregroundColor: TextLayout.contrastColor(for: annotation.color),
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        }
    }

    private func drawShape(_ annotation: Annotation, number: Int?, in context: CGContext) {
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
        case .counter:
            drawCounter(annotation, number: number ?? 1, in: context)
        case .redact, .spotlight, .highlight:
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
