import CoreGraphics
import Foundation

/// A redaction rectangle at one moment. `rect` is normalized: 0…1 of the video's width and height, top-left origin.
public struct RedactionKeyframe: Equatable, Codable, Sendable {
    public var time: Double
    public var rect: CGRect

    public init(time: Double, rect: CGRect) {
        self.time = time
        self.rect = rect
    }
}

/// A redacted area that is visible from `start` to `end` and moves between its keyframes.
public struct VideoRedaction: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var style: RedactStyle
    public var start: Double
    public var end: Double
    public private(set) var keyframes: [RedactionKeyframe]

    /// `keyframeTime` is where the first keyframe goes; it defaults to `start`.
    public init(id: UUID = UUID(), style: RedactStyle = .pixelate, start: Double, end: Double, rect: CGRect, keyframeTime: Double? = nil) {
        self.id = id
        self.style = style
        self.start = start
        self.end = end
        self.keyframes = [RedactionKeyframe(time: keyframeTime ?? start, rect: Self.clampedNormalized(rect))]
    }

    public func isVisible(at time: Double) -> Bool {
        time >= start && time <= end
    }

    /// The rectangle at `time`, or nil while the redaction isn't visible.
    public func rect(at time: Double) -> CGRect? {
        isVisible(at: time) ? interpolatedRect(at: time) : nil
    }

    /// Linear interpolation between the surrounding keyframes; holds the first and last one outside them.
    public func interpolatedRect(at time: Double) -> CGRect {
        guard let first = keyframes.first, let last = keyframes.last else { return .zero }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }
        guard let nextIndex = keyframes.firstIndex(where: { $0.time > time }) else { return last.rect }
        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let progress = CGFloat((time - previous.time) / (next.time - previous.time))
        return CGRect(
            x: previous.rect.minX + (next.rect.minX - previous.rect.minX) * progress,
            y: previous.rect.minY + (next.rect.minY - previous.rect.minY) * progress,
            width: previous.rect.width + (next.rect.width - previous.rect.width) * progress,
            height: previous.rect.height + (next.rect.height - previous.rect.height) * progress
        )
    }

    /// Updates the keyframe at `time` (within `tolerance`) or adds a new one.
    public mutating func setRect(_ rect: CGRect, at time: Double, tolerance: Double = 0.02) {
        let rect = Self.clampedNormalized(rect)
        if let index = keyframeIndex(near: time, tolerance: tolerance) {
            keyframes[index].rect = rect
        } else {
            keyframes.append(RedactionKeyframe(time: time, rect: rect))
            keyframes.sort { $0.time < $1.time }
        }
    }

    public func keyframeIndex(near time: Double, tolerance: Double = 0.02) -> Int? {
        keyframes.indices
            .filter { abs(keyframes[$0].time - time) <= tolerance }
            .min { abs(keyframes[$0].time - time) < abs(keyframes[$1].time - time) }
    }

    /// Removes a keyframe; the last one stays, since a redaction needs a position.
    @discardableResult
    public mutating func removeKeyframe(at index: Int) -> Bool {
        guard keyframes.count > 1, keyframes.indices.contains(index) else { return false }
        keyframes.remove(at: index)
        return true
    }

    public mutating func moveKeyframe(at index: Int, to time: Double) {
        guard keyframes.indices.contains(index) else { return }
        keyframes[index].time = time
        keyframes.sort { $0.time < $1.time }
    }

    static func clampedNormalized(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let width = min(max(standardized.width, 0.005), 1)
        let height = min(max(standardized.height, 0.005), 1)
        let x = min(max(standardized.minX, 0), 1 - width)
        let y = min(max(standardized.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum ExportResolution: String, CaseIterable, Codable, Sendable {
    case original, p1080, p720, p480

    public var title: String {
        switch self {
        case .original: "Original"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    private var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    /// The output size for a `source` video: the shorter side becomes the preset, never upscaled, even dimensions.
    public func size(for source: CGSize) -> CGSize {
        guard let shortSide, source.width > 0, source.height > 0 else { return source }
        let scale = min(1, shortSide / min(source.width, source.height))
        return CGSize(
            width: max(2, (source.width * scale / 2).rounded() * 2),
            height: max(2, (source.height * scale / 2).rounded() * 2)
        )
    }
}

/// Everything the video editor changes. The recording itself stays untouched until export.
public struct VideoEdit: Equatable, Codable, Sendable {
    public static let minimumLength = 0.1

    public let duration: Double
    public private(set) var trimStart: Double
    public private(set) var trimEnd: Double
    public var resolution: ExportResolution = .original
    public var format: RecordingFormat
    public var systemVolume: Double = 1
    public var microphoneVolume: Double = 1
    public var systemMuted = false
    public var microphoneMuted = false
    public var redactions: [VideoRedaction] = []

    public init(duration: Double, format: RecordingFormat) {
        self.duration = max(duration, 0)
        self.trimStart = 0
        self.trimEnd = max(duration, 0)
        self.format = format
    }

    public var trimmedDuration: Double { trimEnd - trimStart }

    public var isTrimmed: Bool { trimStart > 0.001 || trimEnd < duration - 0.001 }

    /// True when exporting needs more than copying the recorded file.
    public var needsRendering: Bool {
        isTrimmed || resolution != .original || !redactions.isEmpty
            || systemMuted || microphoneMuted || systemVolume < 0.999 || microphoneVolume < 0.999
    }

    public var effectiveSystemVolume: Float { systemMuted ? 0 : Float(systemVolume) }
    public var effectiveMicrophoneVolume: Float { microphoneMuted ? 0 : Float(microphoneVolume) }

    public mutating func setTrimStart(_ value: Double) {
        trimStart = min(max(value, 0), trimEnd - Self.minimumLength)
    }

    public mutating func setTrimEnd(_ value: Double) {
        trimEnd = max(min(value, duration), trimStart + Self.minimumLength)
    }

    public mutating func update(_ redaction: VideoRedaction) {
        guard let index = redactions.firstIndex(where: { $0.id == redaction.id }) else { return }
        redactions[index] = redaction
    }

    public mutating func removeRedaction(id: UUID) {
        redactions.removeAll { $0.id == id }
    }

    /// Normalized rectangles to redact at `time`, for preview and export.
    public func activeRedactions(at time: Double) -> [(style: RedactStyle, rect: CGRect)] {
        redactions.compactMap { redaction in
            redaction.rect(at: time).map { (redaction.style, $0) }
        }
    }
}
