import SwiftUI
import EditRushCore

struct PreviewView: View {
    @Environment(EditorStore.self) private var store
    var body: some View {
        Text("PreviewView").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelBackground)
    }
}
