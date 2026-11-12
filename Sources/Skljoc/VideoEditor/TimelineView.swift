import SkljocCore
import SwiftUI

/// Thumbnails with trim handles and the playhead, and one row per redaction with its keyframes.
struct TimelineView: View {
    @ObservedObject var model: VideoEditorModel

    private static let stripHeight: CGFloat = 46
    private static let rowHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack(alignment: .leading, spacing: 6) {
                strip(width: width)
                ForEach(model.edit.redactions) { redaction in
                    RedactionRow(model: model, redaction: redaction, width: width, duration: model.duration)
                        .frame(height: Self.rowHeight)
                }
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: Self.stripHeight + CGFloat(model.edit.redactions.count) * (Self.rowHeight + 6))
    }

    private func strip(width: CGFloat) -> some View {
        let startX = x(model.edit.trimStart, width)
        let endX = x(model.edit.trimEnd, width)
        return ZStack(alignment: .topLeading) {
            thumbnails(width: width)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { value in
                    model.pause()
                    model.seek(to: time(value.location.x, width))
                })

            Color.black.opacity(0.6).frame(width: max(0, startX)).allowsHitTesting(false)
            Color.black.opacity(0.6).frame(width: max(0, width - endX)).offset(x: endX).allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(0, endX - startX))
                .offset(x: startX)
                .allowsHitTesting(false)

            TrimHandle()
                .offset(x: startX - 6)
                .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                    model.pause()
                    model.setTrimStartLive(time(value.location.x, width))
                }.onEnded { _ in model.endLiveChange() })
                .help("Drag to trim the start")
            TrimHandle()
                .offset(x: endX - 6)
                .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                    model.pause()
                    model.setTrimEndLive(time(value.location.x, width))
                }.onEnded { _ in model.endLiveChange() })
                .help("Drag to trim the end")

            Rectangle()
                .fill(.white)
                .frame(width: 2, height: Self.stripHeight + 6)
                .shadow(radius: 1)
                .offset(x: x(model.currentTime, width) - 1, y: -3)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: Self.stripHeight)
    }

    private func thumbnails(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Color.gray.opacity(0.3)
            } else {
                ForEach(model.thumbnails.indices, id: \.self) { index in
                    Image(nsImage: model.thumbnails[index])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(model.thumbnails.count), height: Self.stripHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: Self.stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(time / model.duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x, 0), width) / width) * model.duration : 0
    }
}

private struct TrimHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 12, height: 46)
            .overlay(
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 6) }
                }
            )
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }
}

/// When a redaction is visible, with its keyframes as diamonds.
private struct RedactionRow: View {
    @ObservedObject var model: VideoEditorModel
    let redaction: VideoRedaction
    let width: CGFloat
    let duration: Double

    var body: some View {
        let startX = x(redaction.start)
        let endX = x(redaction.end)
        let isSelected = model.selectedRedactionID == redaction.id

        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.06))
            Capsule()
                .fill(isSelected ? Color.accentColor.opacity(0.75) : Color.gray.opacity(0.55))
                .frame(width: max(8, endX - startX))
                .offset(x: startX)
                .onTapGesture {
                    model.selectedRedactionID = redaction.id
                    if !redaction.isVisible(at: model.currentTime) { model.seek(to: redaction.start) }
                }
            edgeHandle(at: startX) { model.setRedactionRangeLive(redaction.id, start: time($0)) }
            edgeHandle(at: endX - 6) { model.setRedactionRangeLive(redaction.id, end: time($0)) }
            ForEach(redaction.keyframes.indices, id: \.self) { index in
                let keyframe = redaction.keyframes[index]
                let selected = isSelected && model.selectedKeyframe == index
                Rectangle()
                    .fill(selected ? Color.yellow : Color.white)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45))
                    .overlay(Rectangle().stroke(.black.opacity(0.4), lineWidth: 0.5).rotationEffect(.degrees(45)))
                    .offset(x: x(keyframe.time) - 4.5)
                    .onTapGesture { model.selectKeyframe(index, of: redaction.id) }
                    .help("Keyframe at \(SelectionMath.formatDuration(keyframe.time, showsTenths: true)) · ⌫ deletes it")
            }
        }
        .frame(width: width)
    }

    private func edgeHandle(at x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .offset(x: x)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                model.selectedRedactionID = redaction.id
                onDrag(value.location.x)
            }.onEnded { _ in model.endLiveChange() })
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }

    private func x(_ time: Double) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func time(_ x: CGFloat) -> Double {
        width > 0 ? Double(min(max(x, 0), width) / width) * duration : 0
    }
}
