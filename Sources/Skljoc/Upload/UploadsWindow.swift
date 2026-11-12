import AppKit
import SkljocCore
import SwiftUI

/// Everything on the user's Worker: uploaded files and short links, with views,
/// privacy and expiry, and copy, open, rename, edit and delete.
@MainActor
final class UploadsModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case files = "Files", links = "Links"
    }

    @Published var tab: Tab = .files {
        didSet { if tab != oldValue { reload() } }
    }
    @Published private(set) var uploads: [UploadedFile] = []
    @Published private(set) var links: [ShortLink] = []
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
    var linkPrefix: String { service.linkPrefix ?? "" }
    var count: Int { tab == .files ? uploads.count : links.count }

    func reload() {
        load(offset: 0)
    }

    func loadMore() {
        guard let nextOffset, !isLoading else { return }
        load(offset: nextOffset)
    }

    // MARK: Files

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
        return upload.contentType.hasPrefix("image/") ? client.ownerURL(for: upload, raw: true) : nil
    }

    func editOptions(_ upload: UploadedFile) {
        editOptions(id: upload.id, isPrivate: upload.isPrivate, burn: upload.burn, hasPassword: upload.hasPassword, hasExpiry: upload.expiresAt != nil)
    }

    func delete(_ upload: UploadedFile) {
        confirmDelete(name: upload.filename, id: upload.id)
    }

    // MARK: Links

    func copy(_ link: ShortLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
        onCopied?(link.url.absoluteString)
    }

    func open(_ link: ShortLink) {
        NSWorkspace.shared.open(link.targetURL)
    }

    func editOptions(_ link: ShortLink) {
        editOptions(id: link.id, isPrivate: link.isPrivate ?? false, burn: link.burn ?? false, hasPassword: link.hasPassword ?? false, hasExpiry: link.expiresAt != nil)
    }

    func changeDestination(_ link: ShortLink) {
        guard let text = Self.askText(
            title: "Change where \(link.url.host() ?? "")\(link.url.path()) goes",
            message: "Visitors are sent to this address from now on. Views so far are kept.",
            initial: link.targetURL.absoluteString, prefix: nil
        ) else { return }
        guard case .shorten(let url) = LinkShortening.check(text, workerBase: client?.baseURL) else {
            show("Enter a full link starting with https://")
            return
        }
        change(link.id) { try await $0.updateLink(link.id, ["url": url.absoluteString]) }
    }

    func delete(_ link: ShortLink) {
        confirmDelete(name: "\(link.url.host() ?? "")\(link.url.path())", id: link.id)
    }

    // MARK: Both

    /// Gives a file or link a new name. The old address stops working; views and options stay.
    func rename(id: String) {
        guard let text = Self.askText(
            title: "Rename \(linkPrefix)\(id)",
            message: "The old address stops working. Views and options stay.",
            initial: id, prefix: linkPrefix
        ), let slug = LinkSlug.normalized(text), slug != id else { return }
        if let problem = LinkSlug.problem(with: slug) {
            show(problem)
            return
        }
        change(id) { try await $0.updateLink(id, ["slug": slug]) }
    }

    private func editOptions(id: String, isPrivate: Bool, burn: Bool, hasPassword: Bool, hasExpiry: Bool) {
        var current = UploadOptions()
        current.isPrivate = isPrivate
        current.burnAfterViewing = burn
        current.expiry = .never
        optionsWindow.ask(title: "Link Options", actionTitle: "Save", initial: current, hasPassword: hasPassword) { [weak self] options, passwordChanged in
            var payload = options.payload()
            // Leaving the expiry at Never keeps whatever expiry the link already has.
            if options.expiry == .never && hasExpiry { payload.removeValue(forKey: "expiresIn") }
            if !passwordChanged { payload.removeValue(forKey: "password") }
            self?.change(id) { try await $0.updateLink(id, payload) }
        }
    }

    private func confirmDelete(name: String, id: String) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(name)” from your Worker?"
        alert.informativeText = "The link stops working for everyone. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, let client else { return }
        Task {
            do {
                try await client.deleteLink(id)
                reload()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func change(_ id: String, _ body: @escaping (UploadClient) async throws -> UploadClient.LinkSummary) {
        guard let client else { return }
        Task {
            do {
                _ = try await body(client)
                reload()
            } catch UploadError.server(409, let message) {
                show(message)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func load(offset: Int) {
        guard let client else {
            errorText = UploadError.notConfigured.localizedDescription
            uploads = []
            links = []
            return
        }
        isLoading = true
        errorText = nil
        let tab = tab
        Task {
            defer { isLoading = false }
            do {
                switch tab {
                case .files:
                    let page = try await client.list(offset: offset)
                    uploads = offset == 0 ? page.uploads : uploads + page.uploads
                    nextOffset = page.nextOffset
                case .links:
                    let page = try await client.listLinks(offset: offset)
                    links = offset == 0 ? page.links : links + page.links
                    nextOffset = page.nextOffset
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// A one-field prompt; returns nil when cancelled.
    private static func askText(title: String, message: String, initial: String, prefix: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        if let prefix {
            let label = NSTextField(labelWithString: prefix)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, field])
            stack.spacing = 2
            stack.frame = CGRect(x: 0, y: 0, width: 360, height: 24)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

struct UploadsView: View {
    @ObservedObject var model: UploadsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $model.tab) {
                    ForEach(UploadsModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Text("\(model.count)").foregroundStyle(.secondary)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(12)
            Divider()
            if let error = model.errorText {
                ContentUnavailableView("Can't Reach Your Worker", systemImage: "icloud.slash", description: Text(error))
            } else if model.count == 0 && !model.isLoading {
                ContentUnavailableView(
                    model.tab == .files ? "No Uploads Yet" : "No Short Links Yet",
                    systemImage: model.tab == .files ? "icloud.and.arrow.up" : "link",
                    description: Text(model.tab == .files ? "Uploaded screenshots, recordings and files show up here." : "Links shortened with Škljoc show up here.")
                )
            } else {
                List {
                    if model.tab == .files {
                        ForEach(model.uploads) { upload in UploadRow(model: model, upload: upload) }
                    } else {
                        ForEach(model.links) { link in LinkRow(model: model, link: link) }
                    }
                    if model.nextOffset != nil {
                        Button("Load More") { model.loadMore() }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
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
                Image(systemName: Self.symbol(for: upload.contentType)).foregroundStyle(.secondary)
            }
            .frame(width: 72, height: 48)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.filename).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(model.linkPrefix)\(upload.id)").foregroundStyle(.primary.opacity(0.7))
                    Text("·")
                    Text(upload.createdDate.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(upload.size), countStyle: .file))
                    Badges(isPrivate: upload.isPrivate, hasPassword: upload.hasPassword, burn: upload.burn, burned: upload.burnedAt != nil, expires: upload.expiresDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
            Button("Rename Link…") { model.rename(id: upload.id) }
            Button("Link Options…") { model.editOptions(upload) }
            Divider()
            Button("Delete…", role: .destructive) { model.delete(upload) }
        }
    }

    private static func symbol(for contentType: String) -> String {
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType.hasPrefix("video/") { return "video" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType == "application/pdf" { return "doc.richtext" }
        if contentType.contains("zip") || contentType.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

private struct LinkRow: View {
    @ObservedObject var model: UploadsModel
    let link: ShortLink

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(link.url.host() ?? "")\(link.url.path())").font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("→ \(link.targetURL.absoluteString)").lineLimit(1).truncationMode(.middle)
                    if let created = link.createdDate {
                        Text("·")
                        Text(created.formatted(date: .abbreviated, time: .shortened))
                    }
                    Badges(isPrivate: link.isPrivate ?? false, hasPassword: link.hasPassword ?? false, burn: link.burn ?? false, burned: false, expires: link.expiresDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Label("\(link.views ?? 0)", systemImage: "cursorarrow.click")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Clicks (link previews in Slack and similar don't count)")
            Button("Copy Link") { model.copy(link) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.copy(link) }
        .contextMenu {
            Button("Copy Link") { model.copy(link) }
            Button("Open Destination") { model.open(link) }
            Button("Rename Link…") { model.rename(id: link.id) }
            Button("Change Destination…") { model.changeDestination(link) }
            Button("Link Options…") { model.editOptions(link) }
            Divider()
            Button("Delete…", role: .destructive) { model.delete(link) }
        }
    }
}

private struct Badges: View {
    let isPrivate: Bool
    let hasPassword: Bool
    let burn: Bool
    let burned: Bool
    let expires: Date?

    var body: some View {
        if isPrivate { badge("Private", "lock.fill") }
        if hasPassword { badge("Password", "key.fill") }
        if burn { badge(burned ? "Viewed" : "One-time", "flame.fill") }
        if let expires { badge("Expires \(expires.formatted(.relative(presentation: .named)))", "clock") }
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
        window.setContentSize(CGSize(width: 780, height: 560))
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
