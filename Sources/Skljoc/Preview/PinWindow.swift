import AppKit

/// A screenshot pinned above all windows. Drag to move, drag an edge or pinch to resize,
/// scroll to change the opacity, double-click to edit, Esc or ✕ to close.
@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    struct Handlers {
        var copy: (Capture) -> Void
        var save: (Capture) -> Void
        var edit: (Capture) -> Void
        var closed: (Capture) -> Void
    }

    let capture: Capture
    private let handlers: Handlers
    private let window: PinPanel
    private let content: PinContentView

    init(capture: Capture, handlers: Handlers) {
        self.capture = capture
        self.handlers = handlers
        let size = Self.initialSize(for: capture.document.outputSize)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        window = PinPanel(contentRect: frame)
        content = PinContentView(frame: CGRect(origin: .zero, size: size))
        super.init()

        window.contentAspectRatio = capture.document.outputSize
        window.contentView = content
        window.delegate = self
        content.image = capture.thumbnail()
        content.onClose = { [weak self] in self?.close() }
        content.onEdit = { [weak self] in self.map { $0.handlers.edit($0.capture) } }
        content.onCopy = { [weak self] in self.map { $0.handlers.copy($0.capture) } }
        content.onSave = { [weak self] in self.map { $0.handlers.save($0.capture) } }
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// After editing, the pin shows the new version.
    func refresh() {
        content.image = capture.thumbnail()
        window.contentAspectRatio = capture.document.outputSize
        var frame = window.frame
        let ratio = capture.document.outputSize.width / max(capture.document.outputSize.height, 1)
        frame.size.height = frame.width / ratio
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        handlers.closed(capture)
    }

    private static func initialSize(for size: CGSize) -> CGSize {
        let screen = (NSScreen.main?.visibleFrame.size) ?? CGSize(width: 1200, height: 800)
        let scale = min(1, screen.width * 0.6 / max(size.width, 1), screen.height * 0.6 / max(size.height, 1))
        return CGSize(width: max(80, size.width * scale), height: max(40, size.height * scale))
    }
}

private final class PinPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = CGSize(width: 60, height: 30)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinContentView: NSView {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    var image: NSImage? {
        didSet { imageView.image = image }
    }

    private let imageView = NSImageView()
    private let closeButton = NSButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.toolTip = "Close (Esc)"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 24, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            onEdit?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        window.alphaValue = min(1, max(0.2, window.alphaValue + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)))
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        var frame = window.frame
        let factor = 1 + event.magnification
        let newSize = CGSize(width: max(60, frame.width * factor), height: max(30, frame.height * factor))
        frame.origin.x -= (newSize.width - frame.width) / 2
        frame.origin.y -= (newSize.height - frame.height) / 2
        frame.size = newSize
        window.setFrame(frame, display: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Copy", #selector(copyClicked)))
        menu.addItem(item("Save", #selector(saveClicked)))
        menu.addItem(item("Edit", #selector(editClicked)))
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let entry = item("\(percent)%", #selector(opacityClicked(_:)))
            entry.tag = percent
            entry.state = Int(((window?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
            opacityMenu.addItem(entry)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(closeClicked)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func editClicked() { onEdit?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func opacityClicked(_ sender: NSMenuItem) { window?.alphaValue = CGFloat(sender.tag) / 100 }
}
