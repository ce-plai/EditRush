import SwiftUI
import EditRushCore

struct ExportSheet: View {
    @Environment(EditorStore.self) private var store
    var body: some View {
        Text("ExportSheet").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelBackground)
    }
}
