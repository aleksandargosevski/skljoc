import AppKit
import SkljocCore
import SwiftUI

/// Asks for the link name, privacy, password, expiry and one-time viewing before an upload
/// (or when changing them later).
@MainActor
final class UploadOptionsWindow {
    private var window: NSWindow?

    /// - Parameters:
    ///   - linkPrefix: shown before the name field, e.g. "gosev.ski/". Nil hides the field.
    ///   - hasPassword: for editing; an empty password field then means "leave it as it is".
    ///   - checkName: returns why a chosen name can't be used (taken, offline…), or nil when it can.
    func ask(
        title: String, actionTitle: String, initial: UploadOptions, hasPassword: Bool = false,
        linkPrefix: String? = nil, checkName: ((String) async -> String?)? = nil,
        completion: @escaping (UploadOptions, _ passwordChanged: Bool) -> Void
    ) {
        window?.close()
        let model = UploadOptionsModel(options: initial, hasPassword: hasPassword, linkPrefix: linkPrefix)
        let view = UploadOptionsView(model: model, actionTitle: actionTitle, cancel: { [weak self] in
            self?.window?.close()
        }, confirm: { [weak self] in
            model.finalize()
            if let problem = LinkSlug.problem(with: model.options.slug) {
                model.nameProblem = problem
                return
            }
            guard let slug = LinkSlug.normalized(model.options.slug), slug != model.initialSlug, let checkName else {
                self?.window?.close()
                completion(model.options, model.passwordChanged)
                return
            }
            model.isChecking = true
            Task {
                let problem = await checkName(slug)
                model.isChecking = false
                if let problem {
                    model.nameProblem = problem
                } else {
                    self?.window?.close()
                    completion(model.options, model.passwordChanged)
                }
            }
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class UploadOptionsModel: ObservableObject {
    @Published var options: UploadOptions
    @Published var password = ""
    @Published var usePassword: Bool
    @Published var nameProblem: String?
    @Published var isChecking = false
    let hadPassword: Bool
    let linkPrefix: String?
    let initialSlug: String?

    init(options: UploadOptions, hasPassword: Bool, linkPrefix: String?) {
        self.options = options
        self.hadPassword = hasPassword
        self.linkPrefix = linkPrefix
        initialSlug = LinkSlug.normalized(options.slug)
        usePassword = hasPassword || !(options.password ?? "").isEmpty
    }

    var passwordChanged: Bool {
        usePassword ? !password.isEmpty : hadPassword
    }

    func finalize() {
        options.password = usePassword ? (password.isEmpty ? nil : password) : nil
        options.slug = LinkSlug.normalized(options.slug)
    }
}

private struct UploadOptionsView: View {
    @ObservedObject var model: UploadOptionsModel
    let actionTitle: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        Form {
            if let prefix = model.linkPrefix {
                LabeledContent("Link") {
                    HStack(spacing: 2) {
                        Text(prefix).foregroundStyle(.secondary)
                        TextField("random", text: Binding(
                            get: { model.options.slug ?? "" },
                            set: { model.options.slug = $0; model.nameProblem = nil }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                    }
                }
                if let problem = model.nameProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Toggle("Private: only you can open it", isOn: $model.options.isPrivate)
            Toggle("Require a password", isOn: $model.usePassword)
                .disabled(model.options.isPrivate)
            if model.usePassword && !model.options.isPrivate {
                SecureField(model.hadPassword ? "Leave empty to keep the current one" : "Password", text: $model.password)
            }
            Picker("Expires", selection: $model.options.expiry) {
                ForEach(UploadExpiry.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Delete after the first view", isOn: $model.options.burnAfterViewing)
                .disabled(model.options.isPrivate)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(actionTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking || (model.usePassword && !model.options.isPrivate && model.password.isEmpty && !model.hadPassword))
            }
            .padding([.horizontal, .bottom], 16)
        }
    }
}
