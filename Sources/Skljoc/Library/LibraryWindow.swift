import AppKit
import Quartz
import SkljocCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    var setUpUploads: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tab", selection: $model.tab) {
                    ForEach(LibraryTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .help("⌘1 ⌘2 ⌘3, or ⇧H and ⇧L")
                Spacer()
                searchField
            }
            .padding(12)

            Group {
                switch model.tab {
                case .history: HistoryPaneView(pane: model.history)
                case .uploads: FilesPaneView(pane: model.files, setUp: setUpUploads)
                case .links: LinksPaneView(pane: model.links, setUp: setUpUploads)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 440)
        .onChange(of: model.isSearchFocused) { _, focused in isSearchFocused = focused }
        .onChange(of: isSearchFocused) { _, focused in model.isSearchFocused = focused }
    }

    @ViewBuilder private var searchField: some View {
        switch model.tab {
        case .history: SearchField(pane: model.history, prompt: "Search names and text", focus: $isSearchFocused)
        case .uploads: SearchField(pane: model.files, prompt: "Search files and names", focus: $isSearchFocused)
        case .links: SearchField(pane: model.links, prompt: "Search names and destinations", focus: $isSearchFocused)
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.tab {
        case .history: KeyHints(pane: model.history, control: model.history)
        case .uploads: KeyHints(pane: model.files, control: model.files)
        case .links: KeyHints(pane: model.links, control: model.links)
        }
    }
}

private struct SearchField<Item: Identifiable>: View where Item.ID: Hashable {
    @ObservedObject var pane: SelectableList<Item>
    let prompt: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(prompt, text: $pane.query)
            .textFieldStyle(.roundedBorder)
            .focused(focus)
            .frame(width: 260)
            .help("/ or ⌘F to search, Esc to go back to the list")
    }
}

/// The keys that work right now, so nobody has to remember them.
private struct KeyHints<Item: Identifiable>: View where Item.ID: Hashable {
    @ObservedObject var pane: SelectableList<Item>
    let control: LibraryPaneControl

    var body: some View {
        HStack(spacing: 14) {
            if pane.isVisualMode {
                Text("VISUAL").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
            }
            if pane.selection.isMultiple {
                Text("\(pane.selection.count) selected").font(.caption.weight(.medium))
            }
            ForEach(control.commands(), id: \.self) { command in
                hint(command.key, title(command))
            }
            Spacer(minLength: 0)
            hint("/", "search")
            hint("v", "select")
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func title(_ command: LibraryCommand) -> String {
        switch command {
        case .copy: pane.selection.isMultiple ? "copy all" : "copy"
        case .edit: control is HistoryPane ? "edit" : "options"
        case .quickLook: "preview"
        case .pin: "pin"
        case .reveal:
            switch control {
            case is HistoryPane: "finder"
            case is LinksPane: "open target"
            default: "browser"
            }
        case .rename: "rename"
        case .upload: "upload"
        case .changeDestination: "destination"
        case .delete: "delete"
        }
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let model: LibraryModel
    let quickLook: QuickLookController
    private var keyMonitor: Any?

    init(model: LibraryModel, quickLook: QuickLookController, setUpUploads: @escaping () -> Void) {
        self.model = model
        self.quickLook = quickLook
        let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(model: model, setUpUploads: setUpUploads)))
        window.title = "Škljoc"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: 920, height: 640))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SkljocLibrary")
        super.init(window: window)
        window.delegate = self
        model.focusList = { [weak self] in self?.window?.makeFirstResponder(nil) }
        model.close = { [weak self] in self?.window?.performClose(nil) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ tab: LibraryTab?) {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        model.show(tab ?? model.tab)
        startMonitoringKeys()
        // SwiftUI puts the first text field in focus when the window opens; the list should have it.
        DispatchQueue.main.async { [weak self] in self?.model.leaveSearch() }
    }

    func windowWillClose(_ notification: Notification) {
        quickLook.close()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func startMonitoringKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    /// Keys in this window, and in Quick Look while it shows our items, go to the model first.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, NSApp.modalWindow == nil else { return false }
        let inQuickLook = quickLook.owns(event.window)
        guard event.window === window || inQuickLook else { return false }
        let key = KeyInput(event)
        if inQuickLook {
            // Esc and Space close Quick Look and give the keys back to the list.
            if key.code == .escape || key.code == .space {
                quickLook.close()
                window.makeKeyAndOrderFront(nil)
                return true
            }
            return model.handle(key, searchFocused: false)
        }
        let searchFocused = window.firstResponder is NSTextView
        return model.handle(key, searchFocused: searchFocused)
    }
}

/// Quick Look for whatever the focused item is, following the focus while it is open.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    private var url: URL?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && isDataSource
    }

    private var isDataSource: Bool {
        (QLPreviewPanel.shared().dataSource as AnyObject?) === self
    }

    func isShowing(_ url: URL) -> Bool {
        isVisible && self.url == url
    }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window, QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return window === QLPreviewPanel.shared() && isDataSource
    }

    func toggle(_ url: URL) {
        if isVisible { close() } else { show(url) }
    }

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        panel.dataSource = self
        panel.reloadData()
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
