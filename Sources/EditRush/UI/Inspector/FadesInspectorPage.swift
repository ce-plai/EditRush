import SwiftUI
import EditRushCore

/// Longest fade the inspector offers.
let inspectorMaxFade: Seconds = 5

/// Fade in from black / fade out to black for one clip.
struct FadesInspectorPage: View {
    let clip: Clip
    let kind: InspectorClipKind
    @Environment(EditorStore.self) private var store

    private var isBottomLayer: Bool {
        guard let track = store.project.track(containing: clip.id) else { return true }
        return store.project.videoTracks.first?.id == track.id
    }

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let limit = max(0.01, min(inspectorMaxFade, clip.duration))
        let isAudio = kind == .audio

        VStack(spacing: 0) {
            InspectorSection(isAudio ? "Fade In" : "Fade In (from black)") {
                InspectorSliderRow(
                    title: "Duration",
                    value: edit.binding("Fade In", field: "fade-in", get: { clip.fadeIn },
                                        set: { c, v in c.fadeIn = Self.clampedFade(v, other: c.fadeOut, duration: c.duration) }),
                    range: 0...limit, defaultValue: 0, unit: "s", decimals: 2, onEditingChanged: edit.editingChanged)
                InspectorFadePresets(current: clip.fadeIn, limit: limit) { v in
                    edit("Fade In") { $0.fadeIn = Self.clampedFade(v, other: $0.fadeOut, duration: $0.duration) }
                }
            }
            InspectorSection(isAudio ? "Fade Out" : "Fade Out (to black)") {
                InspectorSliderRow(
                    title: "Duration",
                    value: edit.binding("Fade Out", field: "fade-out", get: { clip.fadeOut },
                                        set: { c, v in c.fadeOut = Self.clampedFade(v, other: c.fadeIn, duration: c.duration) }),
                    range: 0...limit, defaultValue: 0, unit: "s", decimals: 2, onEditingChanged: edit.editingChanged)
                InspectorFadePresets(current: clip.fadeOut, limit: limit) { v in
                    edit("Fade Out") { $0.fadeOut = Self.clampedFade(v, other: $0.fadeIn, duration: $0.duration) }
                }
            }
            InspectorCaption(text: caption)
                .padding(.horizontal, InspectorMetrics.hPadding)
                .padding(.vertical, 12)
        }
    }

    private var caption: String {
        if kind == .audio {
            return "Fades ramp the clip's volume up from silence and back down at the end."
        }
        return isBottomLayer
            ? "On the bottom track, fades go from and to black. On upper tracks they dissolve to the layers below."
            : "This clip is on an upper track, so its fades dissolve to the layers below instead of black."
    }

    /// Fade length limited to 0…5 s and to what the clip has left after the other fade.
    static func clampedFade(_ v: Seconds, other: Seconds, duration: Seconds) -> Seconds {
        v.inspectorClamped(to: 0...max(0, min(inspectorMaxFade, duration - other)))
    }
}

/// "None / 0.5 s / 1 s" quick fade buttons.
struct InspectorFadePresets: View {
    let current: Seconds
    let limit: Seconds
    let apply: (Seconds) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { v in
                Button { apply(v) } label: {
                    Text(v == 0 ? "None" : InspectorFormat.number(v, decimals: v == 1 ? 0 : 1) + " s")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InspectorButtonStyle(isSelected: abs(current - v) < 0.005))
                .disabled(v > limit + 0.0001)
            }
        }
    }
}
