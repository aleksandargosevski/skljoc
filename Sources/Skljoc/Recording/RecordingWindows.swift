import AppKit
import SwiftUI

extension NSWindow.Level {
    /// Above everything else on screen, including full-screen apps and the menu bar.
    static let selectionOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
    static let recordingControls = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let cameraBubble = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    static let recordingEffects = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
}

/// A borderless, transparent window that floats on every Space.
class OverlayWindow: NSPanel {
    private let allowsKey: Bool

    init(frame: CGRect, level: NSWindow.Level, allowsKey: Bool = false, ignoresMouse: Bool = false) {
        self.allowsKey = allowsKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Setting isFloatingPanel resets the level to .floating, so the real level has to come after it.
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = ignoresMouse
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// A dashed outline just outside the recorded area, so it doesn't end up in the video.
@MainActor
final class RecordingBorder {
    private let window: OverlayWindow
    private static let outset: CGFloat = 4

    init(around rect: CGRect) {
        let frame = rect.insetBy(dx: -Self.outset, dy: -Self.outset)
        window = OverlayWindow(frame: frame, level: .recordingControls, ignoresMouse: true)
        window.sharingType = .none
        let view = DashedBorderView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
    }

    var windowNumber: Int { window.windowNumber }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil) }
}

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

/// "3, 2, 1" in the middle of the area before recording starts.
@MainActor
final class Countdown {
    private let window: OverlayWindow
    private let model = CountdownModel()
    private var isCancelled = false

    init(centeredIn rect: CGRect) {
        let size = CGSize(width: 140, height: 140)
        let frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        window = OverlayWindow(frame: frame, level: .recordingEffects, ignoresMouse: true)
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
    }

    /// Returns false when cancelled.
    func run(from start: Int = 3) async -> Bool {
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for value in stride(from: start, through: 1, by: -1) {
            model.value = value
            try? await Task.sleep(for: .seconds(1))
            if isCancelled { return false }
        }
        return true
    }

    func cancel() { isCancelled = true }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var value = 3
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 72, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.7)))
            .contentTransition(.numericText(countsDown: true))
            .animation(.easeOut(duration: 0.2), value: model.value)
    }
}
