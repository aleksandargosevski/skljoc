import AppKit
import SkljocCore
import SwiftUI

/// Asks for privacy, password, expiry and one-time viewing before an upload (or when changing them later).
@MainActor
final class UploadOptionsWindow {
    private var window: NSWindow?

    /// `keepsPassword` is for editing: an empty password field then means "leave it as it is".
    func ask(
        title: String, actionTitle: String, initial: UploadOptions, hasPassword: Bool = false,
        completion: @escaping (UploadOptions, _ passwordChanged: Bool) -> Void
    ) {
        window?.close()
        let model = UploadOptionsModel(options: initial, hasPassword: hasPassword)
        let view = UploadOptionsView(model: model, actionTitle: actionTitle, cancel: { [weak self] in
            self?.window?.close()
        }, confirm: { [weak self] in
            self?.window?.close()
            completion(model.options, model.passwordChanged)
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
    let hadPassword: Bool

    init(options: UploadOptions, hasPassword: Bool) {
        self.options = options
        self.hadPassword = hasPassword
        usePassword = hasPassword || !(options.password ?? "").isEmpty
    }

    var passwordChanged: Bool {
        usePassword ? !password.isEmpty : hadPassword
    }

    func finalize() {
        options.password = usePassword ? (password.isEmpty ? nil : password) : nil
    }
}

private struct UploadOptionsView: View {
    @ObservedObject var model: UploadOptionsModel
    let actionTitle: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        Form {
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
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    model.finalize()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.usePassword && !model.options.isPrivate && model.password.isEmpty && !model.hadPassword)
            }
            .padding([.horizontal, .bottom], 16)
        }
    }
}
