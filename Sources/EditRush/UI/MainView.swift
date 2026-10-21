import SwiftUI
import UniformTypeIdentifiers
import EditRushCore

/// Window layout: media bin | preview | inspector, timeline below a resizable divider.
/// Also hosts the window toolbar, the status toast, the export sheet and Finder drops.
struct MainView: View {
    @Environment(EditorStore.self) private var store
    @Environment(Exporter.self) private var exporter
    @Environment(ShellState.self) private var shell
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var shell = shell
        VStack(spacing: 0) {
            if AppEnvironment.shared.isSnapshotMode {
                ShellToolbarStrip()
            }
            ShellVerticalSplit {
                workspace
            } bottom: {
                TimelineView()
            }
        }
        .background(Theme.windowBackground)
        .frame(minWidth: 1020, minHeight: 640)
        .navigationTitle(store.project.name)
        .toolbar { ShellToolbar() }
        .toolbar(removing: .title)
        .sheet(isPresented: $shell.isExportSheetPresented) {
            ExportSheet().appEnvironment()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { await ShellFileDrop.handle(providers, store: store) }
            return true
        }
        .overlay { if isDropTargeted { ShellDropHighlight() } }
        .onChange(of: exporter.state) { _, state in
            guard !shell.isExportSheetPresented else { return }
            switch state {
            case .finished(let url): store.statusMessage = "Exported “\(url.lastPathComponent)”"
            case .failed(let message): store.statusMessage = "Export failed: \(message)"
            default: break
            }
        }
        .preferredColorScheme(.dark)
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            MediaBinView().frame(width: 260)
            Divider()
            PreviewView().frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            InspectorView().frame(width: 300)
        }
        .overlay(alignment: .bottom) { StatusToastOverlay() }
    }
}

// MARK: - Resizable split

/// Top / bottom split with a draggable divider; the bottom pane's share of the height is
/// remembered across launches. Double-click the divider to restore the default.
private struct ShellVerticalSplit<Top: View, Bottom: View>: View {
    static var defaultFraction: Double { 0.38 }
    private let minTop: CGFloat = 300
    private let minBottom: CGFloat = 170
    private let handleHeight: CGFloat = 6

    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    @AppStorage("shell.timelineFraction") private var fraction = Self.defaultFraction
    @State private var dragStart: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.height - handleHeight)
            let bottomHeight = clampedBottom(fraction * available, available: available)
            VStack(spacing: 0) {
                top.frame(height: available - bottomHeight)
                handle(available: available)
                bottom.frame(height: bottomHeight)
            }
        }
    }

    private func clampedBottom(_ height: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(minBottom, available - minTop)
        return min(upper, max(min(minBottom, available), height))
    }

    private func handle(available: CGFloat) -> some View {
        ZStack {
            Theme.windowBackground
            Rectangle().fill(isHovering || dragStart != nil ? Theme.accent.opacity(0.7) : Theme.divider).frame(height: 1)
            Capsule().fill(Color.white.opacity(isHovering ? 0.35 : 0.18)).frame(width: 36, height: 3)
        }
        .frame(height: handleHeight)
        .contentShape(Rectangle())
        .pointerStyle(.rowResize)
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    guard available > 0 else { return }
                    let start = dragStart ?? fraction
                    dragStart = start
                    let height = clampedBottom(start * available - value.translation.height, available: available)
                    fraction = height / available
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { fraction = Self.defaultFraction }
        .help("Drag to resize the timeline")
    }
}

// MARK: - Toolbar

/// Window toolbar: undo / redo, project name, import, add title and export.
private struct ShellToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ShellUndoRedoButtons()
        }
        ToolbarItem(placement: .principal) {
            ShellProjectTitle()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ShellImportButton()
            ShellAddTitleButton()
            ShellExportButton()
        }
    }
}

