import SwiftUI
import EditRushCore

/// Right-hand properties panel: project settings with no selection, shared actions for a
/// multi-selection, and tabbed clip properties for a single clip.
/// Never reads `store.playhead`, so playback does not re-render it.
struct InspectorView: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        let selection = store.selection
        VStack(spacing: 0) {
            if selection.isEmpty {
                InspectorPanelHeader(title: "Project", systemImage: "film.stack")
                ProjectInspector()
            } else if let clip = store.primarySelection {
                InspectorPanelHeader(title: "Clip", systemImage: "slider.horizontal.3")
                ClipInspector(clip: clip)
                    .id(clip.id)
            } else {
                InspectorPanelHeader(title: "Selection", systemImage: "square.on.square")
                MultiSelectionInspector(clips: store.selectedClips)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
    }
}

/// Title bar at the top of the inspector.
struct InspectorPanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, InspectorMetrics.hPadding)
        .frame(height: 32)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}
