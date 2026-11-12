import CoreGraphics
import Foundation

/// The "beautify" frame around a screenshot: a fill, padding, rounded corners and a shadow.
public struct ScreenshotBackground: Codable, Equatable, Sendable {
    public enum Fill: Codable, Equatable, Sendable {
        case gradient(Int)
        case solid(RGBAColor)
        case transparent
    }

    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case auto, wide, standard, square

        public var title: String {
            switch self {
            case .auto: "Auto"
            case .wide: "16:9"
            case .standard: "4:3"
            case .square: "1:1"
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .auto: nil
            case .wide: 16.0 / 9.0
            case .standard: 4.0 / 3.0
            case .square: 1
            }
        }
    }

    public var fill: Fill = .gradient(0)
    /// Points around the screenshot.
    public var padding: CGFloat = 48
    public var cornerRadius: CGFloat = 12
    public var shadow = true
    public var shadowStrength: Double = 0.5
    public var aspect: Aspect = .auto

    public init() {}

    /// Top-left and bottom-right colors of the built-in gradients.
    public static let gradients: [(RGBAColor, RGBAColor)] = [
        (RGBAColor(hex: 0x7F5AF0), RGBAColor(hex: 0x2CB1FF)),
        (RGBAColor(hex: 0xFF6A88), RGBAColor(hex: 0xFFB86B)),
        (RGBAColor(hex: 0x0BA360), RGBAColor(hex: 0x3CBA92)),
        (RGBAColor(hex: 0x1E3C72), RGBAColor(hex: 0x2A5298)),
        (RGBAColor(hex: 0xF7971E), RGBAColor(hex: 0xFFD200)),
        (RGBAColor(hex: 0xEC008C), RGBAColor(hex: 0x6A3093)),
        (RGBAColor(hex: 0x232526), RGBAColor(hex: 0x414345)),
        (RGBAColor(hex: 0xE0EAFC), RGBAColor(hex: 0xCFDEF3)),
    ]

    /// The size of the framed image and where the screenshot sits in it, for content of `contentSize`.
    public func layout(for contentSize: CGSize) -> (canvas: CGSize, content: CGRect) {
        var canvas = CGSize(width: contentSize.width + padding * 2, height: contentSize.height + padding * 2)
        if let ratio = aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        let content = CGRect(
            x: (canvas.width - contentSize.width) / 2,
            y: (canvas.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        return (canvas, content)
    }
}
