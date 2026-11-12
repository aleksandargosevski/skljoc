import AppKit
import SwiftUI

/// Floating previews stacked in the bottom-left corner of the screen the pointer was on.
/// The newest preview sits at the bottom and pushes older ones up.
@MainActor
final class PreviewStack {
    /// Actions for one preview; `close` is filled in by the stack.
    struct Handlers {
        var copy: () -> Void
        var save: () -> Void
        var saveAs: () -> Void
        var upload: () -> Void
        var edit: () -> Void
        var dragItem: () -> NSItemProvider
        var pin: (() -> Void)? = nil
        var copyText: (() -> Void)? = nil
        var uploadWithOptions: (() -> Void)? = nil
    }

    private final class Item {
        let key: ObjectIdentifier
        let panel: PreviewPanel
        let state: PreviewState

        init(key: ObjectIdentifier, panel: PreviewPanel, state: PreviewState) {
            self.key = key
            self.panel = panel
            self.state = state
        }
    }

    static let cardWidth: CGFloat = 280
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 12
    private static let escapeHotKeyID: UInt32 = 100

    private var items: [Item] = []
    private var screen: NSScreen?
    private let hotKeys: HotKeyCenter

    init(hotKeys: HotKeyCenter) {
        self.hotKeys = hotKeys
    }

    func show(_ owner: AnyObject, content: PreviewContent, handlers: Handlers) {
        let key = ObjectIdentifier(owner)
        if let existing = items.first(where: { $0.key == key }) {
            existing.state.content = content
            existing.panel.orderFrontRegardless()
            layout(animated: true)
            return
        }
        screen = Self.screenUnderPointer()
        let state = PreviewState(content: content)
        let size = Self.cardSize(for: content)
        let panel = PreviewPanel(contentRect: CGRect(origin: .zero, size: size))
        let actions = PreviewActions(
            copy: handlers.copy,
            save: handlers.save,
            saveAs: handlers.saveAs,
            upload: handlers.upload,
            edit: handlers.edit,
            close: { [weak self] in self?.remove(key) },
            dragItem: handlers.dragItem,
            pin: handlers.pin,
            copyText: handlers.copyText,
            uploadWithOptions: handlers.uploadWithOptions
        )
        let hosting = FirstMouseHostingView(rootView: PreviewCardView(state: state, actions: actions))
        let container = HoverTrackingView(frame: CGRect(origin: .zero, size: size))
        container.onHoverChange = { [weak self, weak state] hovering in
            state?.isHovered = hovering
            self?.updateEscapeKey(for: key, hovering: hovering)
        }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        items.insert(Item(key: key, panel: panel, state: state), at: 0)

        let target = frames()[0]
        panel.setFrame(target.offsetBy(dx: -(target.width + Self.margin), dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        layout(animated: true)
    }

    func update(_ owner: AnyObject, content: PreviewContent) {
        guard let item = items.first(where: { $0.key == ObjectIdentifier(owner) }) else { return }
        item.state.content = content
        layout(animated: true)
    }

    func setBusy(_ owner: AnyObject, _ text: String?) {
        items.first { $0.key == ObjectIdentifier(owner) }?.state.busyText = text
    }

    func remove(_ owner: AnyObject) {
        remove(ObjectIdentifier(owner))
    }

    private func remove(_ key: ObjectIdentifier) {
        guard let index = items.firstIndex(where: { $0.key == key }) else { return }
        let item = items.remove(at: index)
        if item.state.isHovered { hotKeys.unregister(id: Self.escapeHotKeyID) }
        let panel = item.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
        layout(animated: true)
    }

    private func updateEscapeKey(for key: ObjectIdentifier, hovering: Bool) {
        if hovering {
            hotKeys.registerTransient(id: Self.escapeHotKeyID, shortcut: .init(keyCode: 53, modifiers: [])) { [weak self] in
                self?.remove(key)
            }
        } else {
            hotKeys.unregister(id: Self.escapeHotKeyID)
        }
    }

    private func layout(animated: Bool) {
        for (item, frame) in zip(items, frames()) {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    item.panel.animator().setFrame(frame, display: true)
                    item.panel.animator().alphaValue = 1
                }
            } else {
                item.panel.setFrame(frame, display: true)
                item.panel.alphaValue = 1
            }
        }
    }

    private func frames() -> [CGRect] {
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var y = visible.minY + Self.margin
        return items.map { item in
            let size = Self.cardSize(for: item.state.content)
            let frame = CGRect(x: visible.minX + Self.margin, y: y, width: size.width, height: size.height)
            y += size.height + Self.spacing
            return frame
        }
    }

    private static func cardSize(for content: PreviewContent) -> CGSize {
        let size = content.size
        guard size.width > 0 else { return CGSize(width: cardWidth, height: 160) }
        let height = (cardWidth * size.height / size.width).rounded()
        return CGSize(width: cardWidth, height: min(max(height, 150), 220))
    }

    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }
}

/// Floats above other windows on every Space without taking focus from the app in front.
final class PreviewPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tracks hovering even while Skljoc isn't the active app.
final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
