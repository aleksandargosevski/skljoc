import AppKit
import SkljocCore
import SwiftUI

/// Click, then press a key combination. Esc cancels, Delete clears the shortcut.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 130)
            }
            .help("Click and press a shortcut. Esc cancels, Delete clears it.")
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press shortcut…" }
        return shortcut?.description ?? "Record Shortcut"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        hint = nil
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { onRecordingChange(false) }
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty && event.keyCode == 53 {
            stopRecording()
            return
        }
        if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            stopRecording()
            onChange(nil)
            return
        }
        let candidate = Shortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: .init(eventFlags: UInt(flags.rawValue))
        )
        guard candidate.isValidGlobal else {
            hint = "Include ⌘, ⌃ or ⌥"
            return
        }
        stopRecording()
        onChange(candidate)
    }
}
