import SkljocCore
import SwiftUI

struct VideoEditorToolbar: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.isRedactTool.toggle() } label: {
                Label("Redact", systemImage: "checkerboard.rectangle")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.isRedactTool ? Color.accentColor.opacity(0.25) : .clear))
                    .foregroundStyle(model.isRedactTool ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Redact (X): pause, then drag over the video")

            Picker("Style", selection: Binding(get: { model.selectedRedaction?.style ?? model.redactStyle }, set: model.setRedactStyle)) {
                Text("Pixelate").tag(RedactStyle.pixelate)
                Text("Blur").tag(RedactStyle.blur)
                Text("Solid").tag(RedactStyle.solid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            if model.selectedRedaction != nil {
                Button(model.selectedKeyframe != nil && (model.selectedRedaction?.keyframes.count ?? 0) > 1 ? "Delete Keyframe" : "Delete Redaction",
                       action: model.deleteSelection)
            }

            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).disabled(!model.canUndo).help("Undo (⌘Z)")
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).disabled(!model.canRedo).help("Redo (⇧⌘Z)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hint: String {
        if model.selectedRedaction != nil {
            return "Move it at another moment to add a keyframe · drag the bar ends to set when it shows"
        }
        return "Drag over the video to hide something · it follows from keyframe to keyframe"
    }
}

/// Playback, timeline and export settings below the video.
struct VideoEditorBottomBar: View {
    @ObservedObject var model: VideoEditorModel
    var dragItem: () -> NSItemProvider
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var upload: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                Text("\(SelectionMath.formatDuration(model.currentTime, showsTenths: true)) / \(SelectionMath.formatDuration(model.duration, showsTenths: true))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                TimelineView(model: model)
            }

            HStack(spacing: 14) {
                Picker("Format", selection: Binding(get: { model.edit.format }, set: model.setFormat)) {
                    Text("MP4").tag(RecordingFormat.video)
                    Text("GIF").tag(RecordingFormat.gif)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                Picker("Resolution", selection: Binding(get: { model.edit.resolution }, set: model.setResolution)) {
                    ForEach(ExportResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("Export resolution")

                if model.recording.info.hasSystemAudio && model.edit.format == .video {
                    VolumeControl(
                        systemImage: "speaker.wave.2.fill", mutedImage: "speaker.slash.fill", title: "Mac sound",
                        volume: model.edit.systemVolume, muted: model.edit.systemMuted,
                        setVolume: model.setSystemVolumeLive, toggleMute: model.toggleSystemMuted, endChange: model.endLiveChange
                    )
                }
                if model.recording.info.hasMicrophone && model.edit.format == .video {
                    VolumeControl(
                        systemImage: "mic.fill", mutedImage: "mic.slash.fill", title: "Microphone",
                        volume: model.edit.microphoneVolume, muted: model.edit.microphoneMuted,
                        setVolume: model.setMicrophoneVolumeLive, toggleMute: model.toggleMicrophoneMuted, endChange: model.endLiveChange
                    )
                }

                Text("Length \(SelectionMath.formatDuration(model.edit.trimmedDuration, showsTenths: true))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
                Label("Drag", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .contentShape(Rectangle())
                    .onDrag(dragItem)
                    .help("Drag the edited recording into any app")
                Button(action: upload) { Label("Upload", systemImage: "icloud.and.arrow.up") }
                Button(action: { NSEvent.modifierFlags.contains(.option) ? saveAs() : save() }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save (⌘S) · Option-click or ⇧⌘S to choose where")
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy (⌘C)")
                Button(action: done) { Text("Done").frame(minWidth: 50) }
                    .buttonStyle(.borderedProminent)
                    .help("Back to the preview (⌘W)")
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct VolumeControl: View {
    let systemImage: String
    let mutedImage: String
    let title: String
    let volume: Double
    let muted: Bool
    let setVolume: (Double) -> Void
    let toggleMute: () -> Void
    let endChange: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleMute) {
                Image(systemName: muted ? mutedImage : systemImage)
                    .frame(width: 18)
                    .foregroundStyle(muted ? Color.red : .primary)
            }
            .buttonStyle(.plain)
            .help("\(title): \(muted ? "muted" : "on") (click to toggle)")
            Slider(value: Binding(get: { muted ? 0 : volume }, set: setVolume), in: 0...1) { editing in
                if !editing { endChange() }
            }
            .frame(width: 80)
            .help("\(title) volume")
        }
    }
}
