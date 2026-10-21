import SwiftUI
import EditRushCore

/// Timeline header row: timecode, edit actions, snapping and zoom.
struct TimelineToolbar: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            TimelineTimecode()
                .padding(.trailing, 8)
            ToolbarDivider()
            SplitToolButton()
            TimelineToolButton(help: "Delete (⌫) · Ripple Delete (⇧⌫)", disabled: store.selection.isEmpty) {
                store.deleteSelection(ripple: NSEvent.modifierFlags.contains(.shift))
            } label: { Image(systemName: "trash") }
            TimelineToolButton(help: "Duplicate (⌘D)", disabled: store.selection.isEmpty) {
                store.duplicateSelection()
            } label: { Image(systemName: "plus.square.on.square") }
            TimelineToolButton(help: "Join Clips (⌘J)", disabled: !store.canJoinSelection) {
                store.joinSelection()
            } label: { Image(systemName: "arrow.triangle.merge").rotationEffect(.degrees(90)) }
            TimelineToolButton(help: store.selection.isEmpty ? "Close All Gaps" : "Close Gaps Before Selection",
                               disabled: !hasGaps) {
                store.closeGaps()
            } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left") }
            TimelineToolButton(help: "Detach Audio", disabled: detachableClips.isEmpty) {
                for clip in detachableClips { store.detachAudio(clip.id) }
            } label: { Image(systemName: "waveform.badge.minus") }
            ToolbarDivider()
            TimelineToolButton(help: "Add Title (⌘T)") {
                store.addTextClip()
            } label: {
                Text("T").font(.system(size: 15, weight: .bold, design: .serif))
            }
            fadeButton(fadeIn: true)
            fadeButton(fadeIn: false)
            Spacer(minLength: 12)
            TimelineToolButton(help: store.snappingEnabled ? "Snapping On" : "Snapping Off", isOn: store.snappingEnabled) {
                store.snappingEnabled.toggle()
            } label: { MagnetIcon().frame(width: 14, height: 14) }
            ToolbarDivider()
            TimelineZoomControls()
        }
        .padding(.horizontal, 8)
        .frame(height: TimelineMetrics.headerToolbarHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1) }
    }

    private var detachableClips: [Clip] {
        store.selectedClips.filter { clip in
            guard !clip.audioMuted, let media = store.media(clip.mediaID) else { return false }
            return media.kind == .video && media.hasAudio
        }
    }

    private var hasGaps: Bool {
        store.project.tracks.contains { track in
            var end: Seconds = 0
            for clip in track.clips {
                if clip.start - end > 1e-6 { return true }
                end = clip.end
            }
            return false
        }
    }

    /// Toggles a 1 s fade on the selection (removes it when every selected clip already has one).
    private func fadeButton(fadeIn: Bool) -> some View {
        let clips = store.selectedClips
        let allHave = !clips.isEmpty && clips.allSatisfy { fadeIn ? $0.fadeIn > 0 : $0.fadeOut > 0 }
        let name = fadeIn ? "Fade In" : "Fade Out"
        return TimelineToolButton(help: allHave ? "Remove \(name)" : "\(name) (1 s from \(fadeIn ? "" : "to ")black)",
                                  disabled: clips.isEmpty, isOn: allHave) {
            let value: Seconds = allHave ? 0 : 1
            if fadeIn { store.setFades(in: value, out: nil) } else { store.setFades(in: nil, out: value) }
        } label: {
            FadeRampIcon(rising: fadeIn).frame(width: 16, height: 13)
        }
    }
}

/// Current time / project duration. Isolated so playhead ticks only re-render this view.
private struct TimelineTimecode: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        let fps = store.project.canvas.frameRate
        HStack(spacing: 5) {
            Text(TimelineFormat.timecode(store.playhead, frameRate: fps))
                .foregroundStyle(Theme.textPrimary)
            Text("/ " + TimelineFormat.timecode(store.project.duration, frameRate: fps))
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .fixedSize()
        .help("Playhead / Duration (HH:MM:SS:FF at \(Int(fps.rounded())) fps)")
    }
}

/// Split button; isolated because its enabled state depends on the playhead.
private struct SplitToolButton: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        TimelineToolButton(help: "Split at Playhead (⌘B / S)", disabled: !canSplit) {
            store.splitAtPlayhead()
        } label: { Image(systemName: "scissors") }
    }

    private var canSplit: Bool {
        let t = store.playhead, margin = store.frameDuration / 2
        return store.project.tracks.contains { track in
            !track.isLocked && track.clips.contains { t > $0.start + margin && t < $0.end - margin }
        }
    }
}

