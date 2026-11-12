import AppKit
import SkljocCore

/// Measures and draws text annotations. `start` is the top-left corner of the text box.
enum TextLayout {
    static func font(for size: StrokeSize) -> NSFont {
        .systemFont(ofSize: size.fontSize, weight: .bold)
    }

    static func padding(for annotation: Annotation) -> CGSize {
        let fontSize = annotation.size.fontSize
        switch annotation.textStyle {
        case .pill: return CGSize(width: fontSize * 0.45, height: fontSize * 0.2)
        case .outlined: return CGSize(width: fontSize * 0.12, height: fontSize * 0.05)
        }
    }

    /// The annotation with `end` moved to fit its text, so selection and hit testing match what is drawn.
    static func fitted(_ annotation: Annotation) -> Annotation {
        var copy = annotation
        let textSize = measure(annotation.text.isEmpty ? " " : annotation.text, size: annotation.size)
        let padding = padding(for: annotation)
        copy.end = CGPoint(
            x: annotation.start.x + textSize.width + padding.width * 2,
            y: annotation.start.y + textSize.height + padding.height * 2
        )
        return copy
    }

    static func textOrigin(for annotation: Annotation) -> CGPoint {
        let padding = padding(for: annotation)
        return CGPoint(x: annotation.start.x + padding.width, y: annotation.start.y + padding.height)
    }

    static func contrastColor(for color: RGBAColor) -> NSColor {
        color.isLight ? .black : .white
    }

    /// Draws into the current graphics context, which must be flipped.
    static func draw(_ annotation: Annotation) {
        guard !annotation.text.isEmpty else { return }
        let font = font(for: annotation.size)
        let origin = textOrigin(for: annotation)

        switch annotation.textStyle {
        case .pill:
            let rect = annotation.rect
            let radius = min(rect.height / 2, annotation.size.fontSize * 0.4)
            annotation.color.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: contrastColor(for: annotation.color)]
            NSAttributedString(string: annotation.text, attributes: attributes).draw(at: origin)
        case .outlined:
            let outline: [NSAttributedString.Key: Any] = [
                .font: font,
                .strokeColor: contrastColor(for: annotation.color),
                .strokeWidth: 22,
            ]
            NSGraphicsContext.current?.cgContext.setLineJoin(.round)
            NSAttributedString(string: annotation.text, attributes: outline).draw(at: origin)
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            let fill: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: annotation.color.nsColor]
            NSAttributedString(string: annotation.text, attributes: fill).draw(at: origin)
        }
    }

    private static func measure(_ text: String, size: StrokeSize) -> CGSize {
        let bounds = NSAttributedString(string: text, attributes: [.font: font(for: size)])
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}
