@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SkljocCore

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The screen to record is no longer available."
        case .writerFailed(let reason): "Could not write the recording: \(reason)"
        case .noFrames: "Nothing was recorded. Try recording a little longer."
        }
    }
}

/// Records part of a display with ScreenCaptureKit into an MP4. Mac sound and the microphone
/// go into separate audio tracks (in that order), so the editor can change them independently.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Configuration {
        var displayID: CGDirectDisplayID
        /// Points from the display's top-left corner.
        var sourceRect: CGRect
        var pixelSize: CGSize
        var frameRate: Int
        var codec: VideoCodec
        var showsCursor: Bool
        var systemAudio: Bool
        var microphoneID: String?
        var excludedWindowIDs: [CGWindowID]
        var outputURL: URL
    }

    /// Called on an arbitrary queue when recording stops because of an error.
    var onFailure: (@Sendable (Error) -> Void)?

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "io.github.aleksandargosevski.skljoc.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?

    // Only touched on `queue`.
    private var isAccepting = false
    private var sessionStarted = false
    private var lastVideoTime = CMTime.invalid
    private var isPaused = false
    private var pauseStartedAt = CMTime.invalid
    private var pausedDuration = CMTime.zero

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw RecorderError.displayNotFound
        }
        let excluded = content.windows.filter { configuration.excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = configuration.sourceRect
        streamConfiguration.width = Int(configuration.pixelSize.width)
        streamConfiguration.height = Int(configuration.pixelSize.height)
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.queueDepth = 6
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        streamConfiguration.capturesAudio = configuration.systemAudio
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        if let microphoneID = configuration.microphoneID {
            streamConfiguration.captureMicrophone = true
            streamConfiguration.microphoneCaptureDeviceID = microphoneID
        }

        try makeWriter()
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.microphoneID != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        queue.sync { isAccepting = true }
        try await stream.startCapture()
    }

    func pause() {
        queue.async {
            guard !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            if self.pauseStartedAt.isValid {
                self.pausedDuration = CMTimeAdd(self.pausedDuration, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), self.pauseStartedAt))
            }
        }
    }

    /// Stops and finishes the file. Returns its URL.
    func stop() async throws -> URL {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream?.stopCapture()
        stream = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.isAccepting = false
                guard let writer = self.writer, self.sessionStarted else {
                    self.writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: self.configuration.outputURL)
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                // The screen may not change for a while before stopping; the video still lasts until now.
                let pausedUntilStop = self.isPaused && self.pauseStartedAt.isValid
                    ? CMTimeAdd(self.pausedDuration, CMTimeSubtract(stopTime, self.pauseStartedAt))
                    : self.pausedDuration
                let end = CMTimeMaximum(self.lastVideoTime, CMTimeSubtract(stopTime, pausedUntilStop))
                [self.videoInput, self.systemAudioInput, self.microphoneInput].forEach { $0?.markAsFinished() }
                writer.endSession(atSourceTime: end)
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: self.configuration.outputURL)
                    } else {
                        continuation.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error"))
                    }
                }
            }
        }
    }

    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {
            isAccepting = false
            writer?.cancelWriting()
        }
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }

    // MARK: Writer

    private func makeWriter() throws {
        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mp4)
        let width = configuration.pixelSize.width
        let height = configuration.pixelSize.height
        let bitRate = Int(width * height * CGFloat(configuration.frameRate) * 0.08)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: min(max(bitRate, 2_000_000), 60_000_000),
            AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
            AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
        ]
        if configuration.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: configuration.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        try add(video, to: writer)
        videoInput = video

        if configuration.systemAudio {
            let input = Self.audioInput(channels: 2, bitRate: 160_000)
            try add(input, to: writer)
            systemAudioInput = input
        }
        if configuration.microphoneID != nil {
            let input = Self.audioInput(channels: 1, bitRate: 96_000)
            try add(input, to: writer)
            microphoneInput = input
        }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "could not start")
        }
        self.writer = writer
    }

    private func add(_ input: AVAssetWriterInput, to writer: AVAssetWriter) throws {
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("unsupported \(input.mediaType.rawValue) settings") }
        writer.add(input)
    }

    private static func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isAccepting, !isPaused, sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            append(sampleBuffer, to: videoInput, isVideo: true)
        case .audio:
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput, isVideo: false)
        case .microphone:
            guard sessionStarted else { return }
            append(sampleBuffer, to: microphoneInput, isVideo: false)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Skljoc: recording stopped: \(error.localizedDescription)")
        onFailure?(error)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, isVideo: Bool) {
        guard let input, input.isReadyForMoreMediaData, let buffer = retimed(sampleBuffer) else { return }
        if input.append(buffer), isVideo {
            lastVideoTime = buffer.presentationTimeStamp
        }
    }

    /// Shifts timestamps back by the time spent paused, so the video has no gap.
    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pausedDuration != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, pausedDuration)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, pausedDuration)
            }
        }
        var output: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &output
        )
        return output
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