private struct TimelineZoomControls: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        let range = EditorStore.zoomRange
        let ratio = log(range.upperBound / range.lowerBound)
        let position = Binding<Double>(
            get: { log(store.pixelsPerSecond / range.lowerBound) / ratio },
            set: { store.pixelsPerSecond = min(range.upperBound, max(range.lowerBound, range.lowerBound * exp($0 * ratio))) }
        )
        HStack(spacing: 2) {
            TimelineToolButton(help: "Zoom Out", disabled: store.pixelsPerSecond <= range.lowerBound) {
                store.zoom(by: 1 / 1.5)
            } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(value: position, in: 0...1)
                .controlSize(.mini)
                .frame(width: 110)
                .help("Zoom (pinch or ⌥-scroll on the timeline)")
            TimelineToolButton(help: "Zoom In", disabled: store.pixelsPerSecond >= range.upperBound) {
                store.zoom(by: 1.5)
            } label: { Image(systemName: "plus.magnifyingglass") }
            TimelineToolButton(help: "Zoom to Fit") {
                NotificationCenter.default.post(name: Notification.Name("EditRushZoomToFit"), object: nil)
            } label: { Image(systemName: "arrow.left.and.line.vertical.and.arrow.right") }
        }
    }
}

/// Compact icon button with hover / pressed / toggled states and a tooltip.
struct TimelineToolButton<Label: View>: View {
    let help: String
    var disabled = false
    var isOn = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(TimelineToolButtonStyle(isOn: isOn))
        .disabled(disabled)
        .help(help)
    }
}

private struct TimelineToolButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        TimelineToolButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct TimelineToolButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isOn ? Theme.accent : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(fill)
            )
            .opacity(isEnabled ? 1 : 0.32)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if configuration.isPressed { return Color.white.opacity(0.16) }
        if isOn { return Theme.accent.opacity(hovering ? 0.26 : 0.18) }
        return Color.white.opacity(hovering && isEnabled ? 0.08 : 0)
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 5)
    }
}

/// Horseshoe magnet (SF Symbols has none).
struct MagnetIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                MagnetShape().stroke(style: StrokeStyle(lineWidth: s * 0.22, lineCap: .butt))
                MagnetShape(tipsOnly: true).stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: s * 0.22, lineCap: .butt))
            }
            .frame(width: s, height: s)
        }
    }
}

private struct MagnetShape: Shape {
    var tipsOnly = false

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let left = rect.minX + w * 0.22, right = rect.maxX - w * 0.22
        let top = rect.minY + h * 0.08, bend = rect.minY + h * 0.52
        var p = Path()
        if tipsOnly {
            let tip = rect.minY + h * 0.26
            p.move(to: CGPoint(x: left, y: top)); p.addLine(to: CGPoint(x: left, y: tip))
            p.move(to: CGPoint(x: right, y: top)); p.addLine(to: CGPoint(x: right, y: tip))
            return p
        }
        let r = (right - left) / 2
        p.move(to: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: left, y: bend))
        p.addCurve(to: CGPoint(x: right, y: bend),
                   control1: CGPoint(x: left, y: bend + r * 4 / 3),
                   control2: CGPoint(x: right, y: bend + r * 4 / 3))
        p.addLine(to: CGPoint(x: right, y: top))
        return p
    }
}

/// Opacity ramp glyph for fade in (rising) / fade out (falling).
struct FadeRampIcon: View {
    let rising: Bool

    var body: some View {
        ZStack {
            FadeRampShape(rising: rising, filled: true).fill(.primary.opacity(0.35))
            FadeRampShape(rising: rising, filled: false).stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct FadeRampShape: Shape {
    let rising: Bool
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        let low = CGPoint(x: rising ? rect.minX : rect.maxX, y: rect.maxY)
        let high = CGPoint(x: rising ? rect.maxX : rect.minX, y: rect.minY)
        let corner = CGPoint(x: high.x, y: rect.maxY)
        var p = Path()
        p.move(to: low)
        p.addLine(to: high)
        if filled {
            p.addLine(to: corner)
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return p
    }
}
