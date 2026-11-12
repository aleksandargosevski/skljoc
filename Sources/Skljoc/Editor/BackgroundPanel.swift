import SkljocCore
import SwiftUI

/// Side panel for the background: fill, padding, corners, shadow and aspect ratio.
struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel

    private var style: ScreenshotBackground { model.document.background ?? ScreenshotBackground() }
    private var isOn: Bool { model.document.background != nil }

    var body: some View {
        Form {
            Toggle("Background", isOn: Binding(get: { isOn }, set: model.setBackgroundEnabled))
                .toggleStyle(.switch)

            Section("Fill") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
                    ForEach(ScreenshotBackground.gradients.indices, id: \.self) { index in
                        let colors = ScreenshotBackground.gradients[index]
                        swatch(isSelected: style.fill == .gradient(index)) {
                            LinearGradient(colors: [Color(nsColor: colors.0.nsColor), Color(nsColor: colors.1.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        } action: {
                            update { $0.fill = .gradient(index) }
                        }
                    }
                    swatch(isSelected: style.fill == .transparent) {
                        Image(systemName: "checkerboard.rectangle").foregroundStyle(.secondary)
                    } action: {
                        update { $0.fill = .transparent }
                    }
                }
                ColorPicker("Solid color", selection: Binding(
                    get: {
                        if case .solid(let color) = style.fill { return Color(nsColor: color.nsColor) }
                        return .white
                    },
                    set: { color in update { $0.fill = .solid(RGBAColor(NSColor(color))) } }
                ), supportsOpacity: false)
            }

            Section("Frame") {
                slider("Padding", value: \.padding, range: 0...200)
                slider("Corners", value: \.cornerRadius, range: 0...40)
                Toggle("Shadow", isOn: Binding(get: { style.shadow }, set: { value in update { $0.shadow = value } }))
                if style.shadow {
                    Slider(value: Binding(
                        get: { style.shadowStrength },
                        set: { value in live { $0.shadowStrength = value } }
                    ), in: 0...1) { editing in if !editing { model.endLiveChange() } }
                }
                Picker("Size", selection: Binding(get: { style.aspect }, set: { value in update { $0.aspect = value } })) {
                    ForEach(ScreenshotBackground.Aspect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!isOn)
        .frame(width: 260)
    }

    private func slider(_ title: String, value: WritableKeyPath<ScreenshotBackground, CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(
                get: { style[keyPath: value] },
                set: { newValue in live { $0[keyPath: value] = newValue.rounded() } }
            ), in: range) { editing in if !editing { model.endLiveChange() } }
        }
    }

    private func swatch<Content: View>(isSelected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func update(_ body: (inout ScreenshotBackground) -> Void) {
        var copy = style
        body(&copy)
        model.setBackground(copy)
    }

    private func live(_ body: (inout ScreenshotBackground) -> Void) {
        var copy = style
        body(&copy)
        model.setBackgroundLive(copy)
    }
}
