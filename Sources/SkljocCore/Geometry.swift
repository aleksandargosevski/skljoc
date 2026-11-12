import CoreGraphics

public enum Geometry {
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The end point that turns the drag into a square (or circle) anchored at `start`.
    public static func squareEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let side = max(abs(end.x - start.x), abs(end.y - start.y))
        return CGPoint(
            x: start.x + (end.x >= start.x ? side : -side),
            y: start.y + (end.y >= start.y ? side : -side)
        )
    }

    /// The end point snapped to the nearest multiple of 45° around `start`, keeping the length.
    public static func snappedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    public static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    public static func ellipse(_ rect: CGRect, contains point: CGPoint) -> Bool {
        let rx = rect.width / 2
        let ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let x = (point.x - rect.midX) / rx
        let y = (point.y - rect.midY) / ry
        return x * x + y * y <= 1
    }

    public static func isNearEllipseOutline(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Bool {
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        let insideInner = inner.width > 0 && inner.height > 0 && ellipse(inner, contains: point)
        return ellipse(outer, contains: point) && !insideInner
    }

    /// Moves the edges that belong to `handle` to `point`. Dragging past the opposite edge flips the rect.
    public static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .start, .end: break
        }
        return self.rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
    }

    /// Like `resize`, but keeps the aspect ratio of `rect` by following the larger change.
    public static func resizeKeepingAspect(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        let free = resize(rect, handle: handle, to: point)
        guard rect.width > 0, rect.height > 0 else { return free }
        let ratio = rect.width / rect.height
        var width = free.width
        var height = free.height
        switch handle {
        case .top, .bottom: width = height * ratio
        case .left, .right: height = width / ratio
        default:
            if width / ratio > height { height = width / ratio } else { width = height * ratio }
        }
        let anchor = anchorPoint(of: rect, opposite: handle)
        let growsLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let growsUp = [.topLeft, .top, .topRight].contains(handle)
        var x = growsLeft ? anchor.x - width : anchor.x
        var y = growsUp ? anchor.y - height : anchor.y
        if handle == .top || handle == .bottom { x = rect.midX - width / 2 }
        if handle == .left || handle == .right { y = rect.midY - height / 2 }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? bounds : clipped
    }

    /// Keeps `rect` inside `bounds` by sliding it, without changing its size where possible.
    public static func slide(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(rect.width, bounds.width)
        result.size.height = min(rect.height, bounds.height)
        result.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    public struct ArrowHead: Equatable, Sendable {
        public var tip: CGPoint
        public var left: CGPoint
        public var right: CGPoint
        /// Where the shaft ends, so its thick line doesn't poke through the tip.
        public var base: CGPoint
    }

    public static func arrowHead(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> ArrowHead {
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(max(lineWidth * 4, 14), length * 0.6)
        let halfWidth = headLength * 0.5
        let angle = atan2(end.y - start.y, end.x - start.x)
        let base = CGPoint(x: end.x - cos(angle) * headLength, y: end.y - sin(angle) * headLength)
        let normal = CGVector(dx: -sin(angle), dy: cos(angle))
        return ArrowHead(
            tip: end,
            left: CGPoint(x: base.x + normal.dx * halfWidth, y: base.y + normal.dy * halfWidth),
            right: CGPoint(x: base.x - normal.dx * halfWidth, y: base.y - normal.dy * halfWidth),
            base: CGPoint(x: end.x - cos(angle) * headLength * 0.8, y: end.y - sin(angle) * headLength * 0.8)
        )
    }

    private static func anchorPoint(of rect: CGRect, opposite handle: Handle) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .right: CGPoint(x: rect.minX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.maxX, y: rect.midY)
        case .start, .end: CGPoint(x: rect.minX, y: rect.minY)
        }
    }
}
