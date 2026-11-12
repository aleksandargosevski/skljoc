import AppKit
import SwiftUI

/// A short confirmation like "Saved to Desktop" in the corner where previews appear.
@MainActor
final class Toast {
    private var panel: PreviewPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String, systemImage: String, onClick: (() -> Void)? = nil) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(message: message, systemImage: systemImage) { [weak self] in
            onClick?()
            self?.hide()
        }
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        let visible = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.minX + 16, y: visible.minY + 16, width: size.width, height: size.height)
        let panel = PreviewPanel(contentRect: frame)
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(message, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.black.opacity(0.82)))
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}
