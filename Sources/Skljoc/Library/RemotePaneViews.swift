import AppKit
import SkljocCore
import SwiftUI

struct FilesPaneView: View {
    @ObservedObject var pane: FilesPane
    var setUp: () -> Void

    var body: some View {
        RemoteListView(pane: pane, setUp: setUp, emptyTitle: "No Uploads Yet", emptySymbol: "icloud.and.arrow.up",
                       emptyText: "Uploaded screenshots, recordings and files show up here.") { upload in
            UploadRow(pane: pane, upload: upload)
        }
    }
}

struct LinksPaneView: View {
    @ObservedObject var pane: LinksPane
    var setUp: () -> Void

    var body: some View {
        RemoteListView(pane: pane, setUp: setUp, emptyTitle: "No Short Links Yet", emptySymbol: "link",
                       emptyText: "Links shortened with Škljoc show up here.") { link in
            LinkRow(pane: pane, link: link)
        }
    }
}

/// The list part both remote tabs share: setup, errors, empty states, selection and paging.
private struct RemoteListView<Item: Identifiable & Equatable, Row: View>: View where Item.ID == String {
    @ObservedObject var pane: RemoteList<Item>
    var setUp: () -> Void
    let emptyTitle: String
    let emptySymbol: String
    let emptyText: String
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(countText).foregroundStyle(.secondary)
                Spacer()
                if pane.isLoading { ProgressView().controlSize(.small) }
                Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(!pane.isConfigured)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()
            content.frame(maxHeight: .infinity)
        }
    }

    private var countText: String {
        let count = pane.visibleItems.count
        let more = pane.nextOffset == nil ? "" : "+"
        return pane.query.isEmpty ? "\(count)\(more)" : "\(count)\(more) found"
    }

    @ViewBuilder private var content: some View {
        if !pane.isConfigured {
            ContentUnavailableView {
                Label("Uploads Aren't Set Up", systemImage: "icloud.slash")
            } description: {
                Text("Put screenshots and files on your own Cloudflare Worker and share links to them.")
            } actions: {
                Button("Set Up Uploads…", action: setUp)
            }
        } else if let error = pane.errorText {
            ContentUnavailableView("Can't Reach Your Worker", systemImage: "icloud.slash", description: Text(error))
        } else if pane.visibleItems.isEmpty && !pane.isLoading {
            if pane.query.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyText))
            } else {
                ContentUnavailableView.search(text: pane.query)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(pane.visibleItems) { item in
                            row(item)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(background(for: item.id)))
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { pane.click(item.id) })
                                .id(item.id)
                                .onAppear { if item.id == pane.visibleItems.last?.id { pane.loadMore() } }
                        }
                        if pane.nextOffset != nil {
                            Button("Load More") { pane.loadMore() }.padding(8)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: pane.selection.focused) { _, focused in
                    if let focused { proxy.scrollTo(focused) }
                }
            }
        }
    }

    private func background(for id: String) -> Color {
        guard pane.selection.contains(id) else { return .clear }
        return Color.accentColor.opacity(pane.selection.focused == id ? 0.28 : 0.15)
    }
}

private struct UploadRow: View {
    @ObservedObject var pane: FilesPane
    let upload: UploadedFile

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: pane.thumbnailURL(for: upload)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: Self.symbol(for: upload.contentType)).foregroundStyle(.secondary)
            }
            .frame(width: 72, height: 48)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if pane.downloading.contains(upload.id) {
                    ProgressView().controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.filename).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(pane.worker.linkPrefix)\(upload.id)").foregroundStyle(.primary.opacity(0.7))
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
        }
        .onTapGesture(count: 2) { pane.open(upload) }
        .contextMenu {
            Button("Copy Link") { pane.worker.copy([pane.worker.service.linkText(for: upload)]) }
            Button("Open in Browser") { pane.open(upload) }
            Button("Rename Link…") { pane.worker.rename(id: upload.id) }
            Button("Link Options…") { pane.worker.editOptions(upload) }
            Divider()
            Button("Delete…", role: .destructive) { pane.delete([(upload.id, upload.filename)]) }
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
    @ObservedObject var pane: LinksPane
    let link: ShortLink

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(LinksPane.displayName(link)).font(.body.weight(.medium))
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
        }
        .onTapGesture(count: 2) { pane.worker.copy([link.url.absoluteString]) }
        .contextMenu {
            Button("Copy Link") { pane.worker.copy([link.url.absoluteString]) }
            Button("Open Destination") { NSWorkspace.shared.open(link.targetURL) }
            Button("Rename Link…") { pane.worker.rename(id: link.id) }
            Button("Change Destination…") { pane.worker.changeDestination(link) }
            Button("Link Options…") { pane.worker.editOptions(link) }
            Divider()
            Button("Delete…", role: .destructive) { pane.delete([(link.id, LinksPane.displayName(link))]) }
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
