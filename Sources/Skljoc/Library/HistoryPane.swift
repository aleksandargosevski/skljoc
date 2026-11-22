import AppKit
import SkljocCore
import SwiftUI

/// All screenshots and recordings, searchable by their titles and the text in them.
@MainActor
final class HistoryPane: SelectableList<HistoryEntry>, LibraryPaneControl {
    enum Filter: String, CaseIterable {
        case all = "All", screenshots = "Screenshots", recordings = "Recordings"
    }

    struct Actions {
        var open: (HistoryEntry) -> Void
        var copy: ([HistoryEntry]) -> Void
        var save: (HistoryEntry) -> Void
        var pin: (HistoryEntry) -> Void
        var upload: ([HistoryEntry]) -> Void
        var dragItem: (HistoryEntry) -> NSItemProvider
    }

    static let minimumCellWidth: Double = 190
    static let spacing: Double = 14

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    @Published private(set) var titles: [URL: String] = [:]
    @Published private(set) var uploaded: Set<URL> = []
    /// Items being uploaded right now.
    @Published private(set) var busy: Set<URL> = []
    @Published var filter: Filter = .all {
        didSet { if filter != oldValue { focusFirst() } }
    }

    let store: CaptureStore
    let actions: Actions
    let quickLook: QuickLookController
    private var texts: [URL: String] = [:]

    init(store: CaptureStore, actions: Actions, quickLook: QuickLookController) {
        self.store = store
        self.actions = actions
        self.quickLook = quickLook
    }

