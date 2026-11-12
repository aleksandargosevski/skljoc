import AppKit
@preconcurrency import AVFoundation
import ImageIO
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

/// One file in History, before it is loaded.
struct HistoryEntry: Identifiable, Hashable {
    enum Kind { case screenshot, recording }

    let url: URL
    let date: Date
    let kind: Kind

    var id: URL { url }
    var baseName: String { MediaFiles.baseName(of: url) }
}

/// Keeps screenshots and recordings in the caches folder for History and the Recent menu,
/// with side files for edits, recording info, thumbnails and recognized text.
@MainActor
final class CaptureStore {
    static let recentLimit = 10

    let folder: URL
    var retention: () -> HistoryRetention = { .month }
    /// Called after items are added or removed.
    var onChange: (() -> Void)?
    private var screenshots: [URL: Capture] = [:]
    private var recordings: [URL: Recording] = [:]
    private var indexing = false

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
        prune()
        onChange?()
        indexText()
    }

    func add(_ recording: Recording) {
        recordings[recording.fileURL] = recording
        prune()
        onChange?()
        indexText()
    }

    /// Everything in History, newest first.
    func entries() -> [HistoryEntry] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls
            .compactMap { url -> HistoryEntry? in
                let kind: HistoryEntry.Kind
                switch url.pathExtension {
                case "png": kind = .screenshot
                case "mp4": kind = .recording
                default: return nil
                }
                let date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                return HistoryEntry(url: url, date: date, kind: kind)
            }
            .sorted { $0.date > $1.date }
    }

    /// The latest items for the Recent menu. Items from this session keep their state; older ones load from disk.
    func recent() async -> [MediaItem] {
        var items: [MediaItem] = []
        for entry in entries().prefix(Self.recentLimit) {
            if let item = await item(for: entry) { items.append(item) }
        }
        return items
    }

    func item(for entry: HistoryEntry) async -> MediaItem? {
        switch entry.kind {
        case .screenshot:
            if let capture = screenshots[entry.url] { return .screenshot(capture) }
            guard let capture = try? Capture(fileURL: entry.url, createdAt: entry.date) else { return nil }
            screenshots[entry.url] = capture
            return .screenshot(capture)
        case .recording:
            if let recording = recordings[entry.url] { return .recording(recording) }
            guard let recording = try? await Recording.load(fileURL: entry.url, createdAt: entry.date) else { return nil }
            recordings[entry.url] = recording
            return .recording(recording)
        }
    }

    // MARK: Side files

    /// A small picture for the History grid, cached next to the file.
    func thumbnail(for entry: HistoryEntry) async -> NSImage? {
        let cached = folder.appendingPathComponent("\(entry.baseName).thumb.jpg")
        if let image = NSImage(contentsOf: cached) { return image }
        let image: CGImage?
        switch entry.kind {
        case .screenshot:
            image = Self.downsampledImage(at: entry.url, maxPixels: 480)
        case .recording:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: entry.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            image = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        }
        guard let image else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: cached, options: .atomic)
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    /// Recognized text for searching History; nil until it has been indexed.
    func text(for entry: HistoryEntry) -> String? {
        try? String(contentsOf: textURL(entry.baseName), encoding: .utf8)
    }

    func duration(of entry: HistoryEntry) async -> Double? {
        if let recording = recordings[entry.url] { return recording.edit.trimmedDuration }
        return try? await AVURLAsset(url: entry.url).load(.duration).seconds
    }

    /// Recognizes the text of items that don't have it yet, one at a time in the background.
    func indexText() {
        guard !indexing else { return }
        indexing = true
        Task {
            defer { indexing = false }
            for entry in entries() where !FileManager.default.fileExists(atPath: textURL(entry.baseName).path) {
                let image: CGImage?
                switch entry.kind {
                case .screenshot:
                    image = Self.downsampledImage(at: entry.url, maxPixels: 3000)
                case .recording:
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: entry.url))
                    generator.appliesPreferredTrackTransform = true
                    image = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
                }
                let text = await image.asyncMap { try? await TextRecognizer.text(in: $0) } ?? nil
                try? (text ?? "").write(to: textURL(entry.baseName), atomically: true, encoding: .utf8)
            }
            onChange?()
        }
    }

    // MARK: Cleanup

    func delete(_ entry: HistoryEntry) {
        removeFiles { MediaFiles.baseName(of: $0) == entry.baseName }
        screenshots[entry.url] = nil
        recordings[entry.url] = nil
        onChange?()
    }

    func clear() {
        removeFiles { _ in true }
        screenshots.removeAll()
        recordings.removeAll()
        onChange?()
    }

    func diskUsage() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Removes items History no longer keeps, together with their side files.
    func prune() {
        let policy = retention()
        let keep = Set(entries().enumerated().filter { policy.keeps(index: $0.offset, date: $0.element.date) }.map(\.element.baseName))
        removeFiles { !keep.contains(MediaFiles.baseName(of: $0)) }
    }

    private func removeFiles(where shouldRemove: (URL) -> Bool) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where shouldRemove(url) {
            do {
                try FileManager.default.removeItem(at: url)
                screenshots[url] = nil
                recordings[url] = nil
            } catch {
                NSLog("Skljoc: could not remove \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private func textURL(_ baseName: String) -> URL {
        folder.appendingPathComponent("\(baseName).text.txt")
    }

    private func newURL(extension pathExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).\(pathExtension)")
    }

    private static func downsampledImage(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
