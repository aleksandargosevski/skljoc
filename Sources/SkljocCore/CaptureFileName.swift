import Foundation

public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }
}

public enum CaptureFileName {
    /// "Skljoc 2026-11-12 at 14.03.22.png", in the style of macOS screenshots.
    public static func make(date: Date, format: ImageFormat, timeZone: TimeZone = .current) -> String {
        make(date: date, fileExtension: format.fileExtension, timeZone: timeZone)
    }

    public static func make(date: Date, fileExtension: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Skljoc \(formatter.string(from: date)).\(fileExtension)"
    }

    /// Appends " (2)", " (3)", … until the name is free, so nothing is overwritten.
    public static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let candidate = folder.appendingPathComponent(fileName)
        guard exists(candidate) else { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !exists(url) { return url }
            number += 1
        }
    }
}

/// Where uploads will plug in. Nothing implements it yet.
public protocol Uploader: Sendable {
    func upload(_ data: Data, fileName: String, contentType: String) async throws -> URL
}
