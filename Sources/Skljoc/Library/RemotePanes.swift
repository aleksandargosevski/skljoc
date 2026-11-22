import AppKit
import SkljocCore
import SwiftUI

/// Uploaded files on the user's Worker, with Quick Look, copy, options, rename and delete.
@MainActor
final class FilesPane: RemoteList<UploadedFile> {
    /// Bigger files open in the browser instead of downloading for Quick Look.
    static let quickLookLimit = 100 * 1024 * 1024

    @Published private(set) var downloading: Set<String> = []
    let quickLook: QuickLookController
    private var thumbnailURLs: [String: (url: URL, made: Date)] = [:]

    init(worker: WorkerActions, quickLook: QuickLookController) {
        self.quickLook = quickLook
        super.init(worker: worker) { client, offset, query in
            let page = try await client.list(offset: offset, query: query)
            return (page.uploads, page.nextOffset)
        } matches: { upload, query in
            [upload.id, upload.filename].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    override func commands() -> [LibraryCommand] {
        focusedItem == nil ? [] : [.copy, .edit, .quickLook, .reveal, .rename, .delete]
    }

    override var defaultCommand: LibraryCommand? { .reveal }

    override func perform(_ command: LibraryCommand) {
        guard let focused = focusedItem else { return }
        let selected = selectedItems
        switch command {
        case .copy: worker.copy(selected.map { worker.service.linkText(for: $0) })
        case .edit: worker.editOptions(focused)
        case .quickLook: toggleQuickLook(focused)
        case .reveal: selected.forEach(open)
        case .rename: worker.rename(id: focused.id)
        case .delete: delete(selected.map { ($0.id, $0.filename) })
        default: break
        }
    }

    override func selectionDidMove() {
        guard quickLook.isVisible else { return }
        if let focused = focusedItem { preview(focused) } else { quickLook.close() }
    }

    func open(_ upload: UploadedFile) {
        guard let client = worker.client else { return }
        NSWorkspace.shared.open(client.ownerURL(for: upload))
    }

    /// Images (and video posters) for the list; signed, so private ones show too.
    /// Kept for a while, since a new signature would make the image load again on every redraw.
    func thumbnailURL(for upload: UploadedFile) -> URL? {
        if let cached = thumbnailURLs[upload.id], cached.made.timeIntervalSinceNow > -1800 { return cached.url }
        let url = makeThumbnailURL(for: upload)
        if let url { thumbnailURLs[upload.id] = (url, Date()) }
        return url
    }

    private func makeThumbnailURL(for upload: UploadedFile) -> URL? {
        guard let client = worker.client else { return nil }
        if upload.isVideo {
            guard upload.hasPoster else { return nil }
            let poster = upload.url.appendingPathComponent("poster.jpg")
            return UploadLinks.signed(poster, id: upload.id, token: client.token, expires: Date().addingTimeInterval(3600))
        }
        return upload.contentType.hasPrefix("image/") ? client.ownerURL(for: upload, raw: true) : nil
    }

    // MARK: Quick Look

    private func toggleQuickLook(_ upload: UploadedFile) {
        if quickLook.isVisible {
            quickLook.close()
        } else {
            preview(upload)
        }
    }

    /// Shows the file in Quick Look, downloading it once into a temporary folder.
    private func preview(_ upload: UploadedFile) {
        guard upload.size <= Self.quickLookLimit else {
            quickLook.close()
            open(upload)
            return
        }
        let local = Self.previewURL(for: upload)
        if FileManager.default.fileExists(atPath: local.path) {
            quickLook.show(local)
            return
        }
        guard let client = worker.client, !downloading.contains(upload.id) else { return }
        downloading.insert(upload.id)
        Task {
            defer { downloading.remove(upload.id) }
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: client.ownerURL(for: upload, raw: true))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw UploadError.server((response as? HTTPURLResponse)?.statusCode ?? 0, "Could not download \(upload.filename)")
                }
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: downloaded, to: local)
                if selection.focused == upload.id { quickLook.show(local) }
            } catch {
                TextPrompt.show("Could not preview \(upload.filename): \(error.localizedDescription)")
            }
        }
    }

    private static func previewURL(for upload: UploadedFile) -> URL {
        let fallback = upload.rawURL.pathExtension.isEmpty ? upload.id : "\(upload.id).\(upload.rawURL.pathExtension)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Skljoc Quick Look", isDirectory: true)
            .appendingPathComponent("\(upload.id)-\(upload.createdAt)", isDirectory: true)
            .appendingPathComponent(CaptureFileName.safeName(upload.filename) ?? fallback)
    }
}

