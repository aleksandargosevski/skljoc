import AppKit
import Combine
import SkljocCore

/// Shows the screenshot with its annotations and turns mouse and keyboard input into edits.
/// View coordinates are image points shifted by `origin`, so magnification comes from the scroll view.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    static let margin: CGFloat = 24

    private enum Interaction {
        case creating(id: UUID, start: CGPoint, previous: EditorDocument)
        case moving(id: UUID, last: CGPoint, previous: EditorDocument)
        case resizing(id: UUID, handle: Handle, previous: EditorDocument)
        case cropNew(start: CGPoint)
        case cropMove(startRect: CGRect, startPoint: CGPoint)
        case cropResize(handle: Handle, startRect: CGRect)
        case panning(last: CGPoint)
    }

    private let model: EditorModel
    private var interaction: Interaction?
    private var isSpaceDown = false
    private var textField: NSTextField?
    private var textEditPrevious: EditorDocument?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        updateFrameSize()
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                updateFrameSize()
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The part of the image the canvas shows: everything while cropping, otherwise the crop.
    private var displayedRect: CGRect {
        model.isCropping ? model.document.imageBounds : model.document.visibleRect
    }

    private var origin: CGPoint {
        CGPoint(x: displayedRect.minX - Self.margin, y: displayedRect.minY - Self.margin)
    }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    private var handleRadius: CGFloat { 5 / magnification }

    func updateFrameSize() {
        let size = CGSize(width: displayedRect.width + Self.margin * 2, height: displayedRect.height + Self.margin * 2)
        if frame.size != size { setFrameSize(size) }
        positionTextField()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)

        context.saveGState()
        context.clip(to: displayedRect)
        model.capture.renderer.draw(model.document, in: context, excluding: model.editingTextID)
        context.restoreGState()

        if model.isCropping, let crop = model.cropDraft {
            drawCropOverlay(crop, in: context)
        } else if let selected = model.selected, model.editingTextID == nil {
            drawSelection(selected, in: context)
        }
        context.restoreGState()
    }

    private func drawSelection(_ annotation: Annotation, in context: CGContext) {
        let lineWidth = 1 / magnification
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(lineWidth)
        if !annotation.isSegment {
            context.setLineDash(phase: 0, lengths: [4 / magnification, 3 / magnification])
            context.stroke(annotation.rect.insetBy(dx: -3 / magnification, dy: -3 / magnification))
            context.setLineDash(phase: 0, lengths: [])
        }
        for point in annotation.handles.values {
            drawHandle(at: point, in: context)
        }
    }

    private func drawCropOverlay(_ crop: CGRect, in context: CGContext) {
        let bounds = model.document.imageBounds
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.addRect(bounds)
        context.addRect(crop)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(.white)
        context.setLineWidth(1 / magnification)
        context.stroke(crop)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        for third in [1.0 / 3, 2.0 / 3] {
            context.move(to: CGPoint(x: crop.minX + crop.width * third, y: crop.minY))
            context.addLine(to: CGPoint(x: crop.minX + crop.width * third, y: crop.maxY))
            context.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * third))
            context.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * third))
        }
        context.strokePath()
        for point in Handle.points(of: crop).values {
            drawHandle(at: point, in: context)
        }
        drawCropSize(crop)
    }

    private func drawCropSize(_ crop: CGRect) {
        let scale = model.capture.scale
        let label = "\(Int((crop.width * scale).rounded())) × \(Int((crop.height * scale).rounded()))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11 / magnification, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let padding = 4 / magnification
        var box = CGRect(x: crop.minX, y: crop.minY - size.height - padding * 3, width: size.width + padding * 2, height: size.height + padding)
        if box.minY < model.document.imageBounds.minY - Self.margin { box.origin.y = crop.minY + padding }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: padding, yRadius: padding).fill()
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    private func drawHandle(at point: CGPoint, in context: CGContext) {
        let rect = CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
        context.setFillColor(.white)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / magnification)
        context.strokeEllipse(in: rect)
    }

    // MARK: Mouse

    override func resetCursorRects() {
        if isSpaceDown {
            addCursorRect(visibleRect, cursor: .openHand)
        } else if model.isCropping || model.tool != .text {
            addCursorRect(visibleRect, cursor: .crosshair)
        } else {
            addCursorRect(visibleRect, cursor: .iBeam)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            finishEditingText()
            return
        }
        window?.makeFirstResponder(self)
        let point = documentPoint(for: event)

        if isSpaceDown {
            interaction = .panning(last: event.locationInWindow)
            NSCursor.closedHand.set()
            return
        }
        if model.isCropping {
            beginCropInteraction(at: point)
            return
        }
        if let selected = model.selected, let handle = handle(of: selected.handles, at: point) {
            interaction = .resizing(id: selected.id, handle: handle, previous: model.document)
            return
        }
        if let hit = model.document.annotation(at: point, tolerance: 6 / magnification) {
            model.select(hit.id)
            if hit.kind == .text && event.clickCount == 2 {
                beginEditingText(hit.id, previous: model.document)
            } else {
                interaction = .moving(id: hit.id, last: point, previous: model.document)
            }
            return
        }

        model.select(nil)
        guard let kind = model.tool.annotationKind else { return }
        let previous = model.document
        let annotation = model.makeAnnotation(kind, at: point, filled: event.modifierFlags.contains(.option))
        var document = previous
        document.add(annotation)
        model.setDocumentLive(document)
        if kind == .text {
            model.select(annotation.id)
            beginEditingText(annotation.id, previous: previous)
        } else {
            interaction = .creating(id: annotation.id, start: point, previous: previous)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = documentPoint(for: event)
        let shift = event.modifierFlags.contains(.shift)
        var document = model.document

        switch interaction {
        case .creating(let id, let start, _):
            guard var annotation = document.annotation(withID: id) else { return }
            annotation.end = shift ? constrainedEnd(for: annotation.kind, from: start, to: point) : point
            document.update(annotation)
            model.setDocumentLive(document)
        case .moving(let id, let last, let previous):
            guard let annotation = document.annotation(withID: id) else { return }
            document.update(annotation.moved(by: CGVector(dx: point.x - last.x, dy: point.y - last.y)))
            model.setDocumentLive(document)
            interaction = .moving(id: id, last: point, previous: previous)
        case .resizing(let id, let handle, _):
            guard let annotation = document.annotation(withID: id) else { return }
            var target = point
            if shift && annotation.isSegment {
                target = Geometry.snappedEnd(from: handle == .start ? annotation.end : annotation.start, to: point)
            }
            document.update(annotation.resized(handle, to: target))
            model.setDocumentLive(document)
        case .cropNew(let start):
            let end = shift ? Geometry.squareEnd(from: start, to: point) : point
            model.cropDraft = Geometry.clamp(Geometry.rect(from: start, to: end), to: document.imageBounds)
        case .cropMove(let startRect, let startPoint):
            let moved = startRect.offsetBy(dx: point.x - startPoint.x, dy: point.y - startPoint.y)
            model.cropDraft = Geometry.slide(moved, into: document.imageBounds)
        case .cropResize(let handle, let startRect):
            let resized = shift
                ? Geometry.resizeKeepingAspect(startRect, handle: handle, to: point)
                : Geometry.resize(startRect, handle: handle, to: point)
            model.cropDraft = Geometry.clamp(resized, to: document.imageBounds)
        case .panning(let last):
            pan(by: CGPoint(x: event.locationInWindow.x - last.x, y: event.locationInWindow.y - last.y))
            interaction = .panning(last: event.locationInWindow)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { interaction = nil }
        switch interaction {
        case .creating(let id, _, let previous):
            if let annotation = model.document.annotation(withID: id), annotation.isTooSmall {
                model.setDocumentLive(previous)
            } else {
                model.commit(from: previous)
                model.select(id)
            }
        case .moving(_, _, let previous), .resizing(_, _, let previous):
            model.commit(from: previous)
        case .cropNew, .cropMove, .cropResize:
            if let draft = model.cropDraft, draft.width < 4 || draft.height < 4 {
                model.cropDraft = model.document.imageBounds
            }
        case .panning:
            NSCursor.openHand.set()
        case nil:
            break
        }
    }

    private func beginCropInteraction(at point: CGPoint) {
        let crop = model.cropDraft ?? model.document.imageBounds
        if let handle = handle(of: Handle.points(of: crop), at: point) {
            interaction = .cropResize(handle: handle, startRect: crop)
        } else if crop.contains(point) {
            interaction = .cropMove(startRect: crop, startPoint: point)
        } else {
            interaction = .cropNew(start: point)
        }
    }

    private func constrainedEnd(for kind: Annotation.Kind, from start: CGPoint, to point: CGPoint) -> CGPoint {
        switch kind {
        case .line, .arrow: Geometry.snappedEnd(from: start, to: point)
        case .text: point
        default: Geometry.squareEnd(from: start, to: point)
        }
    }

    private func handle(of handles: [Handle: CGPoint], at point: CGPoint) -> Handle? {
        let reach = handleRadius + 4 / magnification
        return handles.min { hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y) }
            .flatMap { hypot($0.value.x - point.x, $0.value.y - point.y) <= reach ? $0.key : nil }
    }

    private func documentPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + origin.x, y: local.y + origin.y)
    }

    private func pan(by delta: CGPoint) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        var bounds = clipView.bounds
        bounds.origin.x -= delta.x / magnification
        bounds.origin.y += delta.y / magnification
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 49:
            if !event.isARepeat { isSpaceDown = true; window?.invalidateCursorRects(for: self) }
            return
        case 51, 117:
            model.deleteSelected()
            return
        case 53:
            model.isCropping ? model.cancelCrop() : model.select(nil)
            return
        case 36, 76:
            if model.isCropping {
                model.applyCrop()
            } else if let selected = model.selected, selected.kind == .text {
                beginEditingText(selected.id, previous: model.document)
            }
            return
        case 123, 124, 125, 126:
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let delta: [Int: CGVector] = [123: .init(dx: -step, dy: 0), 124: .init(dx: step, dy: 0), 125: .init(dx: 0, dy: step), 126: .init(dx: 0, dy: -step)]
            model.nudgeSelected(by: delta[Int(event.keyCode)]!)
            return
        default:
            break
        }

        if modifiers.isDisjoint(with: [.command, .control, .option]),
           let character = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.key == character }) {
            model.selectTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    // MARK: Text editing

    func finishEditingText() {
        guard let field = textField, let id = model.editingTextID else { return }
        let text = field.stringValue
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        model.editingTextID = nil

        var document = model.document
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.remove(id: id)
            model.select(nil)
        } else if var annotation = document.annotation(withID: id) {
            annotation.text = text
            document.update(TextLayout.fitted(annotation))
        }
        model.setDocumentLive(document)
        if let previous = textEditPrevious { model.commit(from: previous) }
        textEditPrevious = nil
        window?.makeFirstResponder(self)
    }

    private func beginEditingText(_ id: UUID, previous: EditorDocument) {
        finishEditingText()
        guard let annotation = model.document.annotation(withID: id) else { return }
        textEditPrevious = previous
        model.editingTextID = id

        let field = NSTextField(string: annotation.text)
        field.isBordered = false
        field.focusRingType = .none
        field.font = TextLayout.font(for: annotation.size)
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        if annotation.textStyle == .pill {
            field.drawsBackground = true
            field.backgroundColor = annotation.color.nsColor
            field.textColor = TextLayout.contrastColor(for: annotation.color)
        } else {
            field.drawsBackground = false
            field.textColor = annotation.color.nsColor
        }
        addSubview(field)
        textField = field
        positionTextField()
        window?.makeFirstResponder(field)
    }

    private func positionTextField() {
        guard let field = textField, let id = model.editingTextID, var annotation = model.document.annotation(withID: id) else { return }
        annotation.text = field.stringValue
        let fitted = TextLayout.fitted(annotation)
        let textOrigin = TextLayout.textOrigin(for: fitted)
        let padding = TextLayout.padding(for: fitted)
        field.frame = CGRect(
            x: textOrigin.x - origin.x - 2,
            y: textOrigin.y - origin.y,
            width: fitted.rect.width - padding.width * 2 + 24,
            height: fitted.rect.height - padding.height * 2 + 2
        )
    }

    func controlTextDidChange(_ notification: Notification) {
        positionTextField()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditingText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditingText()
            return true
        }
        return false
    }
}
