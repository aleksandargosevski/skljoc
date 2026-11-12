import CoreGraphics
import Foundation
import Testing
@testable import SkljocCore

@Suite struct ScrollStitcherTests {
    private let width = 240
    private let frameHeight = 400
    private let header = 40
    private let footer = 24

    /// A tall page of varied rows, deterministic so failures can be reproduced.
    private func page(height: Int) -> [UInt8] {
        var state: UInt32 = 12345
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            state = state &* 1_103_515_245 &+ 12345
            let rowShade = Int(state >> 16) % 200
            for x in 0..<width {
                state = state &* 1_103_515_245 &+ 12345
                pixels[row * width + x] = UInt8((rowShade + Int(state >> 24) % 50 + x / 30 * 3) % 256)
            }
        }
        return pixels
    }

    /// What the screen shows when the page is scrolled to `offset`, with a sticky header and footer.
    private func frame(_ page: [UInt8], offset: Int) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * frameHeight)
        for row in 0..<frameHeight {
            for x in 0..<width {
                let value: UInt8
                if row < header {
                    value = 230
                } else if row >= frameHeight - footer {
                    value = UInt8(20 + x % 7)
                } else {
                    value = page[(offset + row - header) * width + x]
                }
                pixels[row * width + x] = value
            }
        }
        return GrayImage(width: width, height: frameHeight, pixels: pixels)
    }

    @Test func findsStickyHeaderAndFooter() {
        let content = page(height: 2000)
        let edges = ScrollStitcher.fixedEdges(frame(content, offset: 0), frame(content, offset: 120))
        #expect(edges.top == header)
        #expect(edges.bottom == footer)
    }

    @Test func findsHowFarThePageScrolled() {
        let content = page(height: 2000)
        for shift in [1, 37, 120, 250] {
            let offset = ScrollStitcher.scrollOffset(from: frame(content, offset: 100), to: frame(content, offset: 100 + shift), top: header, bottom: footer)
            #expect(offset == shift)
        }
    }

    @Test func reportsNoMovement() {
        let content = page(height: 2000)
        #expect(ScrollStitcher.scrollOffset(from: frame(content, offset: 50), to: frame(content, offset: 50), top: header, bottom: footer) == 0)
    }

    @Test func givesUpWithoutOverlap() {
        let content = page(height: 3000)
        let jump = frameHeight * 2
        #expect(ScrollStitcher.scrollOffset(from: frame(content, offset: 0), to: frame(content, offset: jump), top: header, bottom: footer) == nil)
    }
}

@Suite struct RecognizedTextTests {
    @Test func joinsRowsAndParagraphs() {
        let lines = [
            RecognizedLine(text: "world", box: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.05)),
            RecognizedLine(text: "Hello", box: CGRect(x: 0.05, y: 0.102, width: 0.2, height: 0.05)),
            RecognizedLine(text: "Second line", box: CGRect(x: 0.05, y: 0.16, width: 0.4, height: 0.05)),
            RecognizedLine(text: "New paragraph", box: CGRect(x: 0.05, y: 0.4, width: 0.4, height: 0.05)),
        ]
        #expect(RecognizedText.join(lines) == "Hello world\nSecond line\n\nNew paragraph")
    }
}

@Suite struct AnnotationFeatureTests {
    @Test func countersNumberThemselvesInOrder() {
        var document = EditorDocument(imageSize: CGSize(width: 300, height: 300))
        let first = Annotation(kind: .counter, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 20, y: 20))
        let second = Annotation(kind: .counter, start: CGPoint(x: 80, y: 20), end: CGPoint(x: 80, y: 20))
        let third = Annotation(kind: .counter, start: CGPoint(x: 140, y: 20), end: CGPoint(x: 140, y: 20))
        [first, second, third].forEach { document.add($0) }
        document.remove(id: second.id)
        #expect(document.counterNumber(for: third.id) == 2)
    }

    @Test func counterArrowAppearsWhenDraggedAway() {
        let plain = Annotation(kind: .counter, start: .zero, end: CGPoint(x: 5, y: 0))
        let pointing = Annotation(kind: .counter, start: .zero, end: CGPoint(x: 80, y: 0))
        #expect(!plain.hasCounterArrow)
        #expect(pointing.hasCounterArrow)
        #expect(pointing.hitTest(CGPoint(x: 60, y: 1)))
    }

    @Test func freehandHighlightMovesWithItsPoints() {
        let highlight = Annotation(kind: .highlight, start: .zero, end: .zero, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10)])
        #expect(highlight.hitTest(CGPoint(x: 50, y: 14)))
        #expect(!highlight.hitTest(CGPoint(x: 50, y: 60)))
        #expect(highlight.moved(by: CGVector(dx: 5, dy: 5)).points.first == CGPoint(x: 15, y: 15))
    }

    @Test func olderSavedAnnotationsStillLoad() throws {
        let json = #"{"id":"6C1F0D3A-6A55-4D7E-9F0B-1A2B3C4D5E6F","kind":"arrow","start":[0,0],"end":[10,10],"color":{"red":1,"green":0,"blue":0,"alpha":1},"size":"medium","filled":false,"text":"","textStyle":"outlined","redactStyle":"pixelate","spotlightShape":"rectangle"}"#
        let annotation = try JSONDecoder().decode(Annotation.self, from: Data(json.utf8))
        #expect(annotation.points.isEmpty)
        #expect(annotation.kind == .arrow)
    }

    @Test func backgroundLayoutPadsAndMatchesTheAspect() {
        var style = ScreenshotBackground()
        style.padding = 20
        let free = style.layout(for: CGSize(width: 200, height: 100))
        #expect(free.canvas == CGSize(width: 240, height: 140))
        #expect(free.content == CGRect(x: 20, y: 20, width: 200, height: 100))
        style.aspect = .square
        let square = style.layout(for: CGSize(width: 200, height: 100))
        #expect(square.canvas == CGSize(width: 240, height: 240))
        #expect(square.content.midY == 120)
    }
}
