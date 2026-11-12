import AppKit
@preconcurrency import AVFoundation
import SkljocCore

/// The video editor's state: playback, trim, export settings, volumes and keyframed redactions, with undo.
@MainActor
final class VideoEditorModel: ObservableObject {
    let recording: Recording
    let player: AVPlayer

    @Published private(set) var edit: VideoEdit
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var isRedactTool = true
    @Published private(set) var redactStyle: RedactStyle = .pixelate
    @Published var selectedRedactionID: UUID? {
        didSet { if oldValue != selectedRedactionID { selectedKeyframe = nil } }
    }
    @Published var selectedKeyframe: Int?

    let redactionSource: RedactionSource
    private let item: AVPlayerItem
    private var history = History<VideoEdit>()
    private var liveChangeStart: VideoEdit?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var audioTracks: [AVAssetTrack] = []

    init(recording: Recording) {
        self.recording = recording
        edit = recording.edit
        redactionSource = RedactionSource(recording.edit.redactions)
        item = AVPlayerItem(asset: recording.asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
    }

    var duration: Double { recording.duration }
    var frameDuration: Double { 1 / max(recording.frameRate, 1) }
    var selectedRedaction: VideoRedaction? { edit.redactions.first { $0.id == selectedRedactionID } }

    func prepare() async {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
        do {
            item.videoComposition = try await VideoExportEngine.makeVideoComposition(
                for: recording.asset, redactions: redactionSource, timeOffset: 0,
                renderSize: recording.naturalSize, frameRate: recording.frameRate
            )
            audioTracks = try await recording.asset.loadTracks(withMediaType: .audio)
        } catch {
            NSLog("Skljoc: could not prepare the editor preview: \(error.localizedDescription)")
        }
        applyPlaybackSettings()
        seek(to: edit.trimStart)
        await loadThumbnails()
    }

    func tearDown() {
        recording.saveEdits()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
            return
        }
        if currentTime >= edit.trimEnd - 0.05 || currentTime < edit.trimStart {
            seek(to: edit.trimStart)
        }
        player.play()
    }

    func pause() { player.pause() }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    func step(seconds: Double) {
        pause()
        seek(to: currentTime + seconds)
    }

    // MARK: Export settings and trim

    func setResolution(_ resolution: ExportResolution) { change { $0.resolution = resolution } }
    func setFormat(_ format: RecordingFormat) { change { $0.format = format } }
    /// Slider updates; `endLiveChange()` records them as one undo step.
    func setSystemVolumeLive(_ volume: Double) {
        beginLiveChange()
        edit.systemVolume = volume
        edit.systemMuted = false
        editChanged()
    }

    func setMicrophoneVolumeLive(_ volume: Double) {
        beginLiveChange()
        edit.microphoneVolume = volume
        edit.microphoneMuted = false
        editChanged()
    }
    func toggleSystemMuted() { change { $0.systemMuted.toggle() } }
    func toggleMicrophoneMuted() { change { $0.microphoneMuted.toggle() } }

    func setTrimStartLive(_ time: Double) {
        beginLiveChange()
        edit.setTrimStart(time)
        editChanged()
        seek(to: edit.trimStart)
    }

    func setTrimEndLive(_ time: Double) {
        beginLiveChange()
        edit.setTrimEnd(time)
        editChanged()
        seek(to: edit.trimEnd)
    }

    // MARK: Redactions

    func setRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        guard var redaction = selectedRedaction else { return }
        redaction.style = style
        change { $0.update(redaction) }
    }

    /// Covers the whole video by default, so nothing leaks before the moment it was drawn;
    /// the bar ends in the timeline narrow it down. The first keyframe sits at the current moment.
    func addRedactionLive(rect: CGRect) -> UUID {
        beginLiveChange()
        let redaction = VideoRedaction(style: redactStyle, start: 0, end: duration, rect: rect, keyframeTime: currentTime)
        edit.redactions.append(redaction)
        selectedRedactionID = redaction.id
        editChanged()
        return redaction.id
    }

    /// Moving or resizing at a new moment adds a keyframe there.
    func setRedactionRectLive(_ id: UUID, rect: CGRect) {
        guard var redaction = edit.redactions.first(where: { $0.id == id }) else { return }
        beginLiveChange()
        redaction.setRect(rect, at: currentTime, tolerance: frameDuration / 2)
        edit.update(redaction)
        selectedKeyframe = redaction.keyframeIndex(near: currentTime, tolerance: frameDuration / 2)
        editChanged()
    }

    func setRedactionRangeLive(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard var redaction = edit.redactions.first(where: { $0.id == id }) else { return }
        beginLiveChange()
        if let start { redaction.start = min(max(0, start), redaction.end - frameDuration) }
        if let end { redaction.end = max(min(duration, end), redaction.start + frameDuration) }
        edit.update(redaction)
        editChanged()
    }

    func selectKeyframe(_ index: Int, of id: UUID) {
        selectedRedactionID = id
        selectedKeyframe = index
        if let redaction = selectedRedaction, redaction.keyframes.indices.contains(index) {
            pause()
            seek(to: redaction.keyframes[index].time)
        }
    }

    /// Deletes the selected keyframe, or the whole redaction when no keyframe (or only one) is selected.
    func deleteSelection() {
        guard var redaction = selectedRedaction else { return }
        if let index = selectedKeyframe, redaction.removeKeyframe(at: index) {
            change { $0.update(redaction) }
            selectedKeyframe = nil
        } else {
            change { $0.removeRedaction(id: redaction.id) }
            selectedRedactionID = nil
        }
    }

    // MARK: History

    func beginLiveChange() {
        if liveChangeStart == nil { liveChangeStart = edit }
    }

    func endLiveChange() {
        guard let start = liveChangeStart else { return }
        liveChangeStart = nil
        if start != edit {
            history.record(start)
            syncHistory()
        }
    }

    func undo() {
        endLiveChange()
        guard let previous = history.undo(from: edit) else { return }
        edit = previous
        afterHistoryJump()
    }

    func redo() {
        endLiveChange()
        guard let next = history.redo(from: edit) else { return }
        edit = next
        afterHistoryJump()
    }

    private func change(_ body: (inout VideoEdit) -> Void) {
        let previous = edit
        body(&edit)
        guard previous != edit else { return }
        history.record(previous)
        syncHistory()
        editChanged()
    }

    private func afterHistoryJump() {
        if let id = selectedRedactionID, !edit.redactions.contains(where: { $0.id == id }) { selectedRedactionID = nil }
        syncHistory()
        editChanged()
    }

    /// Runs after every finished change, so this is also where edits are saved to disk.
    private func syncHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        recording.saveEdits()
    }

    private func editChanged() {
        recording.edit = edit
        redactionSource.update(edit.redactions)
        applyPlaybackSettings()
        if !isPlaying {
            // Re-renders the paused frame with the new redactions.
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func applyPlaybackSettings() {
        item.forwardPlaybackEndTime = CMTime(seconds: edit.trimEnd, preferredTimescale: 600)
        if !audioTracks.isEmpty {
            item.audioMix = VideoExportEngine.audioMix(for: audioTracks, info: recording.info, edit: edit)
        }
    }

    private func loadThumbnails() async {
        let count = 14
        let generator = AVAssetImageGenerator(asset: recording.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [NSImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
            }
        }
        thumbnails = images
    }
}
