import AppKit
import SkljocCore

/// Covers one screen while picking the recording area: drag for an area, click for a window,
/// double-click for the whole screen. The selection then moves and resizes with its handles.
@MainActor
final class SelectionView: NSView {
    private enum Interaction {
        case drawing(start: CGPoint)
        case moving(startRect: CGRect, startPoint: CGPoint)
        case resizing(handle: Handle, startRect: CGRect)
    }

    let screen: NSScreen
    private let model: RecordingSetupModel
    private let windowRects: [CGRect]
    private var hoveredWindow: CGRect?
    private var interaction: Interaction?
    private var didDrag = false
    private static let handleRadius: CGFloat = 5

    init(screen: NSScreen, model: RecordingSetupModel) {
        self.screen = screen
        self.model = model
        self.windowRects = Self.windowRects(on: screen)
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? { model.screen === screen ? model.selection : nil }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))

        if let selection {
            context.addRect(bounds)
            context.addRect(selection)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(.white)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            for point in Handle.points(of: selection).values { drawHandle(at: point, in: context) }
            drawSizeLabel(for: selection)
        } else {
            context.fill(bounds)
            if let hoveredWindow {
                context.clear(hoveredWindow)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                context.fill(hoveredWindow)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(3)
                context.stroke(hoveredWindow.insetBy(dx: 1.5, dy: 1.5))
            }
            if model.selection == nil { drawHint() }
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

    private func drawSizeLabel(for selection: CGRect) {
        let size = SelectionMath.pixelSize(of: selection, scale: screen.backingScaleFactor)
        let label = "\(Int(size.width)) × \(Int(size.height))"
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        var box = CGRect(x: selection.minX, y: selection.minY - textSize.height - 12, width: textSize.width + 12, height: textSize.height + 6)
        if box.minY < 4 { box.origin.y = selection.minY + 6; box.origin.x += 6 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func drawHint() {
        let text = NSAttributedString(
            string: "Drag to select an area · Click a window · Space for the full screen · Esc to cancel",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        )
        let size = text.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10, width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = windowRects.first { $0.contains(point) }
        if hovered != hoveredWindow {
            hoveredWindow = hovered
            needsDisplay = true
        }
        if let selection, selection.contains(point), handle(at: point, of: selection) == nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        if event.clickCount == 2 {
            model.select(bounds, on: screen)
            interaction = nil
            return
        }
        if let selection {
            if let handle = handle(at: point, of: selection) {
                interaction = .resizing(handle: handle, startRect: selection)
                return
            }
            if selection.contains(point) {
                interaction = .moving(startRect: selection, startPoint: point)
                NSCursor.closedHand.set()
                return
            }
        }
        interaction = .drawing(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch interaction {
        case .drawing(let start):
            guard didDrag || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            didDrag = true
            let end = shift ? Geometry.squareEnd(from: start, to: point) : point
            model.select(Geometry.rect(from: start, to: end), on: screen)
        case .moving(let startRect, let startPoint):
            didDrag = true
            let moved = startRect.offsetBy(dx: point.x - startPoint.x, dy: point.y - startPoint.y)
            model.select(Geometry.slide(moved, into: bounds), on: screen)
        case .resizing(let handle, let startRect):
            didDrag = true
            let resized = shift
                ? Geometry.resizeKeepingAspect(startRect, handle: handle, to: point)
                : Geometry.resize(startRect, handle: handle, to: point)
            model.select(resized, on: screen)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { interaction = nil }
        if case .drawing = interaction, !didDrag, let hoveredWindow {
            model.select(hoveredWindow, on: screen)
        }
        if let selection, selection.width < 8 || selection.height < 8 {
            model.select(nil, on: screen)
        }
    }

    private func handle(at point: CGPoint, of rect: CGRect) -> Handle? {
        Handle.points(of: rect)
            .filter { hypot($0.value.x - point.x, $0.value.y - point.y) <= Self.handleRadius + 5 }
            .min { hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y) }?
            .key
    }

    /// Visible windows of other apps on this screen, front to back, in this view's coordinates.
    private static func windowRects(on screen: NSScreen) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTop = primaryHeight - screen.frame.maxY
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bounds = CGRect(origin: .zero, size: screen.frame.size)

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let global = CGRect(dictionaryRepresentation: dictionary),
                  global.width > 40, global.height > 40 else { return nil }
            let local = global.offsetBy(dx: -screen.frame.minX, dy: -screenTop).intersection(bounds)
            return local.isNull || local.width < 40 || local.height < 40 ? nil : local
        }
    }
}
