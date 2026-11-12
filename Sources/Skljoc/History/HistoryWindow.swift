import AppKit
import Quartz
import SkljocCore
import SwiftUI

/// All screenshots and recordings, searchable by the text in them.
@MainActor
final class HistoryModel: ObservableObject {
    enum Filter: String, CaseIterable {
        case all = "All", screenshots = "Screenshots", recordings = "Recordings"
    }

    struct Actions {
        var open: (HistoryEntry) -> Void
        var copy: (HistoryEntry) -> Void
        var save: (HistoryEntry) -> Void
        var pin: (HistoryEntry) -> Void
        var delete: (HistoryEntry) -> Void
        var dragItem: (HistoryEntry) -> NSItemProvider
    }

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    @Published var filter: Filter = .all
    @Published var query = ""
    @Published var selection: URL?
    /// Opens or closes Quick Look for a file; set by the window controller.
    var quickLook: (URL?) -> Void = { _ in }

    let store: CaptureStore
    let actions: Actions
    private var texts: [URL: String] = [:]

    init(store: CaptureStore, actions: Actions) {
        self.store = store
        self.actions = actions
    }

    var visibleEntries: [HistoryEntry] {
        entries.filter { entry in
            switch filter {
            case .all: break
            case .screenshots: if entry.kind != .screenshot { return false }
            case .recordings: if entry.kind != .recording { return false }
            }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return texts[entry.url]?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func reload() {
        entries = store.entries()
        for entry in entries {
            texts[entry.url] = store.text(for: entry)
        }
        if let selection, !entries.contains(where: { $0.url == selection }) { self.selection = nil }
        loadMissingThumbnails()
    }

    func toggleQuickLook() {
        quickLook(selection)
    }

    private func loadMissingThumbnails() {
        let missing = entries.filter { thumbnails[$0.url] == nil }
        guard !missing.isEmpty else { return }
        Task {
            for entry in missing {
                if let image = await store.thumbnail(for: entry) { thumbnails[entry.url] = image }
                if entry.kind == .recording, let duration = await store.duration(of: entry) { durations[entry.url] = duration }
            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $model.filter) {
                    ForEach(HistoryModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                TextField("Search text in screenshots", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(12)
            Divider()

            if model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nothing Here Yet" : "No Matches",
                    systemImage: model.query.isEmpty ? "photo.on.rectangle" : "magnifyingglass",
                    description: Text(model.query.isEmpty ? "Screenshots and recordings show up here." : "No screenshot contains “\(model.query)”.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.visibleEntries) { entry in
                            HistoryCell(model: model, entry: entry)
                        }
                    }
                    .padding(14)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    model.toggleQuickLook()
                    return .handled
                }
                .onKeyPress(.return) {
                    if let entry = model.visibleEntries.first(where: { $0.url == model.selection }) { model.actions.open(entry) }
                    return .handled
                }
                .onDeleteCommand {
                    if let entry = model.visibleEntries.first(where: { $0.url == model.selection }) { model.actions.delete(entry) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct HistoryCell: View {
    @ObservedObject var model: HistoryModel
    let entry: HistoryEntry

    private var isSelected: Bool { model.selection == entry.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let image = model.thumbnails[entry.url] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if entry.kind == .recording {
                    Label(model.durations[entry.url].map { SelectionMath.formatDuration($0) } ?? "Video", systemImage: "video.fill")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .padding(6)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3))

            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.actions.open(entry) }
        .simultaneousGesture(TapGesture().onEnded { model.selection = entry.url })
        .onDrag { model.actions.dragItem(entry) }
        .contextMenu {
            Button("Open in Editor") { model.actions.open(entry) }
            Button("Copy") { model.actions.copy(entry) }
            Button("Save") { model.actions.save(entry) }
            if entry.kind == .screenshot {
                Button("Pin to Screen") { model.actions.pin(entry) }
            }
            Button("Quick Look") {
                model.selection = entry.url
                model.quickLook(entry.url)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Divider()
            Button("Delete", role: .destructive) { model.actions.delete(entry) }
        }
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource {
    let model: HistoryModel
    private var previewURL: URL?

    init(model: HistoryModel) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
        window.title = "Škljoc History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: 900, height: 620))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SkljocHistory")
        super.init(window: window)
        window.delegate = self
        model.quickLook = { [weak self] url in self?.toggleQuickLook(url) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Quick Look

    private func toggleQuickLook(_ url: URL?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let url else { return }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }

    func present() {
        model.reload()
        model.store.indexText()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
