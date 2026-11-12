import AppKit
import SkljocCore
import SwiftUI

/// What the settings window needs from the rest of the app.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var registrations: [ShortcutAction: HotKeyCenter.Registration] = [:]
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var launchAtLoginError: String?

    var setShortcut: (ShortcutAction, Shortcut?) -> Void = { _, _ in }
    var retryShortcuts: () -> Void = {}
    var setRecording: (Bool) -> Void = { _ in }
    var historyUsage: () -> Int64 = { 0 }
    var clearHistory: () -> Void = {}
    var applyRetention: () -> Void = {}
    @Published var uploadToken = ""
    @Published var uploadStatus: String?
    @Published var uploadStatusIsError = false
    @Published var isTestingUploads = false
    var saveUploadToken: (String) throws -> Void = { _ in }
    var testUploads: () async throws -> String = { "" }

    func commitUploadToken() {
        do {
            try saveUploadToken(uploadToken)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func runUploadTest() {
        commitUploadToken()
        isTestingUploads = true
        uploadStatus = nil
        Task {
            defer { isTestingUploads = false }
            do {
                let name = try await testUploads()
                show("Connected to \(name)", isError: false)
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func show(_ text: String, isError: Bool) {
        uploadStatus = text
        uploadStatusIsError = isError
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    shortcutRow(action)
                }
                if hasConflicts {
                    HStack {
                        Button("Open Keyboard Shortcuts…", action: SystemSettings.openKeyboardShortcuts)
                        Button("Try Again", action: model.retryShortcuts)
                    }
                }
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(preferences.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Format", selection: $preferences.format) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                Toggle("Export Retina screenshots at 1x (smaller files)", isOn: $preferences.exportAt1x)
            }

            Section("Capture") {
                Toggle("Play shutter sound", isOn: $preferences.playSound)
            }

            Section("Recording") {
                Picker("Frame rate", selection: $preferences.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Video codec", selection: $preferences.videoCodec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Record Retina screens at 1x (smaller files)", isOn: $preferences.recordAt1x)
                Toggle("Show the mouse pointer", isOn: $preferences.showCursor)
                Toggle("Count down 3-2-1 before recording", isOn: $preferences.countdown)
                Picker("GIF frame rate", selection: $preferences.gifFrameRate) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("GIF maximum width", selection: $preferences.gifMaxWidth) {
                    ForEach([480, 640, 800, 960, 1280], id: \.self) { Text("\($0) px").tag($0) }
                }
            }

            Section("General") {
                if LaunchAtLogin.isManagedByHomebrew {
                    Text("Installed with Homebrew: use `brew services start skljoc` to start at login.")
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.toggleLaunchAtLogin))
                    if let error = model.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Section("History") {
                Picker("Keep", selection: Binding(
                    get: { preferences.historyRetention },
                    set: { preferences.historyRetention = $0; model.applyRetention() }
                )) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Using") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: model.historyUsage(), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear History…", action: confirmClearHistory)
                    }
                }
            }

            Section {
                TextField("Worker address", text: $preferences.uploadBaseURL, prompt: Text("https://share.example.com"))
                    .textContentType(.URL)
                SecureField("Upload token", text: $model.uploadToken)
                    .onSubmit(model.commitUploadToken)
                HStack {
                    Button("Test Connection", action: model.runUploadTest)
                        .disabled(model.isTestingUploads || preferences.uploadBaseURL.isEmpty || model.uploadToken.isEmpty)
                    if model.isTestingUploads { ProgressView().controlSize(.small) }
                    if let status = model.uploadStatus {
                        Label(status, systemImage: model.uploadStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.uploadStatusIsError ? .orange : .green)
                            .font(.callout)
                            .lineLimit(2)
                    }
                }
                Picker("Copy", selection: $preferences.uploadLinkFormat) {
                    ForEach(UploadLinkFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Links expire", selection: $preferences.uploadExpiry) {
                    ForEach(UploadExpiry.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Upload")
            } footer: {
                Text("Uploads go to your own Cloudflare Worker and R2 bucket. [Set one up in a few minutes](https://github.com/aleksandargosevski/skljoc/tree/main/worker#readme). Option-click Upload to make a link private, password-protected, expiring or one-time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onDisappear(perform: model.commitUploadToken)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hasConflicts: Bool {
        model.registrations.values.contains { registration in
            switch registration {
            case .takenBySystem, .takenByOtherApp: true
            default: false
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            ShortcutRecorder(
                shortcut: preferences.shortcut(for: action),
                onChange: { model.setShortcut(action, $0) },
                onRecordingChange: model.setRecording
            )
        }
        if let problem = problemText(for: model.registrations[action]) {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func problemText(for registration: HotKeyCenter.Registration?) -> String? {
        switch registration {
        case .takenBySystem(let name):
            "macOS uses this shortcut for “\(name)”. Turn it off under Keyboard Shortcuts → Screenshots."
        case .takenByOtherApp:
            "Another app (CleanShot?) already uses this shortcut. Turn it off there, then try again."
        case .invalid:
            "This shortcut can't be used globally."
        default:
            nil
        }
    }

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all screenshots and recordings in History?"
        alert.informativeText = "Files you saved or copied elsewhere stay where they are."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            model.clearHistory()
            model.objectWillChange.send()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveFolder = url
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel, preferences: Preferences) {
        let hosting = NSHostingController(rootView: SettingsView(model: model, preferences: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Škljoc Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
