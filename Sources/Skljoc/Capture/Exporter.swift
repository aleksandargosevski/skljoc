import AppKit
import ImageIO
import SkljocCore
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case encodingFailed
    case folderMissing(URL)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Could not encode the image."
        case .folderMissing(let url): "The save folder \(url.path) doesn't exist. Choose another one in Settings."
        }
    }
}

/// Turns a capture into files and clipboard contents, following the export preferences.
@MainActor
enum Exporter {
    static func copy(_ capture: Capture, preferences: Preferences) throws {
        let (image, scale) = render(capture, preferences: preferences)
        guard let png = encode(image, scale: scale, format: .png) else { throw ExportError.encodingFailed }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(cgImage: image, size: pointSize(of: image, scale: scale)).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @discardableResult
    static func save(_ capture: Capture, preferences: Preferences) throws -> URL {
        let folder = preferences.saveFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.folderMissing(folder)
        }
        let name = CaptureFileName.make(date: capture.createdAt, format: preferences.format)
        let url = CaptureFileName.uniqueURL(in: folder, fileName: name) { FileManager.default.fileExists(atPath: $0.path) }
        try write(capture, to: url, format: preferences.format, preferences: preferences)
        return url
    }

    /// Returns nil when the user cancels the panel.
    static func saveAs(_ capture: Capture, preferences: Preferences) throws -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = CaptureFileName.make(date: capture.createdAt, format: preferences.format)
        panel.allowedContentTypes = [.png, .jpeg]
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        try write(capture, to: url, format: format, preferences: preferences)
        return url
    }

    /// A file to hand to drag and drop, named like a saved screenshot.
    static func temporaryFile(for capture: Capture, preferences: Preferences) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skljoc Drag", isDirectory: true)
            .appendingPathComponent(capture.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFileName.make(date: capture.createdAt, format: preferences.format))
        try write(capture, to: url, format: preferences.format, preferences: preferences)
        return url
    }

    private static func write(_ capture: Capture, to url: URL, format: ImageFormat, preferences: Preferences) throws {
        let (image, scale) = render(capture, preferences: preferences)
        guard let data = encode(image, scale: scale, format: format) else { throw ExportError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    private static func render(_ capture: Capture, preferences: Preferences) -> (CGImage, CGFloat) {
        let at1x = preferences.exportAt1x && capture.scale > 1
        let needsRendering = capture.document.hasEdits || at1x
        let image = needsRendering ? capture.renderedImage(at1x: at1x) : capture.image
        return (image, at1x ? 1 : capture.scale)
    }

    /// Stores the DPI, so apps show Retina screenshots at their real size.
    private static func encode(_ image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func pointSize(of image: CGImage, scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}