    override var visibleItems: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            switch filter {
            case .all: break
            case .screenshots: if entry.kind != .screenshot { return false }
            case .recordings: if entry.kind != .recording { return false }
            }
            guard !trimmed.isEmpty else { return true }
            return [titles[entry.url], texts[entry.url]].contains {
                $0?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    func setColumns(forWidth width: Double) {
        let count = GridNavigation.columns(width: width - 2 * Self.spacing, minimum: Self.minimumCellWidth, spacing: Self.spacing)
        if count != columns { columns = count }
    }

    func setBusy(_ url: URL, _ isBusy: Bool) {
        if isBusy { busy.insert(url) } else { busy.remove(url) }
    }

    // MARK: LibraryPaneControl

    func activate() {
        reload()
        store.indexText()
        if selection.focused == nil { focusFirst() }
    }

    func reload() {
        entries = store.entries()
        for entry in entries {
            texts[entry.url] = store.text(for: entry)
        }
        titles = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in store.title(for: entry).map { (entry.url, $0) } })
        uploaded = Set(entries.filter(store.isUploaded).map(\.url))
        reconcileSelection()
        loadMissingThumbnails()
    }

    func commands() -> [LibraryCommand] {
        guard let focused = focusedItem else { return [] }
        var commands: [LibraryCommand] = [.copy, .edit, .quickLook]
        if focused.kind == .screenshot { commands.append(.pin) }
        commands += [.reveal, .rename, .upload, .delete]
        return commands
    }

    var defaultCommand: LibraryCommand? { .edit }

    func perform(_ command: LibraryCommand) {
        guard let focused = focusedItem else { return }
        let selected = selectedItems
        switch command {
        case .copy: actions.copy(selected)
        case .edit: actions.open(focused)
        case .quickLook: quickLook.toggle(focused.url)
        case .pin: actions.pin(focused)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
        case .rename: rename(focused)
        case .upload: actions.upload(selected)
        case .delete: delete(selected)
        case .changeDestination: break
        }
    }

    override func selectionDidMove() {
        guard quickLook.isVisible else { return }
        if let url = focusedItem?.url { quickLook.show(url) } else { quickLook.close() }
    }

    func label(for entry: HistoryEntry) -> String {
        titles[entry.url] ?? entry.date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Private

    private func rename(_ entry: HistoryEntry) {
        guard let text = TextPrompt.ask(
            title: "Name this \(entry.kind == .screenshot ? "screenshot" : "recording")",
            message: "Shown in History, found by search and used as the file name when you save, drag or upload it. Leave it empty to use the date.",
            initial: titles[entry.url] ?? ""
        ) else { return }
        do {
            try store.setTitle(text, for: entry)
        } catch {
            TextPrompt.show("Could not save the name: \(error.localizedDescription)")
        }
    }

    /// Deletes right away; History items are only copies of what was captured.
    private func delete(_ entries: [HistoryEntry]) {
        if entries.contains(where: { quickLook.isShowing($0.url) }) { quickLook.close() }
        focusAfterRemoving(Set(entries.map(\.id)))
        for entry in entries { store.delete(entry) }
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

struct HistoryPaneView: View {
    @ObservedObject var pane: HistoryPane

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $pane.filter) {
                    ForEach(HistoryPane.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()

            if pane.visibleItems.isEmpty {
                ContentUnavailableView(
                    pane.query.isEmpty ? "Nothing Here Yet" : "No Matches",
                    systemImage: pane.query.isEmpty ? "photo.on.rectangle" : "magnifyingglass",
                    description: Text(pane.query.isEmpty ? "Screenshots and recordings show up here." : "Nothing is named “\(pane.query)” or contains it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HistoryPane.spacing), count: pane.columns), spacing: HistoryPane.spacing) {
                    ForEach(pane.visibleItems) { entry in
                        HistoryCell(pane: pane, entry: entry).id(entry.id)
                    }
                }
                .padding(HistoryPane.spacing)
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { pane.setColumns(forWidth: $0) }
            .onChange(of: pane.selection.focused) { _, focused in
                if let focused { proxy.scrollTo(focused) }
            }
        }
    }
}

private struct HistoryCell: View {
    @ObservedObject var pane: HistoryPane
    let entry: HistoryEntry

    private var isSelected: Bool { pane.selection.contains(entry.url) }
    private var isFocused: Bool { pane.selection.focused == entry.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let image = pane.thumbnails[entry.url] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 4) {
                    if pane.busy.contains(entry.url) {
                        ProgressView().controlSize(.mini).tint(.white).padding(4).background(Circle().fill(.black.opacity(0.7)))
                    } else if pane.uploaded.contains(entry.url) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(.black.opacity(0.7)))
                            .help("Uploaded")
                    }
                    if entry.kind == .recording {
                        Label(pane.durations[entry.url].map { SelectionMath.formatDuration($0) } ?? "Video", systemImage: "video.fill")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.7)))
                    }
                }
                .padding(6)
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(isFocused ? 1 : 0.55) : .clear, lineWidth: 3)
            )

            Text(pane.label(for: entry))
                .font(.caption.weight(pane.titles[entry.url] == nil ? .regular : .medium))
                .foregroundStyle(pane.titles[entry.url] == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if pane.titles[entry.url] != nil {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pane.actions.open(entry) }
        .simultaneousGesture(TapGesture().onEnded { pane.click(entry.url) })
        .onDrag { pane.actions.dragItem(entry) }
        .contextMenu {
            Button("Open in Editor") { pane.actions.open(entry) }
            Button("Copy") { pane.actions.copy([entry]) }
            Button("Save") { pane.actions.save(entry) }
            if entry.kind == .screenshot {
                Button("Pin to Screen") { pane.actions.pin(entry) }
            }
            Button("Quick Look") {
                pane.selection.focus(entry.url)
                pane.quickLook.toggle(entry.url)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Rename…") {
                pane.selection.focus(entry.url)
                pane.perform(.rename)
            }
            Button("Upload") { pane.actions.upload([entry]) }
            Divider()
            Button("Delete", role: .destructive) {
                if !pane.selection.contains(entry.url) { pane.selection.focus(entry.url) }
                pane.perform(.delete)
            }
        }
    }
}
