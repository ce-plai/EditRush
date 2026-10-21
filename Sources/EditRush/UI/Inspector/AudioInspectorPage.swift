import SwiftUI
import EditRushCore

/// Volume, mute and detach for audio clips and video clips with sound.
struct AudioInspectorPage: View {
    let clip: Clip
    let kind: InspectorClipKind
    @Environment(EditorStore.self) private var store

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let isVideo = kind == .video

        VStack(spacing: 0) {
            InspectorSection("Volume") {
                InspectorSliderRow(
                    title: "Level",
                    value: edit.binding("Volume", field: "volume", get: { clip.volume * 100 },
                                        set: { $0.volume = ($1 / 100).inspectorClamped(to: 0...2) }),
                    range: 0...200, defaultValue: 100, unit: "%",
                    detail: clip.audioMuted ? "Muted" : InspectorFormat.decibels(clip.volume),
                    onEditingChanged: edit.editingChanged)
                    .disabled(clip.audioMuted)
                InspectorToggleRow(title: isVideo ? "Mute clip audio" : "Mute", isOn: clip.audioMuted) { muted in
                    edit(muted ? "Mute Audio" : "Unmute Audio") { $0.audioMuted = muted }
                }
            }
            if isVideo {
                InspectorSection("Separate Audio") {
                    Button {
                        store.detachAudio(clip.id)
                    } label: {
                        Label("Detach Audio", systemImage: "rectangle.split.1x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(InspectorButtonStyle())
                    .disabled(clip.audioMuted)
                    InspectorCaption(text: clip.audioMuted
                        ? "This clip's own sound is muted. Unmute it to hear the embedded audio again."
                        : "Moves the sound onto an audio track as its own clip so you can trim, move and fade it separately.")
                }
            }
        }
    }
}
