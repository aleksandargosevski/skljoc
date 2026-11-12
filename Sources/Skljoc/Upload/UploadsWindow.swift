import AppKit
import SkljocCore
import SwiftUI

/// Everything on the user's Worker: views, privacy and expiry, with copy, open, edit and delete.
@MainActor
final class UploadsModel: ObservableObject {
    @Published private(set) var uploads: [UploadedFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var nextOffset: Int?

    private let service: UploadService
    private let optionsWindow = UploadOptionsWindow()
    var onCopied: ((String) -> Void)?

    init(service: UploadService) {
        self.service = service
    }

    var client: UploadClient? { service.client }

    func reload() {
        load(offset: 0)
    }

    func loadMore() {
        guard let nextOffset, !isLoading else { return }
        load(offset: nextOffset)
    }

    func copy(_ upload: UploadedFile) {
        onCopied?(service.copyLink(for: upload))
    }

    func open(_ upload: UploadedFile) {
        guard let client else { return }
        NSWorkspace.shared.open(client.ownerURL(for: upload))
    }

    /// Images (and video posters) for the list; signed, so private ones show too.
    func thumbnailURL(for upload: UploadedFile) -> URL? {
        guard let client else { return nil }
        if upload.isVideo {
            guard upload.hasPoster else { return nil }
            let poster = upload.url.appendingPathComponent("poster.jpg")
            return UploadLinks.signed(poster, id: upload.id, token: client.token, expires: Date().addingTimeInterval(3600))
        }
        return client.ownerURL(for: upload, raw: true)
    }

    func editOptions(_ upload: UploadedFile) {
        var current = UploadOptions()
        current.isPrivate = upload.isPrivate
        current.burnAfterViewing = upload.burn
        current.expiry = .never
        optionsWindow.ask(title: "Link Options", actionTitle: "Save", initial: current, hasPassword: upload.hasPassword) { [weak self] options, passwordChanged in
            guard let self, let client else { return }
            var payload = options.payload()
            // Leaving the expiry at Never keeps whatever expiry the link already has.
            if options.expiry == .never && upload.expiresAt != nil { payload.removeValue(forKey: "expiresIn") }
            if !passwordChanged { payload.removeValue(forKey: "password") }
            Task {
                do {
                    let updated = try await client.update(upload.id, options: payload)
                    self.replace(updated)
                } catch {
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func delete(_ upload: UploadedFile) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(upload.filename)” from your Worker?"
        alert.informativeText = "The link stops working for everyone. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, let client else { return }
        Task {
            do {
                try await client.delete(upload.id)
                uploads.removeAll { $0.id == upload.id }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func replace(_ upload: UploadedFile) {
        if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index] = upload }
    }

    private func load(offset: Int) {
        guard let client else {
            errorText = UploadError.notConfigured.localizedDescription
            uploads = []
            return
        }
        isLoading = true
        errorText = nil
        Task {
            defer { isLoading = false }
            do {
                let page = try await client.list(offset: offset)
                uploads = offset == 0 ? page.uploads : uploads + page.uploads
                nextOffset = page.nextOffset
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct UploadsView: View {
    @ObservedObject var model: UploadsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.uploads.count) uploads").foregroundStyle(.secondary)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(12)
            Divider()
            if let error = model.errorText {
                ContentUnavailableView("Can't Reach Your Worker", systemImage: "icloud.slash", description: Text(error))
            } else if model.uploads.isEmpty && !model.isLoading {
                ContentUnavailableView("No Uploads Yet", systemImage: "icloud.and.arrow.up", description: Text("Uploaded screenshots and recordings show up here."))
            } else {
                List {
                    ForEach(model.uploads) { upload in
                        UploadRow(model: model, upload: upload)
                    }
                    if model.nextOffset != nil {
                        Button("Load More") { model.loadMore() }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 400)
    }
}

private struct UploadRow: View {
    @ObservedObject var model: UploadsModel
    let upload: UploadedFile

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.thumbnailURL(for: upload)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: upload.isVideo ? "video" : "photo").foregroundStyle(.secondary)
            }
            .frame(width: 72, height: 48)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.filename).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(upload.createdDate.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(upload.size), countStyle: .file))
                    if upload.isPrivate { badge("Private", "lock.fill") }
                    if upload.hasPassword { badge("Password", "key.fill") }
                    if upload.burn { badge(upload.burnedAt == nil ? "One-time" : "Viewed", "flame.fill") }
                    if let expires = upload.expiresDate { badge("Expires \(expires.formatted(.relative(presentation: .named)))", "clock") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(upload.views)", systemImage: "eye")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Views (link previews in Slack and similar don't count)")
            Button("Copy Link") { model.copy(upload) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(upload) }
        .contextMenu {
            Button("Copy Link") { model.copy(upload) }
            Button("Open in Browser") { model.open(upload) }
            Button("Link Options…") { model.editOptions(upload) }
            Divider()
            Button("Delete…", role: .destructive) { model.delete(upload) }
        }
    }

    private func badge(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

@MainActor
final class UploadsWindowController: NSWindowController {
    let model: UploadsModel

    init(model: UploadsModel) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: UploadsView(model: model)))
        window.title = "Škljoc Uploads"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: 760, height: 560))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SkljocUploads")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
