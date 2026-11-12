import AppKit
import SkljocCore

enum EditorTool: String, CaseIterable, Identifiable {
    case crop, rectangle, oval, line, arrow, text, redact, spotlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: "Crop"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        }
    }

    var key: Character {
        switch self {
        case .crop: "c"
        case .rectangle: "r"
        case .oval: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .redact: "x"
        case .spotlight: "s"
        }
    }

    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "flashlight.on.fill"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .crop: nil
        case .rectangle: .rectangle
        case .oval: .oval
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .redact: .redact
        case .spotlight: .spotlight
        }
    }
}

/// The editor's state: the document being edited, the current tool and style, selection and undo.
@MainActor
final class EditorModel: ObservableObject {
    let capture: Capture

    @Published private(set) var document: EditorDocument
    @Published private(set) var tool: EditorTool = .arrow
    @Published private(set) var color: RGBAColor = .red
    @Published private(set) var size: StrokeSize = .medium
    @Published private(set) var filled = false
    @Published private(set) var textStyle: TextStyle = .outlined
    @Published private(set) var redactStyle: RedactStyle = .pixelate
    @Published private(set) var spotlightShape: SpotlightShape = .rectangle
    @Published var selectedID: UUID?
    @Published var cropDraft: CGRect?
    @Published var editingTextID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var history = History<EditorDocument>()
    private var toolBeforeCrop: EditorTool = .arrow

    init(capture: Capture) {
        self.capture = capture
        self.document = capture.document
    }

    var isCropping: Bool { tool == .crop }

    var selected: Annotation? { selectedID.flatMap(document.annotation(withID:)) }

    /// The kind whose options the toolbar shows: the selection's, otherwise the tool's.
    var activeKind: Annotation.Kind? { selected?.kind ?? tool.annotationKind }

    // MARK: Tools and style

    func selectTool(_ newTool: EditorTool) {
        guard newTool != tool else { return }
        if isCropping { applyCrop(switchingTo: newTool); return }
        if newTool == .crop {
            toolBeforeCrop = tool
            selectedID = nil
            cropDraft = document.crop ?? document.imageBounds
        }
        tool = newTool
    }

    func applyCrop(switchingTo nextTool: EditorTool? = nil) {
        guard isCropping else { return }
        if let cropDraft { change { $0.crop = cropDraft } }
        cropDraft = nil
        tool = nextTool ?? toolBeforeCrop
    }

    func cancelCrop() {
        guard isCropping else { return }
        cropDraft = nil
        tool = toolBeforeCrop
    }

    func resetCropDraft() {
        cropDraft = document.imageBounds
    }

    func setColor(_ newColor: RGBAColor) {
        color = newColor
        updateSelected { $0.color = newColor }
    }

    func setSize(_ newSize: StrokeSize) {
        size = newSize
        updateSelected { $0.size = newSize }
    }

    func setFilled(_ newValue: Bool) {
        filled = newValue
        updateSelected { $0.filled = newValue }
    }

    func setTextStyle(_ style: TextStyle) {
        textStyle = style
        updateSelected { $0.textStyle = style }
    }

    func setRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        updateSelected { $0.redactStyle = style }
    }

    func setSpotlightShape(_ shape: SpotlightShape) {
        spotlightShape = shape
        updateSelected { $0.spotlightShape = shape }
    }

    /// Selecting an annotation shows its style in the toolbar, so changes start from what's there.
    func select(_ id: UUID?) {
        selectedID = id
        guard let annotation = selected else { return }
        color = annotation.color
        size = annotation.size
        filled = annotation.filled
        textStyle = annotation.textStyle
        redactStyle = annotation.redactStyle
        spotlightShape = annotation.spotlightShape
    }

    func makeAnnotation(_ kind: Annotation.Kind, at point: CGPoint, filled forceFilled: Bool = false) -> Annotation {
        let annotation = Annotation(
            kind: kind, start: point, end: point, color: color, size: size,
            filled: filled || forceFilled, textStyle: textStyle, redactStyle: redactStyle, spotlightShape: spotlightShape
        )
        return kind == .text ? TextLayout.fitted(annotation) : annotation
    }

    // MARK: Changes and history

    /// Live updates while dragging; `commit(from:)` records them as one undo step afterwards.
    func setDocumentLive(_ newDocument: EditorDocument) {
        document = newDocument
    }

    func commit(from previous: EditorDocument) {
        guard previous != document else { return }
        history.record(previous)
        syncCapture()
    }

    func change(_ body: (inout EditorDocument) -> Void) {
        let previous = document
        body(&document)
        commit(from: previous)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        change { $0.remove(id: id) }
        selectedID = nil
    }

    func nudgeSelected(by delta: CGVector) {
        guard let annotation = selected else { return }
        change { $0.update(annotation.moved(by: delta)) }
    }

    func undo() {
        guard let previous = history.undo(from: document) else { return }
        document = previous
        afterHistoryJump()
    }

    func redo() {
        guard let next = history.redo(from: document) else { return }
        document = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        if let id = selectedID, document.annotation(withID: id) == nil { selectedID = nil }
        if isCropping { cropDraft = document.crop ?? document.imageBounds }
        syncCapture()
    }

    private func updateSelected(_ body: (inout Annotation) -> Void) {
        guard var annotation = selected else { return }
        body(&annotation)
        if annotation.kind == .text { annotation = TextLayout.fitted(annotation) }
        change { $0.update(annotation) }
    }

    private func syncCapture() {
        capture.document = document
        capture.saveEdits()
        canUndo = history.canUndo
        canRedo = history.canRedo
    }
}
