import Foundation

public enum RecordingFormat: String, Codable, CaseIterable, Sendable {
    case video, gif

    public var title: String {
        switch self {
        case .video: "Video"
        case .gif: "GIF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .video: "mp4"
        case .gif: "gif"
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc

    public var title: String {
        switch self {
        case .h264: "H.264 (works everywhere)"
        case .hevc: "HEVC (smaller files)"
        }
    }
}

public enum CameraSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var diameter: CGFloat {
        switch self {
        case .small: 120
        case .medium: 180
        case .large: 260
        }
    }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle, roundedRectangle
}

/// What the recording control bar lets you switch on and off. Remembered between recordings.
public struct RecordingOptions: Codable, Equatable, Sendable {
    public var format: RecordingFormat = .video
    public var camera = false
    public var cameraID: String?
    public var cameraSize: CameraSize = .medium
    public var cameraShape: CameraShape = .circle
    public var microphone = false
    public var microphoneID: String?
    public var systemAudio = false
    public var highlightClicks = false
    public var showKeystrokes = false

    public init() {}

    /// GIFs have no sound, so audio is only recorded for video.
    public var recordsSystemAudio: Bool { format == .video && systemAudio }
    public var recordsMicrophone: Bool { format == .video && microphone }
}

/// Stored next to each raw recording, so the editor knows which audio track is which.
public struct RecordingInfo: Codable, Equatable, Sendable {
    public var format: RecordingFormat
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool

    public init(format: RecordingFormat, hasSystemAudio: Bool, hasMicrophone: Bool) {
        self.format = format
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
    }
}
