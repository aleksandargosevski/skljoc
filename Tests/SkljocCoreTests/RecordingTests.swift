import CoreGraphics
import Foundation
import Testing
@testable import SkljocCore

@Suite struct VideoRedactionTests {
    private let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
    private let b = CGRect(x: 0.4, y: 0.6, width: 0.4, height: 0.2)

    @Test func interpolatesBetweenKeyframes() {
        var redaction = VideoRedaction(start: 1, end: 10, rect: a)
        redaction.setRect(b, at: 3)
        let middle = redaction.rect(at: 2)!
        #expect(abs(middle.minX - 0.2) < 0.0001)
        #expect(abs(middle.minY - 0.3) < 0.0001)
        #expect(abs(middle.width - 0.3) < 0.0001)
    }

    @Test func holdsFirstAndLastKeyframes() {
        var redaction = VideoRedaction(start: 0, end: 10, rect: a)
        redaction.setRect(b, at: 5)
        #expect(redaction.rect(at: 0) == a)
        #expect(redaction.rect(at: 9) == b)
    }

    @Test func isHiddenOutsideItsRange() {
        let redaction = VideoRedaction(start: 2, end: 4, rect: a)
        #expect(redaction.rect(at: 1.9) == nil)
        #expect(redaction.rect(at: 4.1) == nil)
        #expect(redaction.rect(at: 3) != nil)
    }

    @Test func movingAtAnExistingKeyframeUpdatesIt() {
        var redaction = VideoRedaction(start: 0, end: 10, rect: a)
        redaction.setRect(b, at: 0.01, tolerance: 0.02)
        #expect(redaction.keyframes.count == 1)
        #expect(redaction.keyframes[0].rect == b)
    }

    @Test func keepsKeyframesSortedAndTheLastOne() {
        var redaction = VideoRedaction(start: 0, end: 10, rect: a)
        redaction.setRect(b, at: 6)
        redaction.setRect(b, at: 3)
        #expect(redaction.keyframes.map(\.time) == [0, 3, 6])
        let first = redaction.removeKeyframe(at: 0)
        let second = redaction.removeKeyframe(at: 0)
        let last = redaction.removeKeyframe(at: 0)
        #expect(first && second && !last)
        #expect(redaction.keyframes.count == 1)
    }

    @Test func clampsRectsIntoTheVideo() {
        let redaction = VideoRedaction(start: 0, end: 1, rect: CGRect(x: 0.9, y: -0.2, width: 0.3, height: 0.3))
        let rect = redaction.keyframes[0].rect
        #expect(abs(rect.maxX - 1) < 0.0001)
        #expect(rect.minY == 0)
    }
}

@Suite struct VideoEditTests {
    @Test func trimStaysOrderedWithAMinimumLength() {
        var edit = VideoEdit(duration: 10, format: .video)
        edit.setTrimStart(4)
        edit.setTrimEnd(3)
        #expect(edit.trimStart == 4)
        #expect(abs(edit.trimEnd - (4 + VideoEdit.minimumLength)) < 0.0001)
        edit.setTrimStart(-5)
        #expect(edit.trimStart == 0)
    }

    @Test func untouchedRecordingsAreCopiedNotRendered() {
        var edit = VideoEdit(duration: 10, format: .video)
        #expect(!edit.needsRendering)
        edit.microphoneMuted = true
        #expect(edit.needsRendering)
        #expect(edit.effectiveMicrophoneVolume == 0)
    }

    @Test func exportResolutionScalesTheShortSideWithoutUpscaling() {
        #expect(ExportResolution.p720.size(for: CGSize(width: 2880, height: 1800)) == CGSize(width: 1152, height: 720))
        #expect(ExportResolution.p1080.size(for: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        #expect(ExportResolution.p480.size(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 480, height: 854))
    }
}

@Suite struct SelectionMathTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func pixelSizesAreEven() {
        #expect(SelectionMath.pixelSize(of: CGRect(x: 0, y: 0, width: 100.7, height: 50.3), scale: 2) == CGSize(width: 200, height: 100))
        #expect(SelectionMath.pixelSize(of: CGRect(x: 0, y: 0, width: 101, height: 51), scale: 1) == CGSize(width: 100, height: 50))
    }

    @Test func typedSizeKeepsTheCenter() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let resized = SelectionMath.resized(rect, toPixels: CGSize(width: 1920, height: 1080), scale: 2, within: bounds)
        #expect(resized.size == CGSize(width: 960, height: 540))
        #expect(resized.minX >= 0 && resized.minY >= 0)
    }

    @Test func aspectPresetFitsTheScreen() {
        let rect = CGRect(x: 0, y: 0, width: 1500, height: 100)
        let resized = SelectionMath.applyingAspect(1, to: rect, within: bounds)
        #expect(resized.width == bounds.height)
        #expect(resized.height == bounds.height)
    }

    @Test func gifSizeIsCappedAndEven() {
        #expect(SelectionMath.gifSize(for: CGSize(width: 1920, height: 1080), maxWidth: 960) == CGSize(width: 960, height: 540))
        #expect(SelectionMath.gifSize(for: CGSize(width: 640, height: 361), maxWidth: 960) == CGSize(width: 640, height: 360))
    }

    @Test func formatsDurations() {
        #expect(SelectionMath.formatDuration(42.4) == "0:42")
        #expect(SelectionMath.formatDuration(3723) == "1:02:03")
        #expect(SelectionMath.formatDuration(3.25, showsTenths: true) == "0:03.2")
    }
}

@Suite struct KeystrokeBufferTests {
    @Test func typingJoinsIntoText() {
        var buffer = KeystrokeBuffer()
        let start = Date()
        buffer.register(keyCode: 4, characters: "h", modifiers: [], at: start)
        let text = buffer.register(keyCode: 34, characters: "i", modifiers: [], at: start.addingTimeInterval(0.2))
        #expect(text == "hi")
    }

    @Test func shortcutsShowOnTheirOwn() {
        var buffer = KeystrokeBuffer()
        let start = Date()
        buffer.register(keyCode: 4, characters: "h", modifiers: [], at: start)
        #expect(buffer.register(keyCode: 21, characters: "4", modifiers: [.command, .shift], at: start) == "⇧⌘4")
        #expect(buffer.register(keyCode: 0, characters: "a", modifiers: [], at: start) == "a")
    }

    @Test func pausesStartOver() {
        var buffer = KeystrokeBuffer()
        let start = Date()
        buffer.register(keyCode: 0, characters: "a", modifiers: [], at: start)
        #expect(buffer.register(keyCode: 11, characters: "b", modifiers: [], at: start.addingTimeInterval(3)) == "b")
    }

    @Test func specialKeysUseSymbols() {
        var buffer = KeystrokeBuffer()
        #expect(buffer.register(keyCode: 36, characters: "\r", modifiers: [], at: Date()) == "↩")
    }
}
