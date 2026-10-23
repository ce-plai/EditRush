import SwiftUI
import EditRushCore

/// Playback speed for one video or audio clip.
struct SpeedInspectorPage: View {
    let clip: Clip
    @Environment(EditorStore.self) private var store

    var body: some View {
        let fps = store.project.canvas.frameRate
        VStack(spacing: 0) {
            InspectorSection("Speed") {
                InspectorSpeedControls(speed: clip.speed, coalesceKey: "inspector-speed-\(clip.id.uuidString)") { speed, key in
                    store.setSpeed(speed, for: [clip.id], coalesce: key)
                }
                InspectorInfoRow(title: "Clip length", value: InspectorFormat.timecode(clip.duration, fps: fps))
                InspectorInfoRow(title: "Source used", value: InspectorFormat.timecode(clip.duration * clip.speed, fps: fps))
            }
            InspectorCaption(text: InspectorSpeedControls.caption)
                .padding(.horizontal, InspectorMetrics.hPadding)
                .padding(.vertical, 12)
        }
    }
}

/// Speed slider on a log scale (100 % in the middle), a percent field and quick presets, laid out
/// as rows of the enclosing section.
/// `apply` gets the new speed and, for live drags and typed values, an undo coalescing key.
struct InspectorSpeedControls: View {
    let speed: Double
    var detail: String?
    let coalesceKey: String
    let apply: (Double, String?) -> Void
    @Environment(EditorStore.self) private var store

    static let presets: [Double] = [0.25, 0.5, 1, 2, 4]
    static let caption = "Speed keeps the same footage, so the clip gets shorter or longer and later clips on its track move to make room. Audio keeps its pitch."
    private static let logRange = log2(Clip.speedRange.lowerBound)...log2(Clip.speedRange.upperBound)

    var body: some View {
        let percentRange = Clip.speedRange.lowerBound * 100...Clip.speedRange.upperBound * 100
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Rate")
                    .font(InspectorMetrics.labelFont)
                    .foregroundStyle(Theme.textPrimary)
                    .onTapGesture(count: 2) { reset() }
                    .help("Double-click to reset")
                if let detail {
                    Text(detail)
                        .font(InspectorMetrics.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                InspectorResetButton(action: reset)
                    .opacity(speed != 1 ? 1 : 0)
                    .disabled(speed == 1)
                InspectorNumberField(value: Binding(get: { speed * 100 }, set: { apply($0 / 100, coalesceKey) }),
                                     range: percentRange) { store.endCoalescing() }
                Text("%")
                    .font(InspectorMetrics.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, alignment: .leading)
            }
            InspectorSlider(value: Binding(get: { log2(speed) }, set: { apply(Self.speed(fromLog: $0), coalesceKey) }),
                            range: Self.logRange, origin: 0) { began in
                if !began { store.endCoalescing() }
            }
        }
        HStack(spacing: 6) {
            ForEach(Self.presets, id: \.self) { preset in
                Button { apply(preset, nil) } label: {
                    Text(TimelineFormat.speed(preset)).frame(maxWidth: .infinity)
                }
                .buttonStyle(InspectorButtonStyle(isSelected: abs(speed - preset) < 0.0005))
            }
        }
    }

    private func reset() {
        guard speed != 1 else { return }
        store.endCoalescing()
        apply(1, nil)
    }

    /// Slider position to a whole-percent speed, snapping to 100 % near the middle.
    private static func speed(fromLog v: Double) -> Double {
        abs(v) < 0.05 ? 1 : (pow(2, v) * 100).rounded() / 100
    }
}