/// Short links on the user's Worker.
@MainActor
final class LinksPane: RemoteList<ShortLink> {
    init(worker: WorkerActions) {
        super.init(worker: worker) { client, offset, query in
            let page = try await client.listLinks(offset: offset, query: query)
            return (page.links, page.nextOffset)
        } matches: { link, query in
            [link.id, link.targetURL.absoluteString].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    override func commands() -> [LibraryCommand] {
        focusedItem == nil ? [] : [.copy, .edit, .reveal, .rename, .changeDestination, .delete]
    }

    override var defaultCommand: LibraryCommand? { .copy }

    override func perform(_ command: LibraryCommand) {
        guard let focused = focusedItem else { return }
        let selected = selectedItems
        switch command {
        case .copy: worker.copy(selected.map(\.url.absoluteString))
        case .edit: worker.editOptions(focused)
        case .reveal: selected.forEach { NSWorkspace.shared.open($0.targetURL) }
        case .rename: worker.rename(id: focused.id)
        case .changeDestination: worker.changeDestination(focused)
        case .delete: delete(selected.map { ($0.id, Self.displayName($0)) })
        default: break
        }
    }

    static func displayName(_ link: ShortLink) -> String {
        "\(link.url.host() ?? "")\(link.url.path())"
    }
}

/// A list loaded page by page from the Worker. While searching, what is loaded is filtered at once,
/// and the Worker is asked for the rest after a short pause.
@MainActor
class RemoteList<Item: Identifiable & Equatable>: SelectableList<Item>, LibraryPaneControl where Item.ID == String {
    typealias Fetch = (UploadClient, _ offset: Int, _ query: String) async throws -> ([Item], Int?)

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var nextOffset: Int?
    /// Checked when loading rather than on every redraw, since it reads the keychain.
    @Published private(set) var isConfigured = true

    let worker: WorkerActions
    private let fetch: Fetch
    private let matches: (Item, String) -> Bool
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(worker: WorkerActions, fetch: @escaping Fetch, matches: @escaping (Item, String) -> Bool) {
        self.worker = worker
        self.fetch = fetch
        self.matches = matches
        super.init()
        worker.changed.append { [weak self] in self?.reload() }
    }


    override var visibleItems: [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matches($0, trimmed) }
    }

    func activate() {
        reload()
    }

    func reload() {
        load(offset: 0)
    }

    func loadMore() {
        guard let nextOffset, !isLoading else { return }
        load(offset: nextOffset)
    }

    func commands() -> [LibraryCommand] { [] }
    var defaultCommand: LibraryCommand? { nil }
    func perform(_ command: LibraryCommand) {}

    override func queryDidChange() {
        focusFirst()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.load(offset: 0)
        }
    }

    /// Asks once for all of them, then focuses what comes next.
    func delete(_ targets: [(id: String, name: String)]) {
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        worker.confirmDelete(names: targets.map(\.name), ids: ids) { [weak self] in
            self?.focusAfterRemoving(Set(ids))
        }
    }

