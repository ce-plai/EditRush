import SwiftUI
import EditRushCore

/// The timeline panel: toolbar row above a fixed-header, scrollable multi-track timeline.
struct TimelineView: View {
    @Environment(EditorStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    @Environment(ThumbnailCache.self) private var thumbnails
    @Environment(WaveformCache.self) private var waveforms

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar()
            TimelineBodyRepresentable(store: store, playback: playback, thumbnails: thumbnails, waveforms: waveforms)
        }
        .background(Theme.panelBackground)
    }
}
