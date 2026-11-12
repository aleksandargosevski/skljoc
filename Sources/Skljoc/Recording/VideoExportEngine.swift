@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import SkljocCore
import UniformTypeIdentifiers

enum VideoExportError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    case gifFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video track."
        case .exportFailed(let reason): "Could not export the video: \(reason)"
        case .gifFailed: "Could not create the GIF."
        }
    }
}

/// The redactions to draw at a moment, read from any thread while the editor changes them.
final class RedactionSource: @unchecked Sendable {
    private let lock = NSLock()
    private var redactions: [VideoRedaction]

    init(_ redactions: [VideoRedaction] = []) {
        self.redactions = redactions
    }

    func update(_ redactions: [VideoRedaction]) {
        lock.withLock { self.redactions = redactions }
    }

    func active(at time: Double) -> [(style: RedactStyle, rect: CGRect)] {
        let current = lock.withLock { redactions }
        return current.compactMap { redaction in redaction.rect(at: time).map { (redaction.style, $0) } }
    }
}

/// Everything needed to export a recording, safe to hand to background work.
struct VideoExportRequest: Sendable {
    var sourceURL: URL
    var info: RecordingInfo
    var edit: VideoEdit
    var naturalSize: CGSize
    var codec: VideoCodec
    var frameRate: Double
    var gifFrameRate: Int
    var gifMaxWidth: Int
}

enum VideoExportEngine {
    static func export(_ request: VideoExportRequest, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        switch request.edit.format {
        case .video:
            if request.edit.needsRendering {
                try await exportVideo(request, to: url)
            } else {
                try FileManager.default.copyItem(at: request.sourceURL, to: url)
            }
        case .gif:
            try await exportGIF(request, to: url)
        }
    }

    // MARK: Building blocks shared with the editor's player

    /// Pixelates, blurs or blacks out the redacted areas. Rects are normalized with a top-left origin.
    static func applyRedactions(_ redactions: [(style: RedactStyle, rect: CGRect)], to image: CIImage) -> CIImage {
        guard !redactions.isEmpty else { return image }
        let extent = image.extent
        var output = image
        for redaction in redactions {
            let rect = CGRect(
                x: extent.minX + redaction.rect.minX * extent.width,
                y: extent.minY + (1 - redaction.rect.maxY) * extent.height,
                width: redaction.rect.width * extent.width,
                height: redaction.rect.height * extent.height
            ).integral
            let covered: CIImage
            switch redaction.style {
            case .pixelate:
                let blockSize = max(10, min(extent.width, extent.height) / 40)
                covered = image.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: blockSize,
                    kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                ])
            case .blur:
                covered = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(10, min(extent.width, extent.height) / 50),
                ])
            case .solid:
                covered = CIImage(color: .black)
            }
            output = covered.cropped(to: rect).composited(over: output)
        }
        return output.cropped(to: extent)
    }

    /// A video composition that applies the redactions (with `timeOffset` added to its own time) and scales to `renderSize`.
    static func makeVideoComposition(
        for asset: AVAsset,
        redactions: RedactionSource,
        timeOffset: Double,
        renderSize: CGSize,
        frameRate: Double
    ) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            let time = request.compositionTime.seconds + timeOffset
            var image = applyRedactions(redactions.active(at: time), to: source)
            let extent = source.extent
            if extent.width > 0, extent.height > 0, extent.size != renderSize {
                image = image.transformed(by: CGAffineTransform(scaleX: renderSize.width / extent.width, y: renderSize.height / extent.height))
            }
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: renderSize)), context: nil)
        }
        let mutable = composition.mutableCopy() as! AVMutableVideoComposition
        mutable.renderSize = renderSize
        mutable.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        return mutable
    }

    /// Volume per audio track: Mac sound first, then the microphone, matching how they were recorded.
    static func audioMix(for tracks: [AVAssetTrack], info: RecordingInfo, edit: VideoEdit) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(tracks, roles(for: info)).map { track, role in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(role == .system ? edit.effectiveSystemVolume : edit.effectiveMicrophoneVolume, at: .zero)
            return parameters
        }
        return mix
    }

    enum AudioRole { case system, microphone }

    static func roles(for info: RecordingInfo) -> [AudioRole] {
        (info.hasSystemAudio ? [AudioRole.system] : []) + (info.hasMicrophone ? [.microphone] : [])
    }

    // MARK: Video

    private static func exportVideo(_ request: VideoExportRequest, to url: URL) async throws {
        let asset = AVURLAsset(url: request.sourceURL)
        let edit = request.edit
        let range = CMTimeRange(
            start: CMTime(seconds: edit.trimStart, preferredTimescale: 600),
            end: CMTime(seconds: edit.trimEnd, preferredTimescale: 600)
        )
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw VideoExportError.noVideoTrack }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoExportError.noVideoTrack
        }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)

        var audioTracks: [AVAssetTrack] = []
        var audioRoles: [AudioRole] = []
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        for (track, role) in zip(sourceAudio, roles(for: request.info)) {
            let volume = role == .system ? edit.effectiveSystemVolume : edit.effectiveMicrophoneVolume
            guard volume > 0,
                  let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: .zero)
            audioTracks.append(compositionTrack)
            audioRoles.append(role)
        }

        let renderSize = edit.resolution.size(for: request.naturalSize)
        let videoComposition = try await makeVideoComposition(
            for: composition,
            redactions: RedactionSource(edit.redactions),
            timeOffset: edit.trimStart,
            renderSize: renderSize,
            frameRate: request.frameRate
        )

        let preset = request.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoExportError.exportFailed("the export preset isn't available")
        }
        session.videoComposition = videoComposition
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = zip(audioTracks, audioRoles).map { track, role in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(role == .system ? edit.effectiveSystemVolume : edit.effectiveMicrophoneVolume, at: .zero)
                return parameters
            }
            session.audioMix = mix
        }
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw VideoExportError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: GIF

    private static func exportGIF(_ request: VideoExportRequest, to url: URL) async throws {
        let asset = AVURLAsset(url: request.sourceURL)
        let edit = request.edit
        let fps = Double(max(1, request.gifFrameRate))
        let resolutionSize = edit.resolution.size(for: request.naturalSize)
        let size = SelectionMath.gifSize(for: resolutionSize, maxWidth: CGFloat(request.gifMaxWidth))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.videoComposition = try await makeVideoComposition(
            for: asset, redactions: RedactionSource(edit.redactions), timeOffset: 0, renderSize: size, frameRate: fps
        )

        let times = stride(from: edit.trimStart, to: edit.trimEnd, by: 1 / fps).map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw VideoExportError.gifFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
            ],
        ] as CFDictionary

        for await result in generator.images(for: times) {
            do {
                CGImageDestinationAddImage(destination, try result.image, frameProperties)
            } catch {
                NSLog("Skljoc: skipped a GIF frame: \(error.localizedDescription)")
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw VideoExportError.gifFailed }
    }
}
