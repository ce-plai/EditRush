import SwiftUI
import EditRushCore

/// Window layout: media bin | preview | inspector, timeline below. (shell module owns this)
struct MainView: View {
    @Environment(EditorStore.self) private var store
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MediaBinView().frame(width: 260)
                Divider()
                PreviewView().frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView().frame(width: 300)
            }
            .frame(maxHeight: .infinity)
            Divider()
            TimelineView().frame(height: 300)
        }
        .background(Theme.windowBackground)
        .preferredColorScheme(.dark)
    }
}
