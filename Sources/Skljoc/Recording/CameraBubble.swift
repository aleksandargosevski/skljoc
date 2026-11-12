import AppKit
@preconcurrency import AVFoundation
import SkljocCore

/// The webcam as a floating, draggable bubble. It is part of the screen, so it ends up in the recording.
@MainActor
final class CameraBubble {
    private var window: OverlayWindow?
    private var session: AVCaptureSession?
    private var previewView: CameraPreviewView?
    private var deviceID: String?
    private(set) var wasMovedByUser = false
    private var isPositioning = false
    private var moveObserver: NSObjectProtocol?

    var isVisible: Bool { window?.isVisible == true }

    func show(deviceID: String?, size: CameraSize, shape: CameraShape, near area: CGRect?) {
        if window == nil { makeWindow() }
        if session == nil || deviceID != self.deviceID {
            startSession(deviceID: deviceID)
        }
        apply(size: size, shape: shape)
        if !wasMovedByUser, let area { position(in: area) }
        window?.orderFrontRegardless()
    }

    func follow(_ area: CGRect) {
        guard isVisible, !wasMovedByUser else { return }
        position(in: area)
    }

    func hide() {
        window?.orderOut(nil)
        stopSession()
    }

    func close() {
        hide()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        window = nil
        wasMovedByUser = false
    }

    private func makeWindow() {
        let window = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 180, height: 180), level: .cameraBubble)
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        let view = CameraPreviewView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        previewView = view
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPositioning else { return }
                self.wasMovedByUser = true
            }
        }
        self.window = window
    }

    private func apply(size: CameraSize, shape: CameraShape) {
        guard let window, let previewView else { return }
        let diameter = size.diameter
        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = CGSize(width: diameter, height: diameter)
        if wasMovedByUser { frame.origin = CGPoint(x: center.x - diameter / 2, y: center.y - diameter / 2) }
        isPositioning = true
        window.setFrame(frame, display: true)
        isPositioning = false
        previewView.cornerRadius = shape == .circle ? diameter / 2 : diameter * 0.18
    }

    /// Bottom-right corner of the recording area.
    private func position(in area: CGRect) {
        guard let window else { return }
        let size = window.frame.size
        let origin = CGPoint(x: area.maxX - size.width - 20, y: area.minY + 20)
        isPositioning = true
        window.setFrameOrigin(origin)
        isPositioning = false
    }

    private func startSession(deviceID: String?) {
        stopSession()
        guard let device = MediaDevices.camera(withID: deviceID) else {
            NSLog("Skljoc: no camera available")
            return
        }
        do {
            let session = AVCaptureSession()
            session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.unusable(device.localizedName) }
            session.addInput(input)
            previewView?.attach(session)
            self.session = session
            self.deviceID = deviceID
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        } catch {
            NSLog("Skljoc: could not start the camera: \(error.localizedDescription)")
        }
    }

    private func stopSession() {
        guard let session else { return }
        self.session = nil
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    enum CameraError: LocalizedError {
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .unusable(let name): "The camera “\(name)” can't be used right now."
            }
        }
    }
}

private final class CameraPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var cornerRadius: CGFloat = 90 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 3
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    func attach(_ session: AVCaptureSession) {
        previewLayer.session = session
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        layer?.cornerRadius = cornerRadius
    }
}
