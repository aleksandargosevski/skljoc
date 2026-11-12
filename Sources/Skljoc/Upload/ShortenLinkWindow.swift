import AppKit
import SkljocCore
import SwiftUI

/// "Shorten Link…": a link (taken from the clipboard when there is one) and an optional name for it.
@MainActor
final class ShortenLinkWindow {
    var onShortened: ((ShortLink) -> Void)?

    private let service: UploadService
    private var window: NSWindow?

    init(service: UploadService) {
        self.service = service
    }

    func show() {
        window?.close()
        let model = ShortenLinkModel(prefix: service.linkPrefix ?? "")
        if case .shorten(let url) = LinkShortening.check(NSPasteboard.general.string(forType: .string), workerBase: service.client?.baseURL) {
            model.url = url.absoluteString
        }
        let view = ShortenLinkView(model: model, cancel: { [weak self] in
            self?.window?.close()
        }, shorten: { [weak self] in
            self?.shorten(model)
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Shorten Link"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func shorten(_ model: ShortenLinkModel) {
        guard case .shorten(let url) = LinkShortening.check(model.url, workerBase: service.client?.baseURL) else {
            model.problem = "Enter a full link starting with https://"
            return
        }
        if let problem = LinkSlug.problem(with: model.slug) {
            model.problem = problem
            return
        }
        guard let client = service.client else {
            model.problem = UploadError.notConfigured.localizedDescription
            return
        }
        model.isWorking = true
        Task {
            defer { model.isWorking = false }
            do {
                let link = try await client.shorten(url, slug: model.slug)
                window?.close()
                onShortened?(link)
            } catch UploadError.server(409, _) {
                model.problem = "\(model.prefix)\(LinkSlug.normalized(model.slug) ?? "") is already taken."
            } catch {
                model.problem = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class ShortenLinkModel: ObservableObject {
    @Published var url = ""
    @Published var slug = ""
    @Published var problem: String?
    @Published var isWorking = false
    let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }
}

private struct ShortenLinkView: View {
    @ObservedObject var model: ShortenLinkModel
    let cancel: () -> Void
    let shorten: () -> Void

    var body: some View {
        Form {
            TextField("Link", text: $model.url, prompt: Text("https://…"))
                .onChange(of: model.url) { model.problem = nil }
            LabeledContent("Short link") {
                HStack(spacing: 2) {
                    Text(model.prefix).foregroundStyle(.secondary)
                    TextField("random", text: $model.slug)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                        .onChange(of: model.slug) { model.problem = nil }
                }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Shorten & Copy", action: shorten)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.url.isEmpty)
            }
            .padding([.horizontal, .bottom], 16)
        }
    }
}
