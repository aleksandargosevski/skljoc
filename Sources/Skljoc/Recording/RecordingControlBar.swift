import AppKit
import SkljocCore
import SwiftUI

/// The bar under the recording area: format, size, inputs, overlays and the Record button.
struct RecordingControlBar: View {
    @ObservedObject var model: RecordingSetupModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Format", selection: $model.options.format) {
                ForEach(RecordingFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            Divider().frame(height: 22)
            sizeFields

            Divider().frame(height: 22)
            HStack(spacing: 4) {
                OptionToggle(title: "Camera", systemImage: "video.fill", isOn: $model.options.camera)
                deviceMenu(model.cameras, selection: $model.options.cameraID, extra: cameraExtras)
                OptionToggle(title: "Microphone", systemImage: "mic.fill", isOn: $model.options.microphone)
                    .disabled(model.options.format == .gif)
                deviceMenu(model.microphones, selection: $model.options.microphoneID, extra: { EmptyView() })
                    .disabled(model.options.format == .gif)
                OptionToggle(title: "Mac sound", systemImage: "speaker.wave.2.fill", isOn: $model.options.systemAudio)
                    .disabled(model.options.format == .gif)
                OptionToggle(title: "Highlight clicks", systemImage: "cursorarrow.click.2", isOn: $model.options.highlightClicks)
                OptionToggle(title: "Show keystrokes", systemImage: "keyboard", isOn: $model.options.showKeystrokes)
            }

            Divider().frame(height: 22)
            Button { model.onCancel?() } label: {
                Image(systemName: "xmark").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")

            Button { model.onRecord?() } label: {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Text(model.options.format == .gif ? "Record GIF" : "Record")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.red.opacity(model.selection == nil ? 0.4 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(model.selection == nil)
            .help("Start recording (↩)")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var sizeFields: some View {
        HStack(spacing: 4) {
            Text("W").font(.caption).foregroundStyle(.secondary)
            TextField("Width", value: Binding(
                get: { Int(model.pixelSize?.width ?? 0) },
                set: { model.setPixelWidth($0) }
            ), format: .number.grouping(.never))
            .frame(width: 54)
            Text("×").foregroundStyle(.secondary)
            Text("H").font(.caption).foregroundStyle(.secondary)
            TextField("Height", value: Binding(
                get: { Int(model.pixelSize?.height ?? 0) },
                set: { model.setPixelHeight($0) }
            ), format: .number.grouping(.never))
            .frame(width: 54)
            Menu {
                ForEach(SelectionPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { model.apply(preset) }
                }
            } label: {
                Image(systemName: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Size presets")
        }
        .textFieldStyle(.roundedBorder)
        .disabled(model.selection == nil)
    }

    @ViewBuilder
    private func cameraExtras() -> some View {
        Divider()
        Picker("Size", selection: $model.options.cameraSize) {
            Text("Small").tag(CameraSize.small)
            Text("Medium").tag(CameraSize.medium)
            Text("Large").tag(CameraSize.large)
        }
        Picker("Shape", selection: $model.options.cameraShape) {
            Text("Circle").tag(CameraShape.circle)
            Text("Rounded Rectangle").tag(CameraShape.roundedRectangle)
        }
    }

    private func deviceMenu<Extra: View>(_ devices: [MediaDevice], selection: Binding<String?>, @ViewBuilder extra: () -> Extra) -> some View {
        Menu {
            if devices.isEmpty {
                Text("No devices found")
            }
            Picker("Device", selection: selection) {
                ForEach(devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            extra()
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear(perform: model.refreshDevices)
    }
}

private struct OptionToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(isOn && isEnabled ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn && isEnabled ? Color.accentColor : Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title): \(isOn ? "on" : "off")")
    }
}
