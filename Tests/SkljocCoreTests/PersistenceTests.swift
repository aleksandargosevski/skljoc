import CoreGraphics
import Foundation
import Testing
@testable import SkljocCore

@Suite struct PersistenceTests {
    @Test func screenshotEditsRoundTrip() throws {
        var document = EditorDocument(imageSize: CGSize(width: 400, height: 300))
        document.add(Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 50, y: 60), color: .blue, size: .large))
        document.add(Annotation(kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 40), text: "Škljoc", textStyle: .pill))
        document.crop = CGRect(x: 10, y: 10, width: 200, height: 100)
        let decoded = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
    }

    @Test func videoEditsRoundTrip() throws {
        var edit = VideoEdit(duration: 12, format: .gif)
        edit.setTrimStart(1.5)
        edit.resolution = .p720
        edit.microphoneMuted = true
        var redaction = VideoRedaction(style: .blur, start: 0, end: 12, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), keyframeTime: 3)
        redaction.setRect(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), at: 6)
        edit.redactions = [redaction]
        let decoded = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
        #expect(decoded == edit)
    }

    @Test func sideFilesShareTheBaseName() {
        let media = URL(fileURLWithPath: "/tmp/Captures/1794489938929.mp4")
        #expect(MediaFiles.editsURL(for: media).lastPathComponent == "1794489938929.edits.json")
        #expect(MediaFiles.baseName(of: MediaFiles.editsURL(for: media)) == "1794489938929")
    }

    @Test func writingNothingRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skljoc-test-\(UUID().uuidString).json")
        try MediaFiles.write(["a": 1], to: url)
        #expect(MediaFiles.read([String: Int].self, from: url) == ["a": 1])
        try MediaFiles.write(Optional<[String: Int]>.none, to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
