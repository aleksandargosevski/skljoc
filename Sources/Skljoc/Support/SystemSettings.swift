import AppKit
import CoreGraphics
import ServiceManagement

enum SystemSettings {
    static func openKeyboardShortcuts() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
    }

    static func openScreenRecordingPrivacy() {
        openPrivacy("Privacy_ScreenCapture")
    }

    static func openPrivacy(_ anchor: String) {
        open("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum ScreenRecordingPermission {
    /// Asks macOS once; afterwards the user has to allow Skljoc in System Settings.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}

enum LaunchAtLogin {
    /// Homebrew moves the app to a new Cellar path on every upgrade, which would break a login item
    /// registered for the old path, so Homebrew installs start at login via `brew services` instead.
    static var isManagedByHomebrew: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
