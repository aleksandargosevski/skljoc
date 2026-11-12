import AppKit

enum CaptureMode: CaseIterable {
    case area, fullscreen

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .fullscreen: "Capture Fullscreen"
        }
    }
}

enum CaptureError: LocalizedError {
    case screencaptureFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .screencaptureFailed(let status): "screencapture exited with status \(status)."
        }
    }
}

/// Takes screenshots with the system `screencapture` tool, which brings the familiar area and window picker.
@MainActor
final class CaptureService {
    private(set) var isCapturing = false

    /// Returns false when the user cancelled the selection.
    func capture(_ mode: CaptureMode, to url: URL, playSound: Bool) async throws -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        defer { isCapturing = false }

        var arguments = playSound ? [] : ["-x"]
        switch mode {
        case .area:
            arguments.append("-i")
        case .fullscreen:
            arguments += ["-R", Self.rectArgument(for: Self.screenUnderPointer())]
        }
        arguments.append(url.path)

        let status = try await Self.run("/usr/sbin/screencapture", arguments: arguments)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if status != 0 && !exists && mode == .fullscreen { throw CaptureError.screencaptureFailed(status) }
        return exists
    }

    private static func screenUnderPointer() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `screencapture -R` takes global coordinates with the origin at the top left of the primary display.
    private static func rectArgument(for screen: NSScreen) -> String {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        let top = primaryHeight - frame.maxY
        return "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    }

    private static func run(_ path: String, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