    private func load(offset: Int) {
        guard let client = worker.client else {
            isConfigured = false
            errorText = nil
            items = []
            nextOffset = nil
            return
        }
        isConfigured = true
        generation += 1
        let current = generation
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        errorText = nil
        Task {
            do {
                let (page, next) = try await fetch(client, offset, query)
                guard current == generation else { return }
                let wasEmpty = selection.focused == nil
                items = offset == 0 ? page : items + page
                nextOffset = next
                reconcileSelection()
                if wasEmpty { selectionDidMove() }
            } catch {
                guard current == generation else { return }
                errorText = error.localizedDescription
            }
            if current == generation { isLoading = false }
        }
    }
}

/// Calls to the Worker that files and links share: options, rename, delete and copy.
@MainActor
final class WorkerActions {
    let service: UploadService
    private let optionsWindow = UploadOptionsWindow()
    var onCopied: ((Int) -> Void)?
    /// Called after something changed on the Worker, so the lists reload.
    var changed: [() -> Void] = []

    init(service: UploadService) {
        self.service = service
    }

    var client: UploadClient? { service.client }
    var linkPrefix: String { service.linkPrefix ?? "" }

    func copy(_ links: [String]) {
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        onCopied?(links.count)
    }

    func editOptions(_ upload: UploadedFile) {
        editOptions(id: upload.id, isPrivate: upload.isPrivate, burn: upload.burn, hasPassword: upload.hasPassword, hasExpiry: upload.expiresAt != nil)
    }

    func editOptions(_ link: ShortLink) {
        editOptions(id: link.id, isPrivate: link.isPrivate ?? false, burn: link.burn ?? false, hasPassword: link.hasPassword ?? false, hasExpiry: link.expiresAt != nil)
    }

    func changeDestination(_ link: ShortLink) {
        guard let text = TextPrompt.ask(
            title: "Change where \(LinksPane.displayName(link)) goes",
            message: "Visitors are sent to this address from now on. Views so far are kept.",
            initial: link.targetURL.absoluteString
        ) else { return }
        guard case .shorten(let url) = LinkShortening.check(text, workerBase: client?.baseURL) else {
            TextPrompt.show("Enter a full link starting with https://")
            return
        }
        change { try await $0.updateLink(link.id, ["url": url.absoluteString]) }
    }

    /// Gives a file or link a new name. The old address stops working; views and options stay.
    func rename(id: String) {
        guard let text = TextPrompt.ask(
            title: "Rename \(linkPrefix)\(id)",
            message: "The old address stops working. Views and options stay.",
            initial: id, prefix: linkPrefix
        ), let slug = LinkSlug.normalized(text), slug != id else { return }
        if let problem = LinkSlug.problem(with: slug) {
            TextPrompt.show(problem)
            return
        }
        change { try await $0.updateLink(id, ["slug": slug]) }
    }

    func confirmDelete(names: [String], ids: [String], willDelete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Delete “\(names[0])” from your Worker?" : "Delete \(names.count) items from your Worker?"
        alert.informativeText = names.count == 1
            ? "The link stops working for everyone. This can't be undone."
            : "Their links stop working for everyone. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.makeFirstButtonDestructive()
        guard alert.runModal() == .alertFirstButtonReturn, let client else { return }
        willDelete()
        Task {
            var failures: [String] = []
            for (id, name) in zip(ids, names) {
                do {
                    try await client.deleteLink(id)
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            notifyChanged()
            if !failures.isEmpty { TextPrompt.show("Could not delete:\n" + failures.joined(separator: "\n")) }
        }
    }

    func notifyChanged() {
        changed.forEach { $0() }
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
            self?.change { try await $0.updateLink(id, payload) }
        }
    }

    private func change(_ body: @escaping (UploadClient) async throws -> UploadClient.LinkSummary) {
        guard let client else { return }
        Task {
            do {
                _ = try await body(client)
                notifyChanged()
            } catch UploadError.server(409, let message) {
                TextPrompt.show(message)
            } catch {
                TextPrompt.show(error.localizedDescription)
            }
        }
    }
}
