import AVFoundation
import ApplicationServices

struct MediaDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum MediaDevices {
    static func cameras() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return unique(session.devices)
    }

    static func microphones() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return unique(session.devices)
    }

    static func camera(withID id: String?) -> AVCaptureDevice? {
        id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
    }

    /// The microphone to record, falling back to the system default when the saved one is gone.
    static func microphoneID(preferring id: String?) -> String? {
        if let id, AVCaptureDevice(uniqueID: id) != nil { return id }
        return AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    private static func unique(_ devices: [AVCaptureDevice]) -> [MediaDevice] {
        var seen = Set<String>()
        return devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return MediaDevice(id: device.uniqueID, name: device.localizedName)
        }
    }
}

enum MediaPermission {
    /// Asks the first time; afterwards reflects what the user chose in System Settings.
    static func request(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}

enum AccessibilityPermission {
    /// Needed to see key presses in other apps for "Show keystrokes".
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Shows the system prompt and waits until it is answered (or gone).
    static func request() async -> Bool {
        if isTrusted(prompt: false) { return true }
        _ = isTrusted(prompt: true)
        try? await Task.sleep(for: .milliseconds(600))
        for _ in 0..<240 {
            if isTrusted(prompt: false) { return true }
            if !isPromptVisible { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return isTrusted(prompt: false)
    }

    /// Whether macOS is showing its "would like to control this computer" prompt.
    static var isPromptVisible: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "universalAccessAuthWarn" }
    }
}
