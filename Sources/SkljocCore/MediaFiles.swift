import Foundation

/// Names of the files that belong to one screenshot or recording in the captures folder:
/// `1794489938929.png` or `.mp4`, its edits in `1794489938929.edits.json`, and so on.
public enum MediaFiles {
    public static func editsURL(for mediaURL: URL) -> URL {
        mediaURL.deletingLastPathComponent().appendingPathComponent("\(baseName(of: mediaURL)).edits.json")
    }

    /// A name the user gave a capture in History, kept in `<base>.title.txt`.
    public static func title(for mediaURL: URL) -> String? {
        guard let text = try? String(contentsOf: titleURL(for: mediaURL), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves the name, or removes it when `title` is empty.
    public static func setTitle(_ title: String?, for mediaURL: URL) throws {
        let url = titleURL(for: mediaURL)
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func titleURL(for mediaURL: URL) -> URL {
        mediaURL.deletingLastPathComponent().appendingPathComponent("\(baseName(of: mediaURL)).title.txt")
    }

    /// The part before the first dot, shared by a capture and all its side files.
    public static func baseName(of url: URL) -> String {
        String(url.lastPathComponent.split(separator: ".", maxSplits: 1).first ?? "")
    }

    /// Writes `value` as JSON, or removes the file when there is nothing to keep.
    public static func write<Value: Encodable>(_ value: Value?, to url: URL) throws {
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
