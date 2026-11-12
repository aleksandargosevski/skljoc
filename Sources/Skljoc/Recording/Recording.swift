import AppKit
@preconcurrency import AVFoundation
import SkljocCore

enum RecordingLoadError: LocalizedError {
    case noVideo(URL)

    var errorDescription: String? {
        switch self {
        case .noVideo(let url): "The recording at \(url.path) has no video."
        }
    }
}

/// A screen recording and the edits made to it. The recorded file stays untouched.
@MainActor
final class Recording: Identifiable {
    let id = UUID()
    let fileURL: URL
    let info: RecordingInfo
    let createdAt: Date
    let duration: Double
    /// Pixels.
    let naturalSize: CGSize
    let frameRate: Double
    var thumbnail: NSImage
    var edit: VideoEdit

    private init(fileURL: URL, info: RecordingInfo, createdAt: Date, duration: Double, naturalSize: CGSize, frameRate: Double, thumbnail: NSImage) {
        self.fileURL = fileURL
        self.info = info
        self.createdAt = createdAt
        self.duration = duration
        self.naturalSize = naturalSize
        self.frameRate = frameRate
        self.thumbnail = thumbnail
        let saved = MediaFiles.read(VideoEdit.self, from: MediaFiles.editsURL(for: fileURL))
        self.edit = saved.flatMap { abs($0.duration - duration) < 0.01 ? $0 : nil } ?? VideoEdit(duration: duration, format: info.format)
    }

    /// Keeps trim, redactions and export settings next to the file, so they survive a restart.
    func saveEdits() {
        let pristine = VideoEdit(duration: duration, format: info.format)
        do {
            try MediaFiles.write(edit == pristine ? nil : edit, to: MediaFiles.editsURL(for: fileURL))
        } catch {
            NSLog("Skljoc: could not save recording edits: \(error.localizedDescription)")
        }
    }

    static func load(fileURL: URL, createdAt: Date = Date()) async throws -> Recording {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingLoadError.noVideo(fileURL)
        }
        let (size, frameRate) = try await track.load(.naturalSize, .nominalFrameRate)
        let info = loadInfo(for: fileURL)
        let thumbnail = await makeThumbnail(asset: asset, size: size)
        return Recording(
            fileURL: fileURL, info: info, createdAt: createdAt, duration: duration,
            naturalSize: size, frameRate: Double(frameRate > 0 ? frameRate : 30), thumbnail: thumbnail
        )
    }

    var asset: AVURLAsset { AVURLAsset(url: fileURL) }

    /// Shown on the preview: "GIF · 0:12" or "0:42".
    var badge: String {
        let length = SelectionMath.formatDuration(edit.trimmedDuration)
        return edit.format == .gif ? "GIF · \(length)" : length
    }

    static func infoURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("json")
    }

    static func saveInfo(_ info: RecordingInfo, for fileURL: URL) throws {
        try JSONEncoder().encode(info).write(to: infoURL(for: fileURL), options: .atomic)
    }

    private static func loadInfo(for fileURL: URL) -> RecordingInfo {
        guard let data = try? Data(contentsOf: infoURL(for: fileURL)),
              let info = try? JSONDecoder().decode(RecordingInfo.self, from: data) else {
            return RecordingInfo(format: .video, hasSystemAudio: false, hasMicrophone: false)
        }
        return info
    }

    /// The first frame of an exported file: a video, or a GIF.
    static func thumbnail(ofExport url: URL) async -> NSImage? {
        if url.pathExtension.lowercased() == "gif" {
            return NSImage(contentsOf: url)
        }
        let asset = AVURLAsset(url: url)
        guard let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) else { return nil }
        return await makeThumbnail(asset: asset, size: size)
    }

    private static func makeThumbnail(asset: AVAsset, size: CGSize) async -> NSImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        } catch {
            NSLog("Skljoc: could not make a thumbnail: \(error.localizedDescription)")
            let placeholder = NSImage(size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
            return placeholder
        }
    }
}
