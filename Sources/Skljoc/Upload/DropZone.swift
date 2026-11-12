import AppKit
import SkljocCore
import SwiftUI
import UniformTypeIdentifiers

/// A floating drop zone: drop (or choose) any files, they go to the Worker, and their links land on the clipboard.
/// Folders are zipped first.
@MainActor
final class DropZoneController {
    var onFinished: ((_ links: [String]) -> Void)?
    var onError: ((Error, String) -> Void)?
    var needsSetup: (() -> Void)?

    private let service: UploadService
    private let optionsWindow = UploadOptionsWindow()
    private let model = DropZoneModel()
    private var panel: DropZonePanel?

    init(service: UploadService) {
        self.service = service
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        guard service.isConfigured else {
            needsSetup?()
            return
        }
        if model.options == nil { model.options = service.defaultOptions }
        if panel == nil {
            let view = DropZoneView(
                model: model,
                choose: { [weak self] in self?.chooseFiles() },
                editOptions: { [weak self] in self?.editOptions() },
                close: { [weak self] in self?.close() },
                drop: { [weak self] urls in self?.upload(urls) }
            )
            let hosting = FirstMouseHostingView(rootView: view)
            let size = hosting.fittingSize
            let panel = DropZonePanel(contentRect: CGRect(origin: .zero, size: size))
            panel.contentView = hosting
            panel.onCancel = { [weak self] in self?.close() }
            self.panel = panel
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2 + visible.height * 0.1))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !model.isUploading else { return }
        panel?.orderOut(nil)
        model.items = []
    }

    private func chooseFiles() {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "Upload"
        open.message = "Choose files or folders to upload. Folders are zipped."
        if let panel {
            open.beginSheetModal(for: panel) { [weak self] response in
                guard response == .OK else { return }
                self?.upload(open.urls)
            }
        } else if open.runModal() == .OK {
            upload(open.urls)
        }
    }

    private func editOptions() {
        optionsWindow.ask(title: "Options for Dropped Files", actionTitle: "Use", initial: model.options ?? service.defaultOptions) { [weak self] options, _ in
            self?.model.options = options
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty, !model.isUploading, let client = service.client else { return }
        let options = model.options ?? service.defaultOptions
        model.items = urls.map { DropZoneModel.Item(name: $0.lastPathComponent + (Self.isFolder($0) ? ".zip" : "")) }
        model.isUploading = true

        Task {
            var links: [String] = []
            var failures: [(String, Error)] = []
            for (index, url) in urls.enumerated() {
                do {
                    let file = Self.isFolder(url) ? try await Self.zip(url) : url
                    defer { if file != url { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
                    let item = index
                    let uploaded = try await client.upload(
                        file, filename: file.lastPathComponent, contentType: Self.contentType(of: file),
                        options: options.payload()
                    ) { fraction in
                        Task { @MainActor [weak self] in self?.model.items[item].progress = fraction }
                    }
                    model.items[index].progress = 1
                    model.items[index].isDone = true
                    links.append(service.copyLink(for: uploaded))
                } catch {
                    model.items[index].failed = true
                    failures.append((url.lastPathComponent, error))
                }
            }
            model.isUploading = false
            if !links.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
            if let (name, error) = failures.first {
                onError?(error, failures.count == 1 ? "Could not upload “\(name)”" : "\(failures.count) files could not be uploaded")
            } else {
                close()
            }
            if !links.isEmpty { onFinished?(links) }
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
    }

    /// A plain zip without macOS metadata (no __MACOSX folder), so it opens cleanly anywhere.
    private static func zip(_ folder: URL) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Skljoc Zip \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent(folder.lastPathComponent + ".zip")
        let status = try await run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", folder.path, archive.path])
        guard status == 0 else { throw DropZoneError.zipFailed(folder.lastPathComponent) }
        return archive
    }

    private static func contentType(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum DropZoneError: LocalizedError {
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let name): "Could not zip the folder “\(name)”."
        }
    }
}

@MainActor
final class DropZoneModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var progress: Double = 0
        var isDone = false
        var failed = false
    }

    @Published var items: [Item] = []
    @Published var isUploading = false
    @Published var isTargeted = false
    @Published var options: UploadOptions?

    var optionsSummary: String {
        guard let options else { return "Public link" }
        var parts: [String] = [options.isPrivate ? "Private" : "Public"]
        if !(options.password ?? "").isEmpty { parts.append("password") }
        if options.expiry != .never { parts.append("expires in \(options.expiry.title)") }
        if options.burnAfterViewing { parts.append("one-time") }
        return parts.joined(separator: ", ")
    }
}

private final class DropZonePanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct DropZoneView: View {
    @ObservedObject var model: DropZoneModel
    let choose: () -> Void
    let editOptions: () -> Void
    let close: () -> Void
    let drop: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Upload Files").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isUploading)
                    .help("Close (Esc)")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .foregroundStyle(model.isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(model.isTargeted ? Color.accentColor.opacity(0.12) : .clear))
                if model.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light))
                        Text("Drop files or folders here").font(.system(size: 14, weight: .medium))
                        Text("Any kind: zip, mp3, mp4, pdf…").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(model.isTargeted ? Color.accentColor : .primary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        if item.failed {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        } else if item.isDone {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                        }
                                    }
                                    .font(.callout)
                                    ProgressView(value: item.progress).progressViewStyle(.linear)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .frame(height: 180)
            .onDrop(of: [.fileURL], isTargeted: $model.isTargeted) { providers in
                load(providers)
                return true
            }

            HStack {
                Button(action: editOptions) {
                    Label(model.optionsSummary, systemImage: "slider.horizontal.3").lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Privacy, password, expiry and one-time links for the next upload")
                Spacer()
                Button("Choose Files…", action: choose)
                    .keyboardShortcut("o", modifiers: .command)
            }
            .disabled(model.isUploading)
        }
        .padding(18)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { drop(collected.urls) }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []
    func add(_ url: URL) { lock.withLock { collected.append(url) } }
    var urls: [URL] { lock.withLock { collected } }
}
