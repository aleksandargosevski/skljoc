import Foundation
import SkljocCore

/// A screenshot or a screen recording.
@MainActor
enum MediaItem {
    case screenshot(Capture)
    case recording(Recording)

    var createdAt: Date {
        switch self {
        case .screenshot(let capture): capture.createdAt
        case .recording(let recording): recording.createdAt
        }
    }
}

/// Keeps the latest screenshots and recordings in the caches folder, so a closed preview can be reopened from the menu.
@MainActor
final class CaptureStore {
    static let recentLimit = 10

    let folder: URL
    private var screenshots: [URL: Capture] = [:]
    private var recordings: [URL: Recording] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.aleksandargosevski.skljoc")
            .appendingPathComponent("Captures")
    }

    func newCaptureURL() throws -> URL {
        try newURL(extension: "png")
    }

    func newRecordingURL() throws -> URL {
        try newURL(extension: "mp4")
    }

    func add(_ capture: Capture) {
        screenshots[capture.fileURL] = capture
        pruneOldFiles()
    }

    func add(_ recording: Recording) {
        recordings[recording.fileURL] = recording
        pruneOldFiles()
    }

    /// Newest first. Items from this session keep their edits; older ones are loaded from disk.
    func recent() async -> [MediaItem] {
        var items: [MediaItem] = []
        for (url, date) in recentFiles() {
            if url.pathExtension == "png" {
                if let capture = screenshots[url] ?? (try? Capture(fileURL: url, createdAt: date)) {
                    screenshots[url] = capture
                    items.append(.screenshot(capture))
                }
            } else if let recording = recordings[url] {
                items.append(.recording(recording))
            } else if let recording = try? await Recording.load(fileURL: url, createdAt: date) {
                recordings[url] = recording
                items.append(.recording(recording))
            }
        }
        return items
    }

    private func newURL(extension pathExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).\(pathExtension)")
    }

    private func recentFiles() -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { ["png", "mp4"].contains($0.pathExtension) }
            .map { url in (url, (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.recentLimit)
            .map { $0 }
    }

    /// Removes everything beyond the latest items, together with their side files (info, edits).
    private func pruneOldFiles() {
        let keep = Set(recentFiles().map { MediaFiles.baseName(of: $0.0) })
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where !keep.contains(MediaFiles.baseName(of: url)) {
            do {
                try FileManager.default.removeItem(at: url)
                screenshots[url] = nil
                recordings[url] = nil
            } catch {
                NSLog("Skljoc: could not remove old capture \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
