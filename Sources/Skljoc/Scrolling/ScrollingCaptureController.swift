import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import SkljocCore
import SwiftUI
import UniformTypeIdentifiers

/// A long screenshot of a scrolling area: pick the area, then scroll (or let Škljoc scroll)
/// while frames are captured and stitched together.
@MainActor
final class ScrollingCaptureController: ObservableObject {
    enum State { case idle, selecting, capturing, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var height = 0
    @Published private(set) var message = "Scroll down slowly"
    @Published var autoScroll: Bool {
        didSet { preferences.autoScroll = autoScroll }
    }

    var onFinished: ((URL) -> Void)?
    var onError: ((Error, String) -> Void)?
    var needsScreenRecordingPermission: (() -> Void)?

    private let preferences: Preferences
    private let store: CaptureStore
    private let hotKeys: HotKeyCenter
    private var setup: RecordingSetupModel?
    private var overlay: SelectionOverlay?
    private var keyMonitor: Any?
    private var border: RecordingBorder?
    private var hud: OverlayWindow?
    private var previewWindow: OverlayWindow?
    private let previewModel = ScrollPreviewModel()
    private var session = ScrollSession()
    private var area: (screen: NSScreen, rect: CGRect, global: CGRect)?
    private static let finishKeyID: UInt32 = 200
    private static let cancelKeyID: UInt32 = 201

    init(preferences: Preferences, store: CaptureStore, hotKeys: HotKeyCenter) {
        self.preferences = preferences
        self.store = store
        self.hotKeys = hotKeys
        autoScroll = preferences.autoScroll
    }

    // MARK: Picking the area

    func begin() {
        guard state == .idle else { return }
        guard ScreenRecordingPermission.ensure() else {
            needsScreenRecordingPermission?()
            return
        }
        let setup = RecordingSetupModel(options: RecordingOptions())
        setup.onRecord = { [weak self] in self?.start() }
        setup.onCancel = { [weak self] in self?.cancel() }
        let overlay = SelectionOverlay(model: setup, bar: AnyView(ScrollingSelectionBar(model: setup, controller: self)))
        self.setup = setup
        self.overlay = overlay
        state = .selecting
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        overlay.show()
    }

    func cancel() {
        removeKeyMonitor()
        overlay?.close()
        tearDown()
    }

    // MARK: Capturing

    private func start() {
        guard state == .selecting, let setup, let screen = setup.screen, let rect = setup.selection,
              let global = setup.selectionInScreenCoordinates else { return }
        removeKeyMonitor()
        overlay?.close()
        overlay = nil
        area = (screen, rect, global)
        session = ScrollSession()
        height = 0
        state = .capturing

        let border = RecordingBorder(around: global)
        border.show()
        self.border = border
        showHUD(near: global, on: screen)
        hotKeys.registerTransient(id: Self.finishKeyID, shortcut: .init(keyCode: 36, modifiers: [])) { [weak self] in self?.finish() }
        hotKeys.registerTransient(id: Self.cancelKeyID, shortcut: .init(keyCode: 53, modifiers: [])) { [weak self] in self?.tearDown() }

        Task { await run(screen: screen, rect: rect) }
    }

    private func run(screen: NSScreen, rect: CGRect) async {
        if autoScroll, !(await AccessibilityPermission.request()) {
            autoScroll = false
            message = "Auto-scroll needs Accessibility permission. Scroll by hand."
        }
        do {
            let capturer = try await FrameCapturer(screen: screen, rect: rect)
            var idleFrames = 0
            var scrolledOnce = false
            while state == .capturing {
                if autoScroll {
                    if scrolledOnce { scroll() }
                    scrolledOnce = true
                    try? await Task.sleep(for: .milliseconds(350))
                } else {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard state == .capturing else { break }
                let frame = try await capturer.capture()
                let update = await session.add(frame)
                height = update.height
                previewModel.strips = update.preview
                if update.lostTrack {
                    message = "Lost track. Scroll back up a little, then slower."
                } else if update.moved {
                    message = autoScroll ? "Scrolling…" : "Keep scrolling · ↩ when done"
                }
                if update.reachedLimit {
                    finish()
                } else if autoScroll && scrolledOnce {
                    idleFrames = update.moved ? 0 : idleFrames + 1
                    // The page stopped moving: the bottom is reached.
                    if idleFrames >= 3 { finish() }
                }
            }
        } catch {
            tearDown()
            onError?(error, "Scrolling capture failed")
        }
    }

    func finish() {
        guard state == .capturing, let area else { return }
        state = .finishing
        Task {
            let image = await session.compose()
            tearDown()
            guard let image else { return }
            do {
                let url = try store.newCaptureURL()
                try Self.writePNG(image, scale: area.screen.backingScaleFactor, to: url)
                onFinished?(url)
            } catch {
                onError?(error, "Could not save the scrolling capture")
            }
        }
    }

    private func scroll() {
        guard let area else { return }
        // Scroll events go to the window under the pointer, so it moves into the area first.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? area.screen.frame.height
        let center = CGPoint(x: area.global.midX, y: primaryHeight - area.global.midY)
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
        let distance = Int32(max(40, area.rect.height * 0.45))
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -distance, wheel2: 0, wheel3: 0)
        scroll?.location = center
        scroll?.post(tap: .cghidEventTap)
    }

