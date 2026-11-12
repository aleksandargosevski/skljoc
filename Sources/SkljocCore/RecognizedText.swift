import CoreGraphics
import Foundation

/// A line of text found in an image. `box` is normalized (0…1) with a top-left origin.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

public enum RecognizedText {
    /// Puts recognized lines back in reading order: pieces on the same row are joined with spaces,
    /// rows with newlines, and a larger gap between rows becomes a blank line between paragraphs.
    public static func join(_ lines: [RecognizedLine]) -> String {
        let sorted = lines.filter { !$0.text.isEmpty }.sorted { $0.box.midY < $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.last, sameRow(last, line) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let averageHeight = sorted.map(\.box.height).reduce(0, +) / CGFloat(max(sorted.count, 1))
        var result = ""
        var previousBottom: CGFloat?
        for row in rows {
            let text = row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
            let top = row.map(\.box.minY).min() ?? 0
            if let previousBottom {
                result += top - previousBottom > averageHeight * 0.8 ? "\n\n" : "\n"
            }
            result += text
            previousBottom = row.map(\.box.maxY).max()
        }
        return result
    }

    private static func sameRow(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5
    }
}
