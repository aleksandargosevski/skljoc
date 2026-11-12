import AppKit
import AVFoundation
import Combine
import SkljocCore

/// The video with its redaction rectangles on top. Drag over the video to add one; drag one to move it,
/// which adds a keyframe at the current moment.
@MainActor
final class VideoCanvasView: NSView {
    private let model: VideoEditorModel
    private let playerLayer = AVPlayerLayer()
    private let overlay: RedactionOverlayView

    init(model: VideoEditorModel) {
        self.model = model
        overlay = RedactionOverlayView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        playerLayer.player = model.player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var keyView: NSView { overlay }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        overlay.frame = bounds
    }
}

@MainActor
private final class RedactionOverlayView: NSView {
    private enum Interaction {
        case creating(start: CGPoint, id: UUID?)
        case moving(id: UUID, startRect: CGRect, startPoint: CGPoint)
        case resizing(id: UUID, handle: Handle, startRect: CGRect)
    }

    private let model: VideoEditorModel
    private var interaction: Interaction?
    private var subscription: AnyCancellable?
    private static let handleRadius: CGFloat = 5

    init(model: VideoEditorModel) {
        self.model = model
        super.init(frame: .zero)
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var videoRect: CGRect {
        AVMakeRect(aspectRatio: model.recording.naturalSize, insideRect: bounds)
    }

    private func viewRect(_ normalized: CGRect) -> CGRect {
        let video = videoRect
        return CGRect(
            x: video.minX + normalized.minX * video.width,
            y: video.minY + normalized.minY * video.height,
            width: normalized.width * video.width,
            height: normalized.height * video.height
        )
    }

    private func normalizedRect(_ rect: CGRect) -> CGRect {
        let video = videoRect
        guard video.width > 0, video.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - video.minX) / video.width,
            y: (rect.minY - video.minY) / video.height,
            width: rect.width / video.width,
            height: rect.height / video.height
        )
    }

    /// Visible redactions at the current moment, topmost last.
    private var visibleRedactions: [(redaction: VideoRedaction, rect: CGRect)] {
        model.edit.redactions.compactMap { redaction in
            redaction.rect(at: model.currentTime).map { (redaction, viewRect($0)) }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (redaction, rect) in visibleRedactions {
            let isSelected = redaction.id == model.selectedRedactionID
            let hasKeyframeHere = redaction.keyframeIndex(near: model.currentTime, tolerance: model.frameDuration / 2) != nil
            context.setStrokeColor(isSelected ? NSColor.controlAccentColor.cgColor : CGColor(gray: 1, alpha: 0.8))
            context.setLineWidth(isSelected ? 2 : 1)
            context.setLineDash(phase: 0, lengths: isSelected && hasKeyframeHere ? [] : [5, 3])
            context.stroke(rect)
            context.setLineDash(phase: 0, lengths: [])
            if isSelected {
                for point in Handle.points(of: rect).values { drawHandle(at: point, in: context) }
            }
        }
    }

    private func drawHandle(at point: CGPoint, in context: CGContext) {
        let radius = Self.handleRadius
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(.white)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect)
    }

    // MARK: Mouse

    override func resetCursorRects() {
        if model.isRedactTool { addCursorRect(videoRect, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        model.pause()
        let point = convert(event.locationInWindow, from: nil)
        let visible = visibleRedactions

        if let selected = visible.first(where: { $0.redaction.id == model.selectedRedactionID }),
           let handle = handle(at: point, of: selected.rect) {
            interaction = .resizing(id: selected.redaction.id, handle: handle, startRect: selected.rect)
            return
        }
        if let hit = visible.last(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }) {
            model.selectedRedactionID = hit.redaction.id
            interaction = .moving(id: hit.redaction.id, startRect: hit.rect, startPoint: point)
            return
        }
        model.selectedRedactionID = nil
        if model.isRedactTool, videoRect.contains(point) {
            interaction = .creating(start: point, id: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let video = videoRect
        switch interaction {
        case .creating(let start, let id):
            let rect = Geometry.clamp(Geometry.rect(from: start, to: point), to: video)
            guard rect.width > 4, rect.height > 4 else { return }
            if let id {
                model.setRedactionRectLive(id, rect: normalizedRect(rect))
            } else {
                let newID = model.addRedactionLive(rect: normalizedRect(rect))
                interaction = .creating(start: start, id: newID)
            }
        case .moving(let id, let startRect, let startPoint):
            let moved = Geometry.slide(startRect.offsetBy(dx: point.x - startPoint.x, dy: point.y - startPoint.y), into: video)
            model.setRedactionRectLive(id, rect: normalizedRect(moved))
        case .resizing(let id, let handle, let startRect):
            let resized = Geometry.clamp(Geometry.resize(startRect, handle: handle, to: point), to: video)
            guard resized.width > 4, resized.height > 4 else { return }
            model.setRedactionRectLive(id, rect: normalizedRect(resized))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        interaction = nil
        model.endLiveChange()
    }

    private func handle(at point: CGPoint, of rect: CGRect) -> Handle? {
        Handle.points(of: rect)
            .filter { hypot($0.value.x - point.x, $0.value.y - point.y) <= Self.handleRadius + 5 }
            .min { hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y) }?
            .key
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = modifiers.contains(.shift)
        switch event.keyCode {
        case 49: model.togglePlay()
        case 123: shift ? model.step(seconds: -1) : model.step(frames: -1)
        case 124: shift ? model.step(seconds: 1) : model.step(frames: 1)
        case 51, 117: model.deleteSelection()
        case 53: model.selectedRedactionID = nil
        default:
            if modifiers.isDisjoint(with: [.command, .control, .option]), event.charactersIgnoringModifiers?.lowercased() == "x" {
                model.isRedactTool.toggle()
                window?.invalidateCursorRects(for: self)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
