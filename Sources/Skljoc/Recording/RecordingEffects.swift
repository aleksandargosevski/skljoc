import AppKit
import QuartzCore
import SkljocCore
import SwiftUI

/// Draws a fading ring wherever the mouse is clicked, so viewers can follow along.
@MainActor
final class ClickHighlighter {
    private var windows: [OverlayWindow] = []
    private var monitors: [Any] = []

    func start() {
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(frame: screen.frame, level: .recordingEffects, ignoresMouse: true)
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isRight = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.highlight(at: NSEvent.mouseLocation, isRight: isRight) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.highlight(at: NSEvent.mouseLocation, isRight: event.type == .rightMouseDown)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func highlight(at location: CGPoint, isRight: Bool) {
        guard let window = windows.first(where: { NSMouseInRect(location, $0.frame, false) }),
              let layer = window.contentView?.layer else { return }
        let point = CGPoint(x: location.x - window.frame.minX, y: location.y - window.frame.minY)
        let radius: CGFloat = 24
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        let color = isRight ? NSColor.systemRed : NSColor.systemYellow
        ring.fillColor = color.withAlphaComponent(0.4).cgColor
        ring.strokeColor = color.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2.5
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "click")
        CATransaction.commit()
    }
}

/// Shows typed keys and shortcuts at the bottom of the recorded area. Needs Accessibility permission.
@MainActor
final class KeystrokeOverlay {
    private let area: CGRect
    private var window: OverlayWindow?
    private let model = KeystrokeModel()
    private var buffer = KeystrokeBuffer()
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?

    init(area: CGRect) {
        self.area = area
    }

    func start() {
        let width = min(area.width - 40, 600)
        let frame = CGRect(x: area.midX - width / 2, y: area.minY + 28, width: width, height: 64)
        let window = OverlayWindow(frame: frame, level: .recordingEffects, ignoresMouse: true)
        window.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        window.orderFrontRegardless()
        self.window = window

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = UInt32(event.keyCode)
            let characters = event.characters
            let flags = UInt(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            MainActor.assumeIsolated { self?.register(keyCode: keyCode, characters: characters, flags: flags) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.register(
                keyCode: UInt32(event.keyCode),
                characters: event.characters,
                flags: UInt(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            )
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hideWork?.cancel()
        window?.orderOut(nil)
        window = nil
    }

    private func register(keyCode: UInt32, characters: String?, flags: UInt) {
        let text = buffer.register(keyCode: keyCode, characters: characters, modifiers: .init(eventFlags: flags))
        model.text = text
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.text = ""
            self?.buffer.clear()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + buffer.idleReset, execute: work)
    }
}

@MainActor
private final class KeystrokeModel: ObservableObject {
    @Published var text = ""
}

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel

    var body: some View {
        ZStack {
            if !model.text.isEmpty {
                Text(model.text)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.75)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.text.isEmpty)
    }
}
