import AppKit
import SkljocCore

/// The state of the area picker and its control bar before a recording starts.
@MainActor
final class RecordingSetupModel: ObservableObject {
    @Published var options: RecordingOptions {
        didSet { onOptionsChange?(oldValue, options) }
    }
    /// The screen the selection is on, and the selection in points from that screen's top-left corner.
    @Published private(set) var screen: NSScreen?
    @Published private(set) var selection: CGRect?
    @Published private(set) var cameras: [MediaDevice] = MediaDevices.cameras()
    @Published private(set) var microphones: [MediaDevice] = MediaDevices.microphones()

    var onOptionsChange: ((RecordingOptions, RecordingOptions) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    init(options: RecordingOptions) {
        self.options = options
    }

    var scale: CGFloat { screen?.backingScaleFactor ?? 2 }

    var screenBounds: CGRect {
        guard let screen else { return .zero }
        return CGRect(origin: .zero, size: screen.frame.size)
    }

    var pixelSize: CGSize? {
        selection.map { SelectionMath.pixelSize(of: $0, scale: scale) }
    }

    /// The selection in global AppKit coordinates (bottom-left origin), for positioning windows.
    var selectionInScreenCoordinates: CGRect? {
        guard let screen, let selection else { return nil }
        return Self.globalRect(selection, on: screen)
    }

    func select(_ rect: CGRect?, on screen: NSScreen) {
        self.screen = screen
        selection = rect.map { Geometry.clamp($0.integral, to: CGRect(origin: .zero, size: screen.frame.size)) }
    }

    func setPixelWidth(_ width: Int) {
        guard let selection, let pixelSize, width > 1 else { return }
        self.selection = SelectionMath.resized(selection, toPixels: CGSize(width: CGFloat(width), height: pixelSize.height), scale: scale, within: screenBounds)
    }

    func setPixelHeight(_ height: Int) {
        guard let selection, let pixelSize, height > 1 else { return }
        self.selection = SelectionMath.resized(selection, toPixels: CGSize(width: pixelSize.width, height: CGFloat(height)), scale: scale, within: screenBounds)
    }

    func apply(_ preset: SelectionPreset) {
        guard let screen else { return }
        let current = selection ?? screenBounds.insetBy(dx: screenBounds.width / 4, dy: screenBounds.height / 4)
        select(preset.apply(to: current, bounds: screenBounds, scale: scale), on: screen)
    }

    func refreshDevices() {
        cameras = MediaDevices.cameras()
        microphones = MediaDevices.microphones()
    }

    static func globalRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
