import CoreGraphics
import Foundation

/// Presets offered next to the W × H fields of the recording area.
public enum SelectionPreset: Hashable, Sendable, CaseIterable {
    case aspect16x9, aspect4x3, aspect1x1
    case hd1080, hd720, square1080, vertical1080
    case fullscreen

    public var title: String {
        switch self {
        case .aspect16x9: "16:9"
        case .aspect4x3: "4:3"
        case .aspect1x1: "1:1"
        case .hd1080: "1920 × 1080"
        case .hd720: "1280 × 720"
        case .square1080: "1080 × 1080"
        case .vertical1080: "1080 × 1920 (vertical)"
        case .fullscreen: "Full Screen"
        }
    }

    /// Resizes `rect` (points) on a screen with `bounds` and `scale` pixels per point.
    public func apply(to rect: CGRect, bounds: CGRect, scale: CGFloat) -> CGRect {
        switch self {
        case .aspect16x9: SelectionMath.applyingAspect(16.0 / 9.0, to: rect, within: bounds)
        case .aspect4x3: SelectionMath.applyingAspect(4.0 / 3.0, to: rect, within: bounds)
        case .aspect1x1: SelectionMath.applyingAspect(1, to: rect, within: bounds)
        case .hd1080: SelectionMath.resized(rect, toPixels: CGSize(width: 1920, height: 1080), scale: scale, within: bounds)
        case .hd720: SelectionMath.resized(rect, toPixels: CGSize(width: 1280, height: 720), scale: scale, within: bounds)
        case .square1080: SelectionMath.resized(rect, toPixels: CGSize(width: 1080, height: 1080), scale: scale, within: bounds)
        case .vertical1080: SelectionMath.resized(rect, toPixels: CGSize(width: 1080, height: 1920), scale: scale, within: bounds)
        case .fullscreen: bounds
        }
    }
}

public enum SelectionMath {
    /// The size in pixels a recording of `rect` will have. Video encoders need even dimensions.
    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: even(rect.width * scale), height: even(rect.height * scale))
    }

    /// `rect` resized to `pixels`, keeping its center, then kept inside `bounds`.
    public static func resized(_ rect: CGRect, toPixels pixels: CGSize, scale: CGFloat, within bounds: CGRect) -> CGRect {
        let width = min(max(pixels.width / scale, 2), bounds.width)
        let height = min(max(pixels.height / scale, 2), bounds.height)
        let centered = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return Geometry.slide(centered, into: bounds)
    }

    /// Keeps the width (or the height, when the result wouldn't fit) and the center.
    public static func applyingAspect(_ ratio: CGFloat, to rect: CGRect, within bounds: CGRect) -> CGRect {
        var width = rect.width
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        let centered = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return Geometry.slide(centered, into: bounds)
    }

    /// The size of an exported GIF: no wider than `maxWidth`, never upscaled, even dimensions.
    public static func gifSize(for videoSize: CGSize, maxWidth: CGFloat) -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(1, maxWidth / videoSize.width)
        return CGSize(width: even(videoSize.width * scale), height: even(videoSize.height * scale))
    }

    /// "0:42", "12:05" or "1:02:03".
    public static func formatDuration(_ seconds: Double, showsTenths: Bool = false) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(clamped)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var result = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        if showsTenths {
            result += ".\(Int((clamped - Double(total)) * 10))"
        }
        return result
    }

    /// Rounds down to an even number, forgiving floating-point noise like 479.9999.
    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, ((value + 0.001) / 2).rounded(.down) * 2)
    }
}
