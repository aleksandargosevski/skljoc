import AppKit
import AVFoundation
import SwiftUI

/// What a preview card shows.
struct PreviewContent {
    var thumbnail: NSImage
    /// Used for the card's aspect ratio.
    var size: CGSize
    /// "0:42" or "GIF · 0:12" for recordings.
    var badge: String?
    /// Played silently while hovering.
    var videoURL: URL?
}

@MainActor
final class PreviewState: ObservableObject {
    @Published var content: PreviewContent
    @Published var isHovered = false
    /// Shown over the card while something runs, like "Exporting…" or "Uploading 42%".
    @Published var busyText: String?

    init(content: PreviewContent) {
        self.content = content
    }
}

struct PreviewActions {
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var upload: () -> Void
    var edit: () -> Void
    var close: () -> Void
    var dragItem: () -> NSItemProvider
    /// Screenshots only.
    var pin: (() -> Void)?
    var copyText: (() -> Void)?
    var uploadWithOptions: (() -> Void)?
}

/// The floating thumbnail; its actions show on hover, with labels so they are easy to hit.
struct PreviewCardView: View {
    @ObservedObject var state: PreviewState
    let actions: PreviewActions

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            Image(nsImage: state.content.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            if let videoURL = state.content.videoURL, state.isHovered {
                LoopingVideoView(url: videoURL).allowsHitTesting(false)
            }
            if let badge = state.content.badge, !state.isHovered {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
            if let busyText = state.busyText {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busyText).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    }
                }
            } else if state.isHovered {
                hoverOverlay.transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .animation(.easeOut(duration: 0.12), value: state.isHovered)
        .onDrag(actions.dragItem)
        .contextMenu {
            Button("Copy", action: actions.copy)
            if let copyText = actions.copyText { Button("Copy Text", action: copyText) }
            Button("Save", action: actions.save)
            Button("Save As…", action: actions.saveAs)
            Button("Upload", action: actions.upload)
            if let uploadWithOptions = actions.uploadWithOptions { Button("Upload with Options…", action: uploadWithOptions) }
            Button("Edit", action: actions.edit)
            if let pin = actions.pin { Button("Pin to Screen", action: pin) }
            Divider()
            Button("Close", action: actions.close)
        }
    }

    private var hoverOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    Button(action: actions.close) { Label("Close", systemImage: "xmark") }
                    Spacer()
                    Button(action: actions.edit) { Label("Edit", systemImage: "pencil") }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Button(action: actions.copy) { Label("Copy", systemImage: "doc.on.doc") }
                    Button(action: saveOrSaveAs) { Label("Save", systemImage: "square.and.arrow.down") }
                        .help("Option-click to choose where to save")
                }
                .buttonStyle(PillButtonStyle(compact: false))
                Spacer(minLength: 6)
                HStack {
                    Button(action: uploadOrOptions) { Label("Upload", systemImage: "icloud.and.arrow.up") }
                        .help("Upload and copy the link · Option-click for options")
                        .buttonStyle(PillButtonStyle(compact: true))
                    Spacer()
                    Label("Drag", systemImage: "hand.draw")
                        .labelStyle(CompactLabelStyle(iconSize: 9, spacing: 3))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .allowsHitTesting(false)
                    Spacer()
                    if let pin = actions.pin {
                        Button(action: pin) { Label("Pin", systemImage: "pin") }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .help("Keep it on top of all windows")
                    }
                }
            }
            .padding(8)
        }
    }

    private func uploadOrOptions() {
        if NSEvent.modifierFlags.contains(.option), let uploadWithOptions = actions.uploadWithOptions {
            uploadWithOptions()
        } else {
            actions.upload()
        }
    }

    private func saveOrSaveAs() {
        NSEvent.modifierFlags.contains(.option) ? actions.saveAs() : actions.save()
    }
}

/// A muted, looping video for previews.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingPlayerNSView {
        LoopingPlayerNSView(url: url)
    }

    func updateNSView(_ view: LoopingPlayerNSView, context: Context) {}

    static func dismantleNSView(_ view: LoopingPlayerNSView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingPlayerNSView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        player.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func stop() {
        player.pause()
        looper = nil
    }
}

struct PillButtonStyle: ButtonStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(CompactLabelStyle(iconSize: compact ? 9 : 11, spacing: compact ? 4 : 5))
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.leading, compact ? 7 : 11)
            .padding(.trailing, compact ? 9 : 13)
            .frame(height: compact ? 22 : 30)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.7 : 0.95)))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .contentShape(Capsule())
    }
}

/// Icon and title tightly together and centered on one line; the default style leaves a wide gap.
struct CompactLabelStyle: LabelStyle {
    var iconSize: CGFloat
    var spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            configuration.icon
                .font(.system(size: iconSize, weight: .bold))
                .frame(width: iconSize + 3, height: iconSize + 3)
            configuration.title
        }
        .fixedSize()
    }
}
