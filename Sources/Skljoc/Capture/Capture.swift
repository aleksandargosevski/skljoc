import AppKit
import ImageIO
import SkljocCore

enum CaptureLoadError: LocalizedError {
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Could not read the screenshot at \(url.path)."
        }
    }
}

/// A screenshot and the edits made to it. The original file stays untouched.
@MainActor
final class Capture: Identifiable {
    let id = UUID()
    let fileURL: URL
    let image: CGImage
    /// Pixels per point: 2 on Retina displays.
    let scale: CGFloat
    let createdAt: Date
    var document: EditorDocument
    /// The name given in History, used for exported files.
    var title: String? { MediaFiles.title(for: fileURL) }

    init(fileURL: URL, createdAt: Date = Date()) throws {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureLoadError.unreadable(fileURL)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        self.fileURL = fileURL
        self.image = image
        self.scale = max(1, CGFloat(dpi / 72).rounded())
        self.createdAt = createdAt
        let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let saved = MediaFiles.read(EditorDocument.self, from: MediaFiles.editsURL(for: fileURL))
        self.document = saved?.imageSize == imageSize ? saved! : EditorDocument(imageSize: imageSize)
    }

    /// Keeps annotations and crop next to the file, so they survive a restart.
    func saveEdits() {
        do {
            try MediaFiles.write(document.hasEdits ? document : nil, to: MediaFiles.editsURL(for: fileURL))
        } catch {
            NSLog("Skljoc: could not save screenshot edits: \(error.localizedDescription)")
        }
    }

    var pointSize: CGSize { document.imageSize }

    lazy var renderer = AnnotationRenderer(image: image, scale: scale)

    /// The screenshot with all edits applied.
    func renderedImage(at1x: Bool = false) -> CGImage {
        renderer.export(document, scale: at1x ? 1 : scale) ?? image
    }

    func thumbnail() -> NSImage {
        let rendered = document.hasEdits ? renderedImage() : image
        return NSImage(cgImage: rendered, size: document.outputSize)
    }
}
