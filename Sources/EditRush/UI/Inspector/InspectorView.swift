import SwiftUI
import EditRushCore

struct InspectorView: View {
    @Environment(EditorStore.self) private var store
    var body: some View {
        Text("InspectorView").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelBackground)
    }
}
