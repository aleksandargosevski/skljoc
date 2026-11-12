import AppKit
import SkljocCore

/// Connects shortcuts, capturing, recording, previews, the editors and exporting.
@MainActor
final class AppCoordinator {
    let preferences = Preferences.shared
    let store = CaptureStore()
    private(set) lazy var recorder = RecordingController(preferences: preferences, store: store)
    private lazy var scrolling = ScrollingCaptureController(preferences: preferences, store: store, hotKeys: hotKeys)
    private let hotKeys = HotKeyCenter()
    private let captureService = CaptureService()
    private let toast = Toast()
    private let settingsModel = SettingsModel()
    private lazy var previews = PreviewStack(hotKeys: hotKeys)
    private lazy var recordingExporter = RecordingExporter(preferences: preferences)
    private var settingsWindow: SettingsWindowController?
    private var editors: [UUID: EditorWindowController] = [:]
    private var videoEditors: [UUID: VideoEditorWindowController] = [:]
    private var pins: [UUID: PinWindowController] = [:]
    private var historyWindow: HistoryWindowController?
    private var uploadsWindow: UploadsWindowController?
    private lazy var uploads = UploadService(preferences: preferences)
    private let uploadOptions = UploadOptionsWindow()

    func start() {
        settingsModel.setShortcut = { [unowned self] action, shortcut in
            preferences.setShortcut(shortcut, for: action)
            registerShortcuts()
        }
        settingsModel.retryShortcuts = { [unowned self] in registerShortcuts() }
        settingsModel.setRecording = { [unowned self] recording in
            recording ? hotKeys.suspend() : hotKeys.resume()
        }
        recorder.onFinished = { [unowned self] url, _ in recordingFinished(url) }
        recorder.onError = { [unowned self] error, title in presentError(error, title: title) }
        recorder.needsScreenRecordingPermission = { [unowned self] in explainScreenRecordingPermission() }
        recorder.onPermissionProblem = { [unowned self] in explainPermission($0) }
        scrolling.onFinished = { [unowned self] url in captured(url) }
        scrolling.onError = { [unowned self] error, title in presentError(error, title: title) }
        scrolling.needsScreenRecordingPermission = { [unowned self] in explainScreenRecordingPermission() }
        store.retention = { [unowned self] in preferences.historyRetention }
        settingsModel.historyUsage = { [unowned self] in store.diskUsage() }
        settingsModel.clearHistory = { [unowned self] in store.clear() }
        settingsModel.applyRetention = { [unowned self] in store.prune(); store.onChange?() }
        settingsModel.saveUploadToken = { token in
            try Keychain.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: UploadService.keychainAccount)
        }
        settingsModel.testUploads = { [unowned self] in
            guard let client = uploads.client else { throw UploadError.notConfigured }
            let health = try await client.health()
            return health.siteName ?? client.baseURL.host() ?? "your Worker"
        }
        store.onChange = { [weak self] in self?.historyWindow?.model.reload() }
        store.prune()
        store.indexText()

