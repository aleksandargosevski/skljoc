import CoreGraphics
import Foundation
import Testing
@testable import SkljocCore

@Suite struct EditorDocumentTests {
    private let size = CGSize(width: 200, height: 100)

    @Test func hitsTopmostAnnotation() {
        var document = EditorDocument(imageSize: size)
        let below = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 100, y: 100), filled: true)
        let above = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 100, y: 100), filled: true)
        document.add(below)
        document.add(above)
        #expect(document.annotation(at: CGPoint(x: 50, y: 50))?.id == above.id)
    }

    @Test func outlinedShapesAreHitOnlyNearTheirStroke() {
        let rect = Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 90))
        #expect(rect.hitTest(CGPoint(x: 11, y: 50)))
        #expect(!rect.hitTest(CGPoint(x: 60, y: 50)))

        let oval = Annotation(kind: .oval, start: .zero, end: CGPoint(x: 100, y: 100))
        #expect(oval.hitTest(CGPoint(x: 50, y: 1)))
        #expect(!oval.hitTest(CGPoint(x: 50, y: 50)))
    }

    @Test func shapesAboveSpotlightsAndRedactionsWinHitTests() {
        var document = EditorDocument(imageSize: size)
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        let redact = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 100, y: 100))
        document.add(arrow)
        document.add(redact)
        #expect(document.annotation(at: CGPoint(x: 50, y: 50))?.id == arrow.id)
    }

    @Test func cropIsClampedAndFullCropMeansNone() {
        var document = EditorDocument(imageSize: size)
        document.crop = CGRect(x: -10, y: 10, width: 50, height: 500)
        #expect(document.crop == CGRect(x: 0, y: 10, width: 40, height: 90))
        document.crop = CGRect(origin: .zero, size: size)
        #expect(document.crop == nil)
        #expect(!document.hasEdits)
    }

    @Test func resizingSegmentsMovesOnlyThatEnd() {
        let line = Annotation(kind: .line, start: .zero, end: CGPoint(x: 10, y: 10))
        let resized = line.resized(.end, to: CGPoint(x: 30, y: 5))
        #expect(resized.start == .zero)
        #expect(resized.end == CGPoint(x: 30, y: 5))
    }

    @Test func tinyShapesCountAsClicks() {
        #expect(Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 2, y: 50)).isTooSmall)
        #expect(!Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 20, y: 0)).isTooSmall)
        #expect(!Annotation(kind: .text, start: .zero, end: .zero).isTooSmall)
    }

    @Test func historyUndoesAndRedoes() {
        var history = History<Int>()
        history.record(1)
        history.record(2)
        #expect(history.undo(from: 3) == 2)
        #expect(history.undo(from: 2) == 1)
        #expect(history.undo(from: 1) == nil)
        #expect(history.redo(from: 1) == 2)
        history.record(5)
        #expect(!history.canRedo)
    }
}
