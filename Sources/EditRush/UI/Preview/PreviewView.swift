import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditRushCore

/// The viewer panel: canvas with live video and on-canvas transform controls, transport below.
struct PreviewView: View {
    var body: some View {
        VStack(spacing: 0) {
            PreviewStage()
            PreviewTransportBar()
        }
        .background(Theme.panelBackground)
    }
}

/// Darker surround with the canvas fitted inside; hosts the player, overlay, empty state and drops.
private struct PreviewStage: View {
    @Environment(EditorStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    @State private var isDropTargeted = false

    /// Extra room on top keeps the rotation handle reachable for full-canvas clips.
    private static let insets = EdgeInsets(top: 34, leading: 24, bottom: 22, trailing: 24)

    var body: some View {
        let canvas = store.project.canvas
        let isEmpty = store.project.tracks.allSatisfy { $0.clips.isEmpty }
        GeometryReader { geo in
            let mapping = PreviewCanvasMapping(canvasSize: canvas.size, container: geo.size, insets: Self.insets)
            ZStack(alignment: .topLeading) {
                Self.surround

                canvasContent(mapping: mapping)
                    .frame(width: mapping.viewRect.width, height: mapping.viewRect.height)
                    .background(Color(cgColor: canvas.backgroundColor.cgColor))
                    .clipShape(Rectangle())
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                    .offset(x: mapping.viewRect.minX, y: mapping.viewRect.minY)
                    .opacity(isEmpty ? 0 : 1)

                if isEmpty {
                    PreviewEmptyState(isTargeted: isDropTargeted)
                        .padding(Self.insets)
                } else {
                    PreviewTransformOverlay(mapping: mapping)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .overlay(alignment: .top) { PreviewErrorBadge().padding(.top, 8) }
        .overlay { VoiceoverOverlay() }
        .overlay {
            if isDropTargeted && !isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private static let surround = Color(red: 0.075, green: 0.075, blue: 0.08)

    @ViewBuilder
    private func canvasContent(mapping: PreviewCanvasMapping) -> some View {
        if AppEnvironment.shared.isSnapshotMode {
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            PreviewSnapshotFrame(pixelSize: CGSize(width: (mapping.viewRect.width * backing).rounded(),
                                                   height: (mapping.viewRect.height * backing).rounded()))
        } else {
            PreviewPlayerSurface(player: playback.player).equatable()
        }
    }

    // MARK: Drops

    /// Finder files are imported; media-bin items are used directly. Everything lands at the
    /// playhead, one after another (visual and audio media each chain from the playhead).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let textProviders = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !fileProviders.isEmpty || !textProviders.isEmpty else { return false }
        let store = self.store
        let key = "preview-drop-\(UUID())"
        Task { @MainActor in
            var items: [MediaItem] = []
            let urls = await PreviewDropLoader.urls(from: fileProviders)
            if !urls.isEmpty { items += await ImportActions.importURLs(urls, store: store, coalesce: key) }
            for string in await PreviewDropLoader.strings(from: textProviders) {
                if let id = MediaDragPayload.mediaID(from: string), let media = store.media(id) { items.append(media) }
            }
            Self.place(items, store: store, coalesce: key)
        }
        return true
    }

    /// Adds `items` at the playhead as one undo step, visual and audio media each chaining one
    /// after another, and selects them.
    static func place(_ items: [MediaItem], store: EditorStore, coalesce key: String = "preview-drop-\(UUID())") {
        var visualTime = store.playhead, audioTime = store.playhead
        var added: [UUID] = []
        for item in items {
            let isAudio = item.kind == .audio
            guard let id = store.addClip(mediaID: item.id, at: isAudio ? audioTime : visualTime, coalesce: key),
                  let clip = store.clip(id) else { continue }
            added.append(id)
            if isAudio { audioTime = clip.end } else { visualTime = clip.end }
        }
        store.endCoalescing()
        if added.count > 1 { store.selection = Set(added) }
    }
}

/// Async wrappers around NSItemProvider loading.
private enum PreviewDropLoader {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url, url.isFileURL { result.append(url) }
        }
        return result
    }

    static func strings(from providers: [NSItemProvider]) async -> [String] {
        var result: [String] = []
        for provider in providers {
            let string: String? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: String.self) { s, _ in cont.resume(returning: s) }
            }
            if let string { result.append(string) }
        }
        return result
    }
}

/// Friendly drop target shown while the timeline is empty. Imported media lands on the timeline,
/// just like a drop.
private struct PreviewEmptyState: View {
    @Environment(EditorStore.self) private var store
    let isTargeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(isTargeted ? Theme.accent.opacity(0.10) : Color.white.opacity(0.02))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Theme.accent : Color.white.opacity(0.16),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5]))
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(isTargeted ? Theme.accent : Theme.textSecondary)
                VStack(spacing: 5) {
                    Text("Drop videos, photos and music here")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("MP4, MOV, MP3, WAV, OGG, PNG and JPG — or import from your Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task { @MainActor in
                        PreviewStage.place(await ImportActions.presentImportPanel(store: store), store: store)
                    }
                } label: {
                    Label("Import Media…", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

/// Unobtrusive capsule for the last composition / playback error.
private struct PreviewErrorBadge: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        if let message = playback.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.selection)
                Text(message)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            .frame(maxWidth: 520)
            .help(message)
            .allowsHitTesting(true)
            .transition(.opacity)
        }
    }
}