        registerShortcuts()
        if hasShortcutConflicts { explainShortcutConflict() }
    }

    var hasShortcutConflicts: Bool {
        settingsModel.registrations.values.contains { $0 != .registered && $0 != .cleared }
    }

    func registerShortcuts() {
        for action in ShortcutAction.allCases {
            settingsModel.registrations[action] = hotKeys.register(
                id: action.hotKeyID,
                shortcut: preferences.shortcut(for: action)
            ) { [unowned self] in perform(action) }
        }
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .captureArea: capture(.area)
        case .captureFullscreen: capture(.fullscreen)
        case .captureText: captureText()
        case .captureAndPin: capture(.area) { [unowned self] in pin($0) }
        case .scrollingCapture: scrolling.state == .idle ? scrolling.begin() : scrolling.finish()
        case .recordScreen: recorder.toggle()
        case .shortenLink: shortenClipboardLink()
        case .history: showHistory()
        }
    }

    // MARK: Screenshots

    /// Takes a screenshot and shows its preview, or hands it to `then` instead.
    func capture(_ mode: CaptureMode, then: ((Capture) -> Void)? = nil) {
        guard canCapture else { return }
        Task {
            do {
                let url = try store.newCaptureURL()
                guard try await captureService.capture(mode, to: url, playSound: preferences.playSound) else { return }
                let capture = try Capture(fileURL: url)
                store.add(capture)
                if let then { then(capture) } else { showPreview(capture) }
            } catch {
                presentError(error, title: "Screenshot failed")
            }
        }
    }

    /// Recognizes the text in a picked area and copies it, without keeping a screenshot.
    func captureText() {
        guard canCapture else { return }
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("skljoc-text-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                guard try await captureService.capture(.area, to: url, playSound: false) else { return }
                let capture = try Capture(fileURL: url)
                try await copyRecognizedText(from: capture.image)
            } catch {
                presentError(error, title: "Could not read the text")
            }
        }
    }

    private var canCapture: Bool {
        guard !captureService.isCapturing, recorder.state == .idle, scrolling.state == .idle else { return false }
        guard ScreenRecordingPermission.ensure() else {
            explainScreenRecordingPermission()
            return false
        }
        return true
    }

    private func captured(_ url: URL) {
        do {
            let capture = try Capture(fileURL: url)
            store.add(capture)
            showPreview(capture)
        } catch {
            presentError(error, title: "Could not open the screenshot")
        }
    }

    private func copyRecognizedText(from image: CGImage) async throws {
        let text = try await TextRecognizer.text(in: image)
        guard !text.isEmpty else {
            toast.show("No text found", systemImage: "text.viewfinder")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        toast.show(lines == 1 ? "Copied text" : "Copied \(lines) lines of text", systemImage: "text.viewfinder")
    }

    private func copyText(_ capture: Capture) {
        Task {
            do {
                try await copyRecognizedText(from: capture.renderedImage())
            } catch {
                presentError(error, title: "Could not read the text")
            }
        }
    }

    // MARK: Pins

    private func pin(_ capture: Capture) {
        previews.remove(capture)
        if let existing = pins[capture.id] {
            existing.refresh()
            existing.show()
            return
        }
        let pin = PinWindowController(capture: capture, handlers: .init(
            copy: { [unowned self] in copyKeepingPreview($0) },
            save: { [unowned self] in save($0) },
            edit: { [unowned self] in edit($0) },
            closed: { [unowned self] capture in
                DispatchQueue.main.async { self.pins[capture.id] = nil }
            }
        ))
        pins[capture.id] = pin
        pin.show()
    }

    private func copyKeepingPreview(_ capture: Capture) {
        do {
            try Exporter.copy(capture, preferences: preferences)
            toast.show("Copied", systemImage: "doc.on.doc")
        } catch {
            presentError(error, title: "Could not copy the screenshot")
        }
    }

    // MARK: History

    func showHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(model: HistoryModel(store: store, actions: .init(
                open: { [unowned self] entry in withItem(entry) { [unowned self] in openInEditor($0) } },
                copy: { [unowned self] entry in
                    withItem(entry) { [unowned self] item in
                        switch item {
                        case .screenshot(let capture): copyKeepingPreview(capture)
                        case .recording(let recording): copy(recording)
                        }
                    }
                },
                save: { [unowned self] entry in
                    withItem(entry) { [unowned self] item in
                        switch item {
                        case .screenshot(let capture): save(capture)
                        case .recording(let recording): save(recording)
                        }
                    }
                },
                pin: { [unowned self] entry in
                    withItem(entry) { [unowned self] item in
                        if case .screenshot(let capture) = item { pin(capture) }
                    }
                },
                delete: { [unowned self] entry in store.delete(entry) },
                dragItem: { entry in
                    let provider = NSItemProvider(contentsOf: entry.url) ?? NSItemProvider()
                    provider.suggestedName = CaptureFileName.make(date: entry.date, fileExtension: entry.url.pathExtension)
                    return provider
                }
            )))
        }
        historyWindow?.present()
    }

    private func withItem(_ entry: HistoryEntry, _ body: @escaping (MediaItem) -> Void) {
        Task {
            guard let item = await store.item(for: entry) else {
                presentError(CaptureLoadError.unreadable(entry.url), title: "Could not open it")
                return
            }
            body(item)
        }
    }

    private func openInEditor(_ item: MediaItem) {
        switch item {
        case .screenshot(let capture): edit(capture)
        case .recording(let recording): edit(recording)
        }
    }

    func showRecent(_ item: MediaItem) {
        switch item {
        case .screenshot(let capture):
            if let editor = editors[capture.id] { editor.present() } else { showPreview(capture) }
        case .recording(let recording):
            if let editor = videoEditors[recording.id] { editor.present() } else { showPreview(recording) }
        }
    }

    private func showPreview(_ capture: Capture) {
        let content = PreviewContent(thumbnail: capture.thumbnail(), size: capture.document.outputSize)
        previews.show(capture, content: content, handlers: .init(
            copy: { [unowned self] in copy(capture) },
            save: { [unowned self] in save(capture) },
            saveAs: { [unowned self] in saveAs(capture) },
            upload: { [unowned self] in startUpload(.screenshot(capture)) },
            edit: { [unowned self] in edit(capture) },
            dragItem: { [unowned self] in dragItem(for: capture) },
            pin: { [unowned self] in pin(capture) },
            copyText: { [unowned self] in copyText(capture) },
            uploadWithOptions: { [unowned self] in askUploadOptions(.screenshot(capture)) }
        ))
    }

    private func copy(_ capture: Capture) {
        do {
            try Exporter.copy(capture, preferences: preferences)
            previews.remove(capture)
            toast.show("Copied", systemImage: "doc.on.doc")
        } catch {
            presentError(error, title: "Could not copy the screenshot")
        }
    }

    private func save(_ capture: Capture) {
        do {
            let url = try Exporter.save(capture, preferences: preferences)
            previews.remove(capture)
            showSavedToast(url)
        } catch {
            presentError(error, title: "Could not save the screenshot")
        }
    }

    private func saveAs(_ capture: Capture) {
        do {
            guard let url = try Exporter.saveAs(capture, preferences: preferences) else { return }
            previews.remove(capture)
            showSavedToast(url, showsName: true)
        } catch {
            presentError(error, title: "Could not save the screenshot")
        }
    }

    private func edit(_ capture: Capture) {
        previews.remove(capture)
        if let editor = editors[capture.id] {
            editor.present()
            return
        }
        let editor = EditorWindowController(capture: capture, handlers: .init(
            copy: { [unowned self] in copy($0) },
            save: { [unowned self] in save($0) },
            saveAs: { [unowned self] in saveAs($0) },
            upload: { [unowned self] in startUpload(.screenshot($0)) },
            dragItem: { [unowned self] in dragItem(for: $0) },
            done: { [unowned self] capture in
                if let pin = pins[capture.id] { pin.refresh() } else { showPreview(capture) }
            },
            closed: { [unowned self] capture in
                DispatchQueue.main.async { self.editors[capture.id] = nil }
            },
            pin: { [unowned self] in pin($0) },
            copyText: { [unowned self] in copyText($0) }
        ))
        editors[capture.id] = editor
        editor.present()
    }

    private func dragItem(for capture: Capture) -> NSItemProvider {
        do {
            let url = try Exporter.temporaryFile(for: capture, preferences: preferences)
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
            provider.suggestedName = url.deletingPathExtension().lastPathComponent
            return provider
        } catch {
            presentError(error, title: "Could not prepare the screenshot for dragging")
            return NSItemProvider()
        }
    }

    // MARK: Recordings

    private func recordingFinished(_ url: URL) {
        Task {
            do {
                let recording = try await Recording.load(fileURL: url)
                store.add(recording)
                showPreview(recording)
                prepareExport(recording)
            } catch {
                presentError(error, title: "Could not open the recording")
            }
        }
    }

    private func showPreview(_ recording: Recording) {
        // Until the edits are rendered, hovering shows nothing rather than the unedited recording.
        let plainVideo = recording.edit.format == .video && !recording.edit.needsRendering
        let content = PreviewContent(
            thumbnail: recording.thumbnail,
            size: recording.edit.resolution.size(for: recording.naturalSize),
            badge: recording.badge,
            videoURL: plainVideo ? recording.fileURL : nil
        )
        previews.show(recording, content: content, handlers: .init(
            copy: { [unowned self] in copy(recording) },
            save: { [unowned self] in save(recording) },
            saveAs: { [unowned self] in saveAs(recording) },
            upload: { [unowned self] in startUpload(.recording(recording)) },
            edit: { [unowned self] in edit(recording) },
            dragItem: { [unowned self] in recordingExporter.dragItem(for: recording) },
            uploadWithOptions: { [unowned self] in askUploadOptions(.recording(recording)) }
        ))
    }

    /// Renders the edits in the background, then shows them in the preview.
    private func prepareExport(_ recording: Recording) {
        recordingExporter.prepare(recording) { [weak self] url in
            Task { @MainActor in
                guard let self else { return }
                if let thumbnail = await Recording.thumbnail(ofExport: url) { recording.thumbnail = thumbnail }
                self.previews.update(recording, content: PreviewContent(
                    thumbnail: recording.thumbnail,
                    size: recording.edit.resolution.size(for: recording.naturalSize),
                    badge: recording.badge,
                    videoURL: recording.edit.format == .video ? url : nil
                ))
            }
        }
    }

    private func copy(_ recording: Recording) {
        runExport(recording, failure: "Could not copy the recording") { [self] in
            try await recordingExporter.copy(recording)
            previews.remove(recording)
            toast.show("Copied", systemImage: "doc.on.doc")
        }
    }

    private func save(_ recording: Recording) {
        runExport(recording, failure: "Could not save the recording") { [self] in
            let url = try await recordingExporter.save(recording)
            previews.remove(recording)
            showSavedToast(url)
        }
    }

    private func saveAs(_ recording: Recording) {
        runExport(recording, failure: "Could not save the recording") { [self] in
            guard let url = try await recordingExporter.saveAs(recording) else { return }
            previews.remove(recording)
            showSavedToast(url, showsName: true)
        }
    }

    private func runExport(_ recording: Recording, failure: String, _ body: @escaping () async throws -> Void) {
        previews.setBusy(recording, "Exporting…")
        Task {
            defer { previews.setBusy(recording, nil) }
            do {
                try await body()
            } catch {
                presentError(error, title: failure)
            }
        }
    }

    private func edit(_ recording: Recording) {
        previews.remove(recording)
        if let editor = videoEditors[recording.id] {
            editor.present()
            return
        }
        let editor = VideoEditorWindowController(recording: recording, handlers: .init(
            copy: { [unowned self] in copy($0) },
            save: { [unowned self] in save($0) },
            saveAs: { [unowned self] in saveAs($0) },
            upload: { [unowned self] in startUpload(.recording($0)) },
            dragItem: { [unowned self] in recordingExporter.dragItem(for: $0) },
            done: { [unowned self] recording in
                showPreview(recording)
                prepareExport(recording)
            },
            closed: { [unowned self] recording in
                DispatchQueue.main.async { self.videoEditors[recording.id] = nil }
            }
        ))
        videoEditors[recording.id] = editor
        editor.present()
    }

    // MARK: Shared

    // MARK: Uploads

    /// Uploads with the default options; with ⌥ held, asks for options first.
    private func startUpload(_ item: MediaItem) {
        if NSEvent.modifierFlags.contains(.option) {
            askUploadOptions(item)
        } else {
            upload(item, options: uploads.defaultOptions)
        }
    }

    private func askUploadOptions(_ item: MediaItem) {
        guard ensureUploadsConfigured() else { return }
        uploadOptions.ask(title: "Upload", actionTitle: "Upload", initial: uploads.defaultOptions) { [weak self] options, _ in
            self?.upload(item, options: options)
        }
    }

    private func upload(_ item: MediaItem, options: UploadOptions) {
        guard ensureUploadsConfigured() else { return }
        let owner: AnyObject
        switch item {
        case .screenshot(let capture): owner = capture
        case .recording(let recording): owner = recording
        }
        previews.setBusy(owner, "Uploading…")
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.previews.setBusy(owner, "Uploading \(Int(fraction * 100))%") }
        }
        Task {
            defer { previews.setBusy(owner, nil) }
            do {
                let uploaded: UploadedFile
                switch item {
                case .screenshot(let capture):
                    uploaded = try await uploadScreenshot(capture, options: options, progress: progress)
                case .recording(let recording):
                    previews.setBusy(owner, "Exporting…")
                    uploaded = try await uploadRecording(recording, options: options, progress: progress)
                }
                let link = uploads.copyLink(for: uploaded)
                previews.remove(owner)
                let message = uploaded.isPrivate ? "Private link copied (works for you for an hour)" : "Link copied"
                toast.show(message, systemImage: "link") {
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                }
            } catch {
                presentError(error, title: "Upload failed")
            }
        }
    }

    private func uploadScreenshot(_ capture: Capture, options: UploadOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile {
        let file = try Exporter.temporaryFile(for: capture, preferences: preferences)
        let scale = preferences.exportAt1x ? 1 : capture.scale
        let size = capture.document.outputSize
        return try await uploads.upload(
            file: file, sideFileOf: capture.fileURL,
            fingerprint: UploadService.fingerprint([capture.document, preferences.format.rawValue, preferences.exportAt1x]),
            contentType: preferences.format.mimeType,
            media: (Int(size.width * scale), Int(size.height * scale), nil),
            options: options, progress: progress
        )
    }

    private func uploadRecording(_ recording: Recording, options: UploadOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile {
        let file = try await recordingExporter.exportedFile(for: recording)
        let isGIF = recording.edit.format == .gif
        let videoSize = recording.edit.resolution.size(for: recording.naturalSize)
        let size = isGIF ? SelectionMath.gifSize(for: videoSize, maxWidth: CGFloat(preferences.gifMaxWidth)) : videoSize
        let poster = isGIF ? nil : await UploadService.posterFrame(of: file)
        return try await uploads.upload(
            file: file, sideFileOf: recording.fileURL,
            fingerprint: UploadService.fingerprint([recording.edit, preferences.videoCodec.rawValue, preferences.gifFrameRate, preferences.gifMaxWidth]),
            contentType: isGIF ? "image/gif" : "video/mp4",
            media: (Int(size.width), Int(size.height), recording.edit.trimmedDuration),
            poster: poster, options: options, progress: progress
        )
    }

    private func ensureUploadsConfigured() -> Bool {
        if uploads.isConfigured { return true }
        toast.show("Set up uploads in Settings first", systemImage: "icloud.slash")
        showSettings(.upload)
        return false
    }

    /// Replaces a link on the clipboard with a short one on the user's Worker.
    func shortenClipboardLink() {
        let text = NSPasteboard.general.string(forType: .string)
        let base = UploadLinks.normalizedBase(preferences.uploadBaseURL)
        switch LinkShortening.check(text, workerBase: base) {
        case .notALink:
            toast.show("The clipboard doesn't contain a link to shorten", systemImage: "exclamationmark.triangle")
        case .alreadyShort:
            toast.show("That's already a short link", systemImage: "link")
        case .shorten(let url):
            guard let client = uploads.client else {
                _ = ensureUploadsConfigured()
                return
            }
            Task {
                do {
                    let link = try await client.shorten(url)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                    toast.show("Short link copied: \(link.url.host() ?? "")\(link.url.path())", systemImage: "link") {
                        NSWorkspace.shared.open(link.url)
                    }
                } catch {
                    presentError(error, title: "Could not shorten the link")
                }
            }
        }
    }

    func showUploads() {
        guard ensureUploadsConfigured() else { return }
        if uploadsWindow == nil {
            let model = UploadsModel(service: uploads)
            model.onCopied = { [weak self] _ in self?.toast.show("Link copied", systemImage: "link") }
            uploadsWindow = UploadsWindowController(model: model)
        }
        uploadsWindow?.present()
    }

    private func showSavedToast(_ url: URL, showsName: Bool = false) {
        let message = showsName ? "Saved \(url.lastPathComponent)" : "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        toast.show(message, systemImage: "checkmark.circle") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Windows and alerts

    func showSettings(_ page: SettingsPage? = nil) {
        settingsModel.launchAtLogin = LaunchAtLogin.isEnabled
        // Read only when Settings opens, so launching Škljoc never asks for keychain access.
        settingsModel.uploadToken = Keychain.token(for: UploadService.keychainAccount) ?? ""
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: settingsModel, preferences: preferences)
        }
        if let page { settingsWindow?.show(page) } else { settingsWindow?.present() }
    }

    private func explainShortcutConflict() {
        let taken = ShortcutAction.allCases
            .filter { settingsModel.registrations[$0] != .registered && settingsModel.registrations[$0] != .cleared }
            .compactMap { preferences.shortcut(for: $0)?.description }
            .joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "\(taken) is used by another shortcut"
        alert.informativeText = """
        Turn off the macOS screenshot shortcuts under Keyboard Shortcuts → Screenshots \
        (and the same shortcuts in CleanShot, if you use it), then press Try Again in Škljoc Settings. \
        You can also pick different shortcuts there.
        """
        alert.addButton(withTitle: "Open Keyboard Shortcuts")
        alert.addButton(withTitle: "Open Škljoc Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SystemSettings.openKeyboardShortcuts()
            showSettings()
        case .alertSecondButtonReturn:
            showSettings()
        default:
            break
        }
    }

    private func explainScreenRecordingPermission() {
        let alert = NSAlert()
        alert.messageText = "Škljoc needs Screen Recording permission"
        alert.informativeText = """
        Allow Škljoc under Privacy & Security → Screen & System Audio Recording. \
        If it is already allowed, quit and reopen Škljoc.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SystemSettings.openScreenRecordingPrivacy()
        }
    }

    private func explainPermission(_ problem: PermissionError) {
        let alert = NSAlert()
        alert.messageText = problem.title
        alert.informativeText = problem.localizedDescription
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            problem.openSettings()
        }
    }

    private func presentError(_ error: Error, title: String) {
        NSLog("Skljoc: \(title): \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
