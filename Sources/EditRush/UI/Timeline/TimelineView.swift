import SwiftUI
import EditRushCore

struct TimelineView: View {
    @Environment(EditorStore.self) private var store
    var body: some View {
        Text("TimelineView").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelBackground)
    }
}