    private func tearDown() {
        hotKeys.unregister(id: Self.finishKeyID)
        hotKeys.unregister(id: Self.cancelKeyID)
        border?.close()
        border = nil
        hud?.orderOut(nil)
        hud = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        previewModel.strips = []
        setup = nil
        area = nil
        state = .idle
    }

    // MARK: Windows

    private func showHUD(near area: CGRect, on screen: NSScreen) {
        let hosting = FirstMouseHostingView(rootView: ScrollingHUD(controller: self))
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 14)
        if origin.y < visible.minY { origin.y = min(area.maxY + 14, visible.maxY - size.height) }
        if origin.y + size.height > visible.maxY || area.height > visible.height - size.height - 30 {
            origin.y = visible.minY + 16
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let hud = OverlayWindow(frame: CGRect(origin: origin, size: size), level: .recordingControls)
        hud.contentView = hosting
        hud.orderFrontRegardless()
        self.hud = hud

        let previewSize = CGSize(width: 170, height: min(area.height, 520))
        var previewX = area.maxX + 14
        if previewX + previewSize.width > visible.maxX { previewX = area.minX - previewSize.width - 14 }
        if previewX < visible.minX { previewX = visible.maxX - previewSize.width - 8 }
        let preview = OverlayWindow(
            frame: CGRect(x: previewX, y: area.maxY - previewSize.height, width: previewSize.width, height: previewSize.height),
            level: .recordingControls, ignoresMouse: true
        )
        preview.contentView = NSHostingView(rootView: ScrollPreviewView(model: previewModel))
        preview.orderFrontRegardless()
        previewWindow = preview
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { cancel(); return nil }
            if event.keyCode == 36 || event.keyCode == 76 { start(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
    }
}

/// Grabs single frames of the area with ScreenCaptureKit, leaving Škljoc's own windows out.
private struct FrameCapturer {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration

    @MainActor
    init(screen: NSScreen, rect: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = RecordingSetupModel.displayID(of: screen),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        let pixels = SelectionMath.pixelSize(of: rect, scale: screen.backingScaleFactor)
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
    }

    func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

// MARK: Views

private struct ScrollingSelectionBar: View {
    @ObservedObject var model: RecordingSetupModel
    @ObservedObject var controller: ScrollingCaptureController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.text.horizontal")
            Text(model.selection == nil ? "Select the part that scrolls" : "Ready when you are")
                .font(.system(size: 13, weight: .medium))
            Divider().frame(height: 22)
            Toggle("Auto-scroll", isOn: $controller.autoScroll)
                .toggleStyle(.checkbox)
                .help("Škljoc scrolls for you until the end (needs Accessibility permission)")
            Divider().frame(height: 22)
            Button { model.onCancel?() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            Button { model.onRecord?() } label: {
                Text("Start")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.accentColor.opacity(model.selection == nil ? 0.4 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(model.selection == nil)
            .help("Start capturing (↩)")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

private struct ScrollingHUD: View {
    @ObservedObject var controller: ScrollingCaptureController

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.message).font(.system(size: 12, weight: .semibold))
                Text("\(controller.height) px").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 230, alignment: .leading)
            Toggle("Auto", isOn: $controller.autoScroll).toggleStyle(.switch).controlSize(.mini)
            Button("Cancel") { controller.cancel() }
            Button("Done") { controller.finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

@MainActor
private final class ScrollPreviewModel: ObservableObject {
    @Published var strips: [CGImage] = []
}

/// The stitched result so far, newest part at the bottom.
private struct ScrollPreviewView: View {
    @ObservedObject var model: ScrollPreviewModel

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(model.strips.indices, id: \.self) { index in
                    let strip = model.strips[index]
                    Image(decorative: strip, scale: 1)
                        .resizable()
                        .frame(width: geometry.size.width - 12, height: (geometry.size.width - 12) * CGFloat(strip.height) / CGFloat(strip.width))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .clipped()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.7)))
    }
}
