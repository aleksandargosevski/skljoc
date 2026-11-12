import CoreGraphics
import Testing
@testable import SkljocCore

@Suite struct GeometryTests {
    @Test func rectIsNormalizedWhicheverWayYouDrag() {
        let rect = Geometry.rect(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 0))
        #expect(rect == CGRect(x: 10, y: 0, width: 40, height: 40))
    }

    @Test func squareEndFollowsTheLongerSide() {
        let end = Geometry.squareEnd(from: .zero, to: CGPoint(x: -30, y: 10))
        #expect(end == CGPoint(x: -30, y: 30))
    }

    @Test func snapsToFortyFiveDegrees() {
        let end = Geometry.snappedEnd(from: .zero, to: CGPoint(x: 100, y: 8))
        #expect(abs(end.y) < 0.001)
        #expect(abs(end.x - hypot(100, 8)) < 0.001)

        let diagonal = Geometry.snappedEnd(from: .zero, to: CGPoint(x: 50, y: 45))
        #expect(abs(diagonal.x - diagonal.y) < 0.001)
    }

    @Test func distanceToSegmentClampsToEndpoints() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        #expect(Geometry.distance(from: CGPoint(x: 5, y: 3), toSegmentFrom: a, to: b) == 3)
        #expect(Geometry.distance(from: CGPoint(x: 13, y: 4), toSegmentFrom: a, to: b) == 5)
    }

    @Test func resizingPastTheOppositeEdgeFlips() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let resized = Geometry.resize(rect, handle: .left, to: CGPoint(x: 40, y: 0))
        #expect(resized == CGRect(x: 30, y: 10, width: 10, height: 20))
    }

    @Test func aspectResizeKeepsTheRatio() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let resized = Geometry.resizeKeepingAspect(rect, handle: .bottomRight, to: CGPoint(x: 80, y: 25))
        #expect(resized == CGRect(x: 0, y: 0, width: 80, height: 40))
    }

    @Test func slideKeepsRectInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let slid = Geometry.slide(CGRect(x: 90, y: -5, width: 20, height: 20), into: bounds)
        #expect(slid == CGRect(x: 80, y: 0, width: 20, height: 20))
    }

    @Test func arrowHeadEndsAtTheTip() {
        let head = Geometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)
        #expect(head.tip == CGPoint(x: 100, y: 0))
        #expect(head.left.x < 100 && head.right.x < 100)
        #expect(head.left.y == -head.right.y)
    }
}
