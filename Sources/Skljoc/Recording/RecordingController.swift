import AppKit
import AVFoundation
import Combine
import SkljocCore
import SwiftUI

/// Runs a recording from picking the area to the finished file: overlay, countdown, recorder and on-screen effects.
@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle, selecting, countdown, recording, paused, finishing
    }

    @Published private(set) var state: State = .idle

    var onFinished: ((URL, RecordingInfo) -> Void)?
    var onError: ((Error, String) -> Void)?
    var needsScreenRecordingPermission: (() -> Void)?
    var onPermissionProblem: ((PermissionError) -> Void)?

    private let preferences: Preferences
    private let store: CaptureStore
    private let camera = CameraBubble()
    private var setup: RecordingSetupModel?
    private var overlay: SelectionOverlay?
    private var countdown: Countdown?
    private var border: RecordingBorder?
    private var clicks: ClickHighlighter?
    private var keystrokes: KeystrokeOverlay?
    private var recorder: ScreenRecorder?
    private var recordingInfo: RecordingInfo?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var keyMonitor: Any?

    init(preferences: Preferences, store: CaptureStore) {
        self.preferences = preferences
        self.store = store
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let pausedNow = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return Date().timeIntervalSince(startedAt) - pausedTotal - pausedNow
    }

    /// The record shortcut: opens the area picker, or stops a running recording.
    func toggle() {
        switch state {
        case .idle: begin()
        case .selecting: startRecording()
        case .countdown: cancel()
        case .recording, .paused: stop()
        case .finishing: break
        }
    }

    func begin(format: RecordingFormat? = nil) {
        guard state == .idle else { return }
        guard ScreenRecordingPermission.ensure() else {
            needsScreenRecordingPermission?()
            return
        }
        var options = preferences.recordingOptions
        if let format { options.format = format }
        let setup = RecordingSetupModel(options: options)
        setup.onRecord = { [weak self] in self?.startRecording() }
        setup.onCancel = { [weak self] in self?.cancel() }
        setup.onOptionsChange = { [weak self] old, new in self?.optionsChanged(from: old, to: new) }
        restoreLastArea(in: setup)

        let overlay = SelectionOverlay(model: setup)
        overlay.onSelectionChange = { [weak self] area in
            if let area { self?.camera.follow(area) }
        }
        self.setup = setup
        self.overlay = overlay
        state = .selecting
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        overlay.show()
        if options.camera { showCamera() }
    }

    func stop() {
        guard state == .recording || state == .paused, let recorder else { return }
        state = .finishing
        stopEffects()
        Task {
            do {
                let url = try await recorder.stop()
                if let recordingInfo { try Recording.saveInfo(recordingInfo, for: url) }
                let info = recordingInfo ?? RecordingInfo(format: .video, hasSystemAudio: false, hasMicrophone: false)
                reset()
                onFinished?(url, info)
            } catch {
                reset()
                onError?(error, "Recording failed")
            }
        }
    }

    func cancel() {
        switch state {
        case .selecting:
            reset()
        case .countdown:
            countdown?.cancel()
        case .recording, .paused:
            state = .finishing
            stopEffects()
            let recorder = recorder
            Task {
                await recorder?.cancel()
                reset()
            }
        case .idle, .finishing:
            break
        }
    }

    func togglePause() {
        switch state {
        case .recording:
            recorder?.pause()
            pausedAt = Date()
            state = .paused
        case .paused:
            recorder?.resume()
            if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
            state = .recording
        default:
            break
        }
    }

    // MARK: Starting

    private func startRecording() {
        guard state == .selecting, let setup, let screen = setup.screen, let selection = setup.selection,
              let area = setup.selectionInScreenCoordinates, let displayID = RecordingSetupModel.displayID(of: screen) else { return }
        let options = setup.options
        preferences.recordingOptions = options
        preferences.lastRecordingArea = SavedRecordingArea(displayID: displayID, rect: selection)
        overlay?.close()
        overlay = nil
        removeKeyMonitor()
        state = .countdown

        Task {
            let microphoneID = options.recordsMicrophone ? await microphoneIfAllowed(options) : nil
            if options.showKeystrokes, !AccessibilityPermission.isTrusted(prompt: false) {
                NSLog("Skljoc: keystrokes need Accessibility permission; recording without them")
            }

            let border = RecordingBorder(around: area)
            border.show()
            self.border = border

            if preferences.countdown {
                let countdown = Countdown(centeredIn: area)
                self.countdown = countdown
                installKeyMonitor()
                let finished = await countdown.run()
                removeKeyMonitor()
                self.countdown = nil
                guard finished else {
                    reset()
                    return
                }
            }

            let scale = preferences.recordAt1x ? 1 : screen.backingScaleFactor
            let pixelSize = SelectionMath.pixelSize(of: selection, scale: scale)
            do {
                let url = try store.newRecordingURL()
                let recorder = ScreenRecorder(configuration: .init(
                    displayID: displayID,
                    sourceRect: selection,
                    pixelSize: pixelSize,
                    frameRate: preferences.frameRate,
                    codec: preferences.videoCodec,
                    showsCursor: preferences.showCursor,
                    systemAudio: options.recordsSystemAudio,
                    microphoneID: microphoneID,
                    excludedWindowIDs: [CGWindowID(border.windowNumber)],
                    outputURL: url
                ))
                recorder.onFailure = { [weak self] error in
                    Task { @MainActor in self?.recorderFailed(error) }
                }
                self.recorder = recorder
                recordingInfo = RecordingInfo(format: options.format, hasSystemAudio: options.recordsSystemAudio, hasMicrophone: microphoneID != nil)
                try await recorder.start()
                startEffects(options: options, area: area)
                startedAt = Date()
                pausedTotal = 0
                state = .recording
            } catch {
                reset()
                onError?(error, "Could not start recording")
            }
        }
    }

    private func microphoneIfAllowed(_ options: RecordingOptions) async -> String? {
        guard await MediaPermission.request(.audio) else {
            onPermissionProblem?(.microphone)
            return nil
        }
        return MediaDevices.microphoneID(preferring: options.microphoneID)
    }

    private func startEffects(options: RecordingOptions, area: CGRect) {
        if options.highlightClicks {
            let clicks = ClickHighlighter()
            clicks.start()
            self.clicks = clicks
        }
        if options.showKeystrokes {
            let keystrokes = KeystrokeOverlay(area: area)
            keystrokes.start()
            self.keystrokes = keystrokes
        }
    }

    private func stopEffects() {
        clicks?.stop()
        clicks = nil
        keystrokes?.stop()
        keystrokes = nil
        border?.close()
        border = nil
        camera.close()
    }

    private func recorderFailed(_ error: Error) {
        guard state == .recording || state == .paused else { return }
        stop()
    }

    private func reset() {
        removeKeyMonitor()
        overlay?.close()
        overlay = nil
        countdown?.cancel()
        countdown = nil
        stopEffects()
        recorder = nil
        recordingInfo = nil
        setup = nil
        startedAt = nil
        pausedAt = nil
        pausedTotal = 0
        state = .idle
    }

    // MARK: Area picker

    private func restoreLastArea(in setup: RecordingSetupModel) {
        guard let saved = preferences.lastRecordingArea,
              let screen = NSScreen.screens.first(where: { RecordingSetupModel.displayID(of: $0) == saved.displayID }) else { return }
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        guard bounds.contains(saved.rect) else { return }
        setup.select(saved.rect, on: screen)
    }

    private func optionsChanged(from old: RecordingOptions, to new: RecordingOptions) {
        preferences.recordingOptions = new
        if new.camera != old.camera || new.cameraID != old.cameraID || new.cameraSize != old.cameraSize || new.cameraShape != old.cameraShape {
            new.camera ? showCamera() : camera.hide()
        }
        if new.microphone && !old.microphone {
            Task {
                if !(await requestMediaAccess(.audio)) {
                    setup?.options.microphone = false
                    reportPermission(.microphone)
                }
            }
        }
        if new.showKeystrokes && !old.showKeystrokes {
            Task {
                if !(await requestAccessibility()) {
                    setup?.options.showKeystrokes = false
                    reportPermission(.accessibility)
                }
            }
        }
    }

    /// Asks macOS with the overlay out of the way, so the system prompt can be clicked.
    private func requestMediaAccess(_ type: AVMediaType) async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: type) == .authorized { return true }
        overlay?.suspend()
        defer { overlay?.resume() }
        return await MediaPermission.request(type)
    }

    /// Shows the Accessibility prompt with the overlay out of the way and waits until it is answered.
    private func requestAccessibility() async -> Bool {
        if AccessibilityPermission.isTrusted(prompt: false) { return true }
        overlay?.suspend()
        defer { overlay?.resume() }
        _ = AccessibilityPermission.isTrusted(prompt: true)
        try? await Task.sleep(for: .milliseconds(600))
        for _ in 0..<240 {
            if AccessibilityPermission.isTrusted(prompt: false) { return true }
            if !AccessibilityPermission.isPromptVisible { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return AccessibilityPermission.isTrusted(prompt: false)
    }

    private func reportPermission(_ problem: PermissionError) {
        overlay?.suspend()
        onPermissionProblem?(problem)
        overlay?.resume()
    }

    private func showCamera() {
        guard let setup else { return }
        Task {
            guard await requestMediaAccess(.video) else {
                setup.options.camera = false
                reportPermission(.camera)
                return
            }
            let options = setup.options
            camera.show(deviceID: options.cameraID, size: options.cameraSize, shape: options.cameraShape, near: setup.selectionInScreenCoordinates)
        }
    }

    // MARK: Keys

    /// Esc cancels, Return starts, Space picks the whole screen under the pointer.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isEditingText = NSApp.keyWindow?.firstResponder is NSText
            if event.keyCode == 53 {
                cancel()
                return nil
            }
            if (event.keyCode == 36 || event.keyCode == 76) && !isEditingText {
                startRecording()
                return nil
            }
            if event.keyCode == 49 && !isEditingText && state == .selecting {
                selectScreenUnderPointer()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func selectScreenUnderPointer() {
        guard let setup else { return }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else { return }
        setup.select(CGRect(origin: .zero, size: screen.frame.size), on: screen)
    }
}

enum PermissionError: LocalizedError {
    case microphone, camera, accessibility

    var title: String {
        switch self {
        case .microphone: "Škljoc can't use the microphone"
        case .camera: "Škljoc can't use the camera"
        case .accessibility: "Show keystrokes needs Accessibility permission"
        }
    }

    func openSettings() {
        switch self {
        case .microphone: SystemSettings.openPrivacy("Privacy_Microphone")
        case .camera: SystemSettings.openPrivacy("Privacy_Camera")
        case .accessibility: SystemSettings.openPrivacy("Privacy_Accessibility")
        }
    }

    var errorDescription: String? {
        switch self {
        case .microphone:
            "Allow Škljoc under System Settings → Privacy & Security → Microphone."
        case .camera:
            "Allow Škljoc under System Settings → Privacy & Security → Camera."
        case .accessibility:
            "Allow Škljoc under System Settings → Privacy & Security → Accessibility. Recordings work without it, just without keystrokes."
        }
    }
}

/// The dimmed screens and the control bar while picking the area.
@MainActor
final class SelectionOverlay {
    var onSelectionChange: ((CGRect?) -> Void)?

    private let model: RecordingSetupModel
    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var bar: OverlayWindow?
    private var subscription: AnyCancellable?
    private var suspendCount = 0

    init(model: RecordingSetupModel) {
        self.model = model
    }

    func show() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(frame: screen.frame, level: .selectionOverlay, allowsKey: true)
            window.acceptsMouseMovedEvents = true
            let view = SelectionView(screen: screen, model: model)
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        let location = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(location, $0.frame, false) } ?? windows.first)?.makeKey()

        let hosting = FirstMouseHostingView(rootView: RecordingControlBar(model: model))
        let bar = OverlayWindow(frame: CGRect(origin: .zero, size: hosting.fittingSize), level: .recordingControls, allowsKey: true)
        bar.contentView = hosting
        bar.orderFrontRegardless()
        self.bar = bar
        layout()

        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    /// Steps aside for system prompts and alerts, which sit below the overlay's window level.
    func suspend() {
        suspendCount += 1
        guard suspendCount == 1 else { return }
        windows.forEach { $0.orderOut(nil) }
        bar?.orderOut(nil)
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        guard suspendCount == 0, !windows.isEmpty else { return }
        windows.forEach { $0.orderFrontRegardless() }
        bar?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let location = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(location, $0.frame, false) } ?? windows.first)?.makeKey()
    }

    func close() {
        subscription = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        bar?.orderOut(nil)
        bar = nil
    }

    private func layout() {
        views.forEach { $0.needsDisplay = true }
        onSelectionChange?(model.selectionInScreenCoordinates)
        guard let bar, let content = bar.contentView else { return }
        let size = content.fittingSize
        let gap: CGFloat = 14

        let screen = model.screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let area = model.selectionInScreenCoordinates {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - gap - size.height)
            if origin.y < visible.minY {
                origin.y = area.maxY + gap
                if origin.y + size.height > visible.maxY { origin.y = area.minY + gap }
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        bar.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
