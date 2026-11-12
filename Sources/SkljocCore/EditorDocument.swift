import CoreGraphics
import Foundation

/// Everything the editor adds to a screenshot. The image itself never changes, so every edit stays reversible.
public struct EditorDocument: Equatable, Codable, Sendable {
    public let imageSize: CGSize
    public private(set) var annotations: [Annotation] = []
    /// The visible part of the image; nil shows all of it.
    public var crop: CGRect? {
        didSet { crop = crop.flatMap(normalizedCrop) }
    }

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
    }

    public var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    public var visibleRect: CGRect { crop ?? imageBounds }

    public var hasEdits: Bool { !annotations.isEmpty || crop != nil }

    public func annotation(withID id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// The topmost annotation under `point`, matching the order things are drawn in.
    public func annotation(at point: CGPoint, tolerance: CGFloat = 6) -> Annotation? {
        drawingOrder.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    /// Redactions sit on the image, spotlights dim everything below the remaining shapes.
    public var drawingOrder: [Annotation] {
        annotations.filter { $0.kind == .redact }
            + annotations.filter { $0.kind == .spotlight }
            + annotations.filter { $0.kind != .redact && $0.kind != .spotlight }
    }

    public var spotlights: [Annotation] { annotations.filter { $0.kind == .spotlight } }

    public mutating func add(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    public mutating func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    public mutating func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    private func normalizedCrop(_ rect: CGRect) -> CGRect? {
        let clamped = Geometry.clamp(rect.integral, to: imageBounds)
        if clamped.width < 1 || clamped.height < 1 || clamped == imageBounds { return nil }
        return clamped
    }
}

/// Undo and redo as snapshots of a value, recorded before each change.
public struct History<State: Equatable>: Sendable where State: Sendable {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ previous: State) {
        undoStack.append(previous)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undo(from current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(from current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
