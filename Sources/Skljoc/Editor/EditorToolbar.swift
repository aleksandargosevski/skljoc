import SkljocCore
import SwiftUI

/// Tools and style options above the canvas.
struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 1) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(tool: tool, isSelected: model.tool == tool) { model.selectTool(tool) }
                }
            }
            Divider().frame(height: 22)
            if model.isCropping {
                cropOptions
            } else if model.isEditingBackground {
                Text("Style the background in the panel on the right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                styleOptions
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                IconButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)", action: model.undo).disabled(!model.canUndo)
                IconButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: model.redo).disabled(!model.canRedo)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var styleOptions: some View {
        HStack(spacing: 5) {
            ForEach(RGBAColor.presets, id: \.self) { color in
                ColorSwatch(color: color, isSelected: model.currentColor == color) { model.setColor(color) }
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.currentColor.nsColor) },
                set: { model.setColor(RGBAColor(NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Custom color")
        }
        Picker("Size", selection: Binding(get: { model.size }, set: model.setSize)) {
            Text("S").tag(StrokeSize.small)
            Text("M").tag(StrokeSize.medium)
            Text("L").tag(StrokeSize.large)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
        .help(model.activeKind == .text ? "Font size" : model.activeKind == .counter ? "Number size" : "Line width")
        kindOptions
    }

    @ViewBuilder
    private var kindOptions: some View {
        switch model.activeKind {
        case .rectangle, .oval:
            Toggle("Fill", isOn: Binding(get: { model.filled }, set: model.setFilled))
                .toggleStyle(.checkbox)
                .help("Fill the shape (or hold ⌥ while drawing)")
        case .text:
            Picker("Style", selection: Binding(get: { model.textStyle }, set: model.setTextStyle)) {
                Text("Outline").tag(TextStyle.outlined)
                Text("Pill").tag(TextStyle.pill)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        case .redact:
            Picker("Style", selection: Binding(get: { model.redactStyle }, set: model.setRedactStyle)) {
                Text("Pixelate").tag(RedactStyle.pixelate)
                Text("Blur").tag(RedactStyle.blur)
                Text("Solid").tag(RedactStyle.solid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Solid is the safest for sensitive data")
        case .highlight:
            Text("Hold ⌥ to draw freehand")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .counter:
            Text("Click to place · drag to point at something")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .spotlight:
            Picker("Shape", selection: Binding(get: { model.spotlightShape }, set: model.setSpotlightShape)) {
                Image(systemName: "rectangle").tag(SpotlightShape.rectangle)
                Image(systemName: "circle").tag(SpotlightShape.ellipse)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cropOptions: some View {
        Text("Drag to crop · ⇧ keeps the ratio")
            .font(.callout)
            .foregroundStyle(.secondary)
        Button("Reset", action: model.resetCropDraft)
        Button("Cancel", action: model.cancelCrop)
            .keyboardShortcut(.cancelAction)
        Button("Apply") { model.applyCrop() }
            .keyboardShortcut(.defaultAction)
    }
}

/// Drag handle, export actions and Done below the canvas.
struct EditorActionBar: View {
    var dragItem: () -> NSItemProvider
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var upload: () -> Void
    var done: () -> Void
    var pin: () -> Void
    var copyText: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Drag", systemImage: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                .contentShape(Rectangle())
                .onDrag(dragItem)
                .help("Drag the edited screenshot into any app")
            Button(action: copyText) { Label("Copy Text", systemImage: "text.viewfinder") }
                .help("Recognize the text in the screenshot and copy it")
            Button(action: pin) { Label("Pin", systemImage: "pin") }
                .help("Keep it on top of all windows")
            Spacer()
            Button(action: upload) { Label("Upload", systemImage: "icloud.and.arrow.up") }
            Button(action: { NSEvent.modifierFlags.contains(.option) ? saveAs() : save() }) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save (⌘S) · Option-click or ⇧⌘S to choose where")
            Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy (⌘C)")
            Button(action: done) { Text("Done").frame(minWidth: 50) }
                .buttonStyle(.borderedProminent)
                .help("Back to the preview (⌘W)")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.25) : .clear))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ColorSwatch: View {
    let color: RGBAColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
