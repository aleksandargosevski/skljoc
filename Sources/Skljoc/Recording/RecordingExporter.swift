import AppKit
import SkljocCore
import UniformTypeIdentifiers

/// Exports recordings with their edits for copy, save and drag. The last export of each
/// recording is kept, so copying and then dragging doesn't render twice.
@MainActor
final class RecordingExporter {
    private struct CachedExport {
        var request: VideoExportRequestKey
        var url: URL
    }

    /// The parts of a request that change the output file.
    private struct VideoExportRequestKey: Equatable {
        var edit: VideoEdit
        var codec: VideoCodec
        var gifFrameRate: Int
        var gifMaxWidth: Int
        var fileName: String
    }

    private let preferences: Preferences
    private var cache: [UUID: CachedExport] = [:]
    private var running: [UUID: Task<URL, Error>] = [:]

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func fileName(for recording: Recording) -> String {
        CaptureFileName.make(title: recording.title, date: recording.createdAt, fileExtension: recording.edit.format.fileExtension)
    }

    /// The exported file in a temporary folder, rendered only when the edits changed.
    func exportedFile(for recording: Recording) async throws -> URL {
        let key = requestKey(for: recording)
        if let cached = cache[recording.id], cached.request == key, FileManager.default.fileExists(atPath: cached.url.path) {
            return cached.url
        }
        if let task = running[recording.id] {
            let url = try await task.value
            if cache[recording.id]?.request == key { return url }
        }

        let request = VideoExportRequest(
            sourceURL: recording.fileURL, info: recording.info, edit: recording.edit,
            naturalSize: recording.naturalSize, codec: preferences.videoCodec, frameRate: recording.frameRate,
            gifFrameRate: preferences.gifFrameRate, gifMaxWidth: preferences.gifMaxWidth
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skljoc Exports", isDirectory: true)
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(fileName(for: recording))
        let task = Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await VideoExportEngine.export(request, to: url)
            return url
        }
        running[recording.id] = task
        defer { running[recording.id] = nil }
        let result = try await task.value
        cache[recording.id] = CachedExport(request: key, url: result)
        return result
    }

    func copy(_ recording: Recording) async throws {
        let url = try await exportedFile(for: recording)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    func save(_ recording: Recording) async throws -> URL {
        let folder = preferences.saveFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.folderMissing(folder)
        }
        let source = try await exportedFile(for: recording)
        let destination = CaptureFileName.uniqueURL(in: folder, fileName: fileName(for: recording)) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Returns nil when the user cancels the panel.
    func saveAs(_ recording: Recording) async throws -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = fileName(for: recording)
        panel.allowedContentTypes = [recording.edit.format == .gif ? .gif : .mpeg4Movie]
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        let source = try await exportedFile(for: recording)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Drags a ready file when there is one; otherwise the receiving app gets it once it is rendered.
    func dragItem(for recording: Recording) -> NSItemProvider {
        let key = requestKey(for: recording)
        if let cached = cache[recording.id], cached.request == key, FileManager.default.fileExists(atPath: cached.url.path),
           let provider = NSItemProvider(contentsOf: cached.url) {
            provider.suggestedName = cached.url.deletingPathExtension().lastPathComponent
            return provider
        }
        let provider = NSItemProvider()
        let type: UTType = recording.edit.format == .gif ? .gif : .mpeg4Movie
        provider.suggestedName = (fileName(for: recording) as NSString).deletingPathExtension
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            Task { @MainActor in
                do {
                    guard let self else { throw CancellationError() }
                    completion(try await self.exportedFile(for: recording), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Renders in the background so the first copy or drag is instant. Calls back with the file
    /// unless the edits changed meanwhile.
    func prepare(_ recording: Recording, completion: ((URL) -> Void)? = nil) {
        let key = requestKey(for: recording)
        Task {
            do {
                let url = try await exportedFile(for: recording)
                if requestKey(for: recording) == key { completion?(url) }
            } catch {
                NSLog("Skljoc: could not pre-render the recording: \(error.localizedDescription)")
            }
        }
    }

    private func requestKey(for recording: Recording) -> VideoExportRequestKey {
        VideoExportRequestKey(
            edit: recording.edit, codec: preferences.videoCodec,
            gifFrameRate: preferences.gifFrameRate, gifMaxWidth: preferences.gifMaxWidth,
            fileName: fileName(for: recording)
        )
    }
}
