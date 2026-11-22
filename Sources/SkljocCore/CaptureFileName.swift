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

    /// The title the user gave the capture, made safe for a file name; the dated name when there is none.
    public static func make(title: String?, date: Date, fileExtension: String, timeZone: TimeZone = .current) -> String {
        guard let name = safeName(title) else { return make(date: date, fileExtension: fileExtension, timeZone: timeZone) }
        return "\(name).\(fileExtension)"
    }

    /// Without slashes, colons and control characters, no leading dots and at most 200 characters; nil when nothing is left.
    public static func safeName(_ title: String?) -> String? {
        let replaced = String((title ?? "").unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        })
        var name = replaced.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(200)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
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