/// In-content stand-in for the window toolbar, used by `--snapshot` (offscreen hosting views
/// have no window toolbar).
private struct ShellToolbarStrip: View {
    var body: some View {
        HStack(spacing: 10) {
            ShellUndoRedoButtons()
            Spacer()
            ShellProjectTitle()
            Spacer()
            ShellImportButton()
            ShellAddTitleButton()
            ShellExportButton()
        }
        .buttonStyle(.bordered)
        .padding(.leading, 84)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct ShellUndoRedoButtons: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        Button(action: store.undo) {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .help(store.undoActionName.map { "Undo \($0)" } ?? "Nothing to undo")
        .disabled(store.undoActionName == nil)

        Button(action: store.redo) {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .help(store.redoActionName.map { "Redo \($0)" } ?? "Nothing to redo")
        .disabled(store.redoActionName == nil)
    }
}

private struct ShellImportButton: View {
    var body: some View {
        Button(action: ShellActions.importMedia) {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .help("Import video, audio and images (⌘I)")
    }
}

private struct ShellAddTitleButton: View {
    var body: some View {
        Button(action: ShellActions.addTitle) {
            Label("Title", systemImage: "textformat")
        }
        .help("Add a title at the playhead (⌘T)")
    }
}

private struct ShellExportButton: View {
    @Environment(EditorStore.self) private var store
    @Environment(Exporter.self) private var exporter

    var body: some View {
        Button(action: ShellActions.showExport) {
            HStack(spacing: 6) {
                if exporter.state == .exporting {
                    ProgressView(value: exporter.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text(verbatim: "\(Int((exporter.progress * 100).rounded()))%")
                        .monospacedDigit()
                } else {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
            }
        }
        .buttonStyle(ShellAccentButtonStyle(compact: true))
        .disabled(store.project.duration <= 0 && exporter.state != .exporting)
        .help(exporter.state == .exporting ? "Show export progress" : "Export the video (⌘E)")
    }
}

/// Editable project name with an "Edited" marker while there are unsaved changes.
private struct ShellProjectTitle: View {
    @Environment(EditorStore.self) private var store
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film.stack")
                .foregroundStyle(Theme.accent)
            // A hidden Text sizes the field to its content so the name hugs its icon.
            Text(draft.isEmpty ? "Project name" : draft)
                .font(.headline)
                .lineLimit(1)
                .padding(.trailing, 4)
                .hidden()
                .frame(minWidth: 60, maxWidth: 280)
                .overlay {
                    TextField("Project name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($isEditing)
                        .onSubmit(commit)
                        .help("Rename project")
                }
            if store.isDirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.raised, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .onAppear { draft = store.project.name }
        .onChange(of: store.project.name) { _, name in if !isEditing { draft = name } }
        .onChange(of: isEditing) { _, editing in if !editing { commit() } }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { draft = store.project.name; return }
        if name != store.project.name {
            store.mutate("Rename Project") { $0.name = name }
        }
    }
}

// MARK: - Status toast

/// Shows `store.statusMessage` at the bottom of the workspace and clears it after 4 s.
private struct StatusToastOverlay: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        ZStack {
            if let message = store.statusMessage {
                StatusToast(message: message)
                    .onTapGesture { store.statusMessage = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(message)
            }
        }
        .padding(.bottom, 18)
        .padding(.horizontal, 24)
        .animation(.snappy(duration: 0.25), value: store.statusMessage)
        .task(id: store.statusMessage) {
            guard let message = store.statusMessage else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, store.statusMessage == message { store.statusMessage = nil }
        }
    }
}

private struct StatusToast: View {
    let message: String

    private var isProblem: Bool {
        let lower = message.lowercased()
        return ["couldn't", "could not", "failed", "error", "missing", "unsupported", "can't", "cannot"]
            .contains { lower.contains($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? Color.orange : Theme.accent)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(Theme.raised.opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .help("Click to dismiss")
    }
}

// MARK: - Finder drops

/// Window-wide highlight while Finder files hover over an area without its own drop target.
private struct ShellDropHighlight: View {
    var body: some View {
        ZStack {
            Theme.accent.opacity(0.08)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(6)
            Label("Drop to import", systemImage: "square.and.arrow.down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Theme.raised, in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

/// Loads file URLs from drag providers and imports them (projects open, media goes to the bin).
@MainActor
enum ShellFileDrop {
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) else { continue }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            } else if let url = item as? URL {
                urls.append(url)
            }
        }
        return urls.filter(\.isFileURL)
    }

    /// Imports dropped files: a `.editrush` file opens as the project, media is added to the bin
    /// and the first new item is selected.
    static func handle(_ providers: [NSItemProvider], store: EditorStore) async {
        let urls = await fileURLs(from: providers)
        let projects = urls.filter { $0.pathExtension.lowercased() == Project.fileExtension }
        if let project = projects.first {
            AppEnvironment.shared.documents.open([project])
        }
        let media = urls.filter { $0.pathExtension.lowercased() != Project.fileExtension }
        guard !media.isEmpty else { return }
        let items = await ImportActions.importURLs(media, store: store)
        if let first = items.first { store.selectedMediaID = first.id }
    }
}

// MARK: - Styles

/// Filled accent button that stays blue in inactive windows (unlike `.borderedProminent`),
/// used for the primary call to action (Export, Import Media…).
struct ShellAccentButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .background {
                RoundedRectangle(cornerRadius: compact ? 7 : 8)
                    .fill(isEnabled ? Theme.accent : Theme.raised)
                    .brightness(configuration.isPressed ? -0.12 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
