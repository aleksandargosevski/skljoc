import AppKit
import Combine
import SwiftUI

/// The editor window for one capture. Closing it counts as Done: edits stay with the capture.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    struct Handlers {
        var copy: (Capture) -> Void
        var save: (Capture) -> Void
        var saveAs: (Capture) -> Void
        var upload: (Capture) -> Void
        var uploadWithOptions: (Capture) -> Void
        var dragItem: (Capture) -> NSItemProvider
        var done: (Capture) -> Void
        var closed: (Capture) -> Void
        var pin: (Capture) -> Void
        var copyText: (Capture) -> Void
    }

    let capture: Capture
    private let model: EditorModel
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let handlers: Handlers
    private var finishedByAction = false
    private var panelWidth: NSLayoutConstraint?
    private var subscriptions: Set<AnyCancellable> = []

    init(capture: Capture, handlers: Handlers) {
        self.capture = capture
        self.handlers = handlers
        model = EditorModel(capture: capture)
        canvas = CanvasView(model: model)

        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Škljoc"
        window.minSize = CGSize(width: 820, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.editor = self
        buildContent(in: window)
        sizeWindowToFitImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        zoomToFit()
    }

    // MARK: Actions

    func copy() { finish(with: handlers.copy) }
    func pin() { finish(with: handlers.pin) }
    func copyText() { canvas.finishEditingText(); handlers.copyText(capture) }
    func save() { finish(with: handlers.save) }
    func upload() { canvas.finishEditingText(); handlers.upload(capture) }
    func uploadWithOptions() { canvas.finishEditingText(); handlers.uploadWithOptions(capture) }
    func undo() { model.undo() }
    func redo() { model.redo() }

    func saveAs() {
        canvas.finishEditingText()
        handlers.saveAs(capture)
    }

    func done() {
        window?.close()
    }

    func zoom(by factor: CGFloat) {
        let magnification = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.animator().magnification = magnification
    }

    func zoomToFit() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = scrollView.contentSize
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        scrollView.magnification = min(1, available.width / size.width, available.height / size.height)
    }

    func windowWillClose(_ notification: Notification) {
        canvas.finishEditingText()
        if model.isCropping { model.applyCrop() }
        if !finishedByAction { handlers.done(capture) }
        handlers.closed(capture)
    }

    private func finish(with action: (Capture) -> Void) {
        canvas.finishEditingText()
        if model.isCropping { model.applyCrop() }
        finishedByAction = true
        action(capture)
        window?.close()
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let toolbar = NSHostingView(rootView: EditorToolbar(model: model))
        let actionBar = NSHostingView(rootView: EditorActionBar(
            dragItem: { [unowned self] in canvas.finishEditingText(); return handlers.dragItem(capture) },
            copy: { [unowned self] in copy() },
            save: { [unowned self] in save() },
            saveAs: { [unowned self] in saveAs() },
            upload: { [unowned self] in upload() },
            done: { [unowned self] in done() },
            pin: { [unowned self] in pin() },
            copyText: { [unowned self] in copyText() }
        ))

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)

        let topDivider = NSBox()
        topDivider.boxType = .separator
        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator

        let panel = NSHostingView(rootView: BackgroundPanel(model: model))
        panel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [toolbar, topDivider, bottomDivider, actionBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        content.addSubview(panel)
        let panelWidth = panel.widthAnchor.constraint(equalToConstant: 0)
        self.panelWidth = panelWidth
        panel.clipsToBounds = true
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            topDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
            panel.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panelWidth,
            bottomDivider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            actionBar.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        // The background panel slides in while the background tool is active.
        model.$tool
            .removeDuplicates()
            .sink { [weak self] tool in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.panelWidth?.animator().constant = tool == .background ? 260 : 0
                }
                DispatchQueue.main.async { self.zoomToFit() }
            }
            .store(in: &subscriptions)
    }

    private func sizeWindowToFitImage() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let chrome: CGFloat = 130
        let canvasSize = canvas.frame.size
        let width = min(max(canvasSize.width, window.minSize.width), visible.width * 0.85)
        let height = min(max(canvasSize.height + chrome, window.minSize.height), visible.height * 0.85)
        window.setContentSize(CGSize(width: width, height: height))
    }
}

/// Routes editor shortcuts, unless a text annotation is being typed (it needs ⌘C, ⌘Z and friends itself).
final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor, !(firstResponder is NSTextView) else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch (modifiers, key) {
        case ([.command], "z"): MainActor.assumeIsolated { editor.undo() }
        case ([.command, .shift], "z"): MainActor.assumeIsolated { editor.redo() }
        case ([.command], "c"): MainActor.assumeIsolated { editor.copy() }
        case ([.command, .shift], "c"): MainActor.assumeIsolated { editor.copyText() }
        case ([.command], "s"): MainActor.assumeIsolated { editor.save() }
        case ([.command, .shift], "s"): MainActor.assumeIsolated { editor.saveAs() }
        case ([.command], "u"): MainActor.assumeIsolated { editor.upload() }
        case ([.command, .option], "u"): MainActor.assumeIsolated { editor.uploadWithOptions() }
        case ([.command], "p"): MainActor.assumeIsolated { editor.pin() }
        case ([.command], "="), ([.command], "+"), ([.command, .shift], "="): MainActor.assumeIsolated { editor.zoom(by: 1.25) }
        case ([.command], "-"): MainActor.assumeIsolated { editor.zoom(by: 0.8) }
        case ([.command], "0"): MainActor.assumeIsolated { editor.zoomToFit() }
        case ([.command], "w"): MainActor.assumeIsolated { editor.done() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Keeps the image centered when it is smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let documentFrame = documentView.frame
        if rect.width > documentFrame.width { rect.origin.x = (documentFrame.width - rect.width) / 2 }
        if rect.height > documentFrame.height { rect.origin.y = (documentFrame.height - rect.height) / 2 }
        return rect
    }
}
