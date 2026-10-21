import SwiftUI
import EditRushCore

struct MediaBinView: View {
    @Environment(EditorStore.self) private var store
    var body: some View {
        Text("MediaBinView").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelBackground)
    }
}
