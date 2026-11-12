import CoreGraphics
import Foundation

/// One object drawn on top of a screenshot. Coordinates are in image points with a top-left origin.
public struct Annotation: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case rectangle, oval, line, arrow, text, redact, spotlight
    }

    public let id: UUID
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    public var size: StrokeSize
    public var filled: Bool
    public var text: String
    public var textStyle: TextStyle
    public var redactStyle: RedactStyle
    public var spotlightShape: SpotlightShape

    public init(
        id: UUID = UUID(),
        kind: Kind,
        start: CGPoint,
        end: CGPoint,
        color: RGBAColor = .red,
        size: StrokeSize = .medium,
        filled: Bool = false,
        text: String = "",
        textStyle: TextStyle = .outlined,
        redactStyle: RedactStyle = .pixelate,
        spotlightShape: SpotlightShape = .rectangle
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.size = size
        self.filled = filled
        self.text = text
        self.textStyle = textStyle
        self.redactStyle = redactStyle
        self.spotlightShape = spotlightShape
    }

    public var rect: CGRect { Geometry.rect(from: start, to: end) }

    public var isSegment: Bool { kind == .line || kind == .arrow }

    /// Shapes this small are treated as accidental clicks and discarded.
    public var isTooSmall: Bool {
        if kind == .text { return false }
        if isSegment { return hypot(end.x - start.x, end.y - start.y) < 4 }
        return rect.width < 4 || rect.height < 4
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let reach = tolerance + size.lineWidth / 2
        switch kind {
        case .line, .arrow:
            return Geometry.distance(from: point, toSegmentFrom: start, to: end) <= reach
        case .rectangle where !filled:
            return rect.insetBy(dx: -reach, dy: -reach).contains(point)
                && !rect.insetBy(dx: reach, dy: reach).contains(point)
        case .oval where !filled:
            return Geometry.isNearEllipseOutline(point, in: rect, tolerance: reach)
        case .oval:
            return Geometry.ellipse(rect.insetBy(dx: -reach, dy: -reach), contains: point)
        case .rectangle, .text, .redact, .spotlight:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public var handles: [Handle: CGPoint] {
        switch kind {
        case .line, .arrow: return [.start: start, .end: end]
        case .text: return [:]
        default: return Handle.points(of: rect)
        }
    }

    public func resized(_ handle: Handle, to point: CGPoint) -> Annotation {
        var copy = self
        switch handle {
        case .start: copy.start = point
        case .end: copy.end = point
        default:
            let resized = Geometry.resize(rect, handle: handle, to: point)
            copy.start = resized.origin
            copy.end = CGPoint(x: resized.maxX, y: resized.maxY)
        }
        return copy
    }

    public func moved(by delta: CGVector) -> Annotation {
        var copy = self
        copy.start = CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)
        copy.end = CGPoint(x: end.x + delta.dx, y: end.y + delta.dy)
        return copy
    }
}

public enum Handle: Hashable, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end

    public static func points(of rect: CGRect) -> [Handle: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.minY),
            .top: CGPoint(x: rect.midX, y: rect.minY),
            .topRight: CGPoint(x: rect.maxX, y: rect.minY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .bottom: CGPoint(x: rect.midX, y: rect.maxY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .left: CGPoint(x: rect.minX, y: rect.midY),
        ]
    }
}

public enum StrokeSize: String, CaseIterable, Codable, Sendable {
    case small, medium, large

    public var lineWidth: CGFloat {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 7
        }
    }

    public var fontSize: CGFloat {
        switch self {
        case .small: 16
        case .medium: 24
        case .large: 36
        }
    }
}

public enum TextStyle: String, CaseIterable, Codable, Sendable {
    case outlined, pill
}

public enum RedactStyle: String, CaseIterable, Codable, Sendable {
    case pixelate, blur, solid
}

public enum SpotlightShape: String, CaseIterable, Codable, Sendable {
    case rectangle, ellipse
}

public struct RGBAColor: Equatable, Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Relative luminance, used to pick black or white text on top of this color.
    public var isLight: Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6
    }

    public static let red = RGBAColor(hex: 0xFF3B30)
    public static let orange = RGBAColor(hex: 0xFF9500)
    public static let yellow = RGBAColor(hex: 0xFFCC00)
    public static let green = RGBAColor(hex: 0x34C759)
    public static let blue = RGBAColor(hex: 0x0A84FF)
    public static let purple = RGBAColor(hex: 0xAF52DE)
    public static let black = RGBAColor(hex: 0x000000)
    public static let white = RGBAColor(hex: 0xFFFFFF)

    public static let presets: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}
