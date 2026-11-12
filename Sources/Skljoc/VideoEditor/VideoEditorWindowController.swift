import AppKit
import SwiftUI

/// The editor window for one recording. Closing it counts as Done: edits stay with the recording.
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    struct Handlers {
        var copy: (Recording) -> Void
        var save: (Recording) -> Void
        var saveAs: (Recording) -> Void
        var upload: (Recording) -> Void
        var dragItem: (Recording) -> NSItemProvider
        var done: (Recording) -> Void
        var closed: (Recording) -> Void
    }

    let recording: Recording
    private let model: VideoEditorModel
    private let canvas: VideoCanvasView
    private let handlers: Handlers
    private var finishedByAction = false

    init(recording: Recording, handlers: Handlers) {
        self.recording = recording
        self.handlers = handlers
        model = VideoEditorModel(recording: recording)
        canvas = VideoCanvasView(model: model)

        let window = VideoEditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Škljoc"
        window.minSize = CGSize(width: 900, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.editor = self
        buildContent(in: window)
        sizeWindow()
        Task { await model.prepare() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas.keyView)
    }

    // MARK: Actions

    func copy() { finish(with: handlers.copy) }
    func save() { finish(with: handlers.save) }
    func saveAs() { model.endLiveChange(); handlers.saveAs(recording) }
    func upload() { handlers.upload(recording) }
    func undo() { model.undo() }
    func redo() { model.redo() }
    func done() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        model.endLiveChange()
        model.tearDown()
        if !finishedByAction { handlers.done(recording) }
        handlers.closed(recording)
    }

    private func finish(with action: (Recording) -> Void) {
        model.endLiveChange()
        finishedByAction = true
        action(recording)
        window?.close()
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let toolbar = NSHostingView(rootView: VideoEditorToolbar(model: model))
        let bottom = NSHostingView(rootView: VideoEditorBottomBar(
            model: model,
            dragItem: { [unowned self] in handlers.dragItem(recording) },
            copy: { [unowned self] in copy() },
            save: { [unowned self] in save() },
            saveAs: { [unowned self] in saveAs() },
            upload: { [unowned self] in upload() },
            done: { [unowned self] in done() }
        ))
        let topDivider = NSBox()
        topDivider.boxType = .separator
        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator

        let content = NSView()
        for view in [toolbar, topDivider, canvas, bottomDivider, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            topDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            bottomDivider.topAnchor.constraint(equalTo: canvas.bottomAnchor),
            bottom.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func sizeWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let pointSize = CGSize(width: recording.naturalSize.width / 2, height: recording.naturalSize.height / 2)
        let width = min(max(pointSize.width, window.minSize.width), visible.width * 0.85)
        let height = min(max(pointSize.height + 220, window.minSize.height), visible.height * 0.85)
        window.setContentSize(CGSize(width: width, height: height))
    }
}

/// Routes editor shortcuts to the controller.
final class VideoEditorWindow: NSWindow {
    weak var editor: VideoEditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor, !(firstResponder is NSTextView) else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (modifiers, key) {
        case ([.command], "z"): MainActor.assumeIsolated { editor.undo() }
        case ([.command, .shift], "z"): MainActor.assumeIsolated { editor.redo() }
        case ([.command], "c"): MainActor.assumeIsolated { editor.copy() }
        case ([.command], "s"): MainActor.assumeIsolated { editor.save() }
        case ([.command, .shift], "s"): MainActor.assumeIsolated { editor.saveAs() }
        case ([.command], "w"): MainActor.assumeIsolated { editor.done() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
