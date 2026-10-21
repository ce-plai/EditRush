import SwiftUI
import AppKit
import EditRushCore

/// Project media: import, filter, select, drag to the timeline, double-click to append after the playhead.
struct MediaBinView: View {
    @Environment(EditorStore.self) private var store
    @State private var filter: MediaBinFilter = .all
    @State private var missing: Set<UUID> = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .background(Theme.panelBackground)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { await ShellFileDrop.handle(providers, store: store) }
            return true
        }
        .overlay {
            if isDropTargeted && !store.project.media.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .task(id: store.project.media.map(\.url)) { await refreshMissing() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshMissing() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Media")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !store.project.media.isEmpty {
                    Text(verbatim: "\(store.project.media.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.raised, in: Capsule())
                }
                Spacer()
                Button(action: ShellActions.importMedia) {
                    Label("Import", systemImage: "plus")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .help("Import media (⌘I)")
            }
            Picker("Show", selection: $filter) {
                ForEach(MediaBinFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.panelHeader)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let all = store.project.media
        let items = all.filter { filter.includes($0.kind) }
        if all.isEmpty {
            MediaBinEmptyState(isTargeted: isDropTargeted)
        } else if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 26, weight: .light))
                Text("No \(filter.noun) in this project")
                    .font(.callout)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: deselect)
        } else {
            let usage = usageCounts()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 10)], spacing: 12) {
                    ForEach(items) { media in
                        MediaBinTile(
                            media: media,
                            isSelected: store.selectedMediaID == media.id,
                            isMissing: missing.contains(media.id),
                            usageCount: usage[media.id] ?? 0,
                            relink: { relink(media) }
                        )
                    }
                }
                .padding(12)
            }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: deselect)
            }
            footer
        }
    }

    private var footer: some View {
        Text("Double-click or drag to the timeline")
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Theme.panelHeader)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    // MARK: Helpers

    private func deselect() {
        ShellResponder.endTextEditing()
        store.selectedMediaID = nil
    }

    private func usageCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for track in store.project.tracks {
            for clip in track.clips {
                if let id = clip.mediaID { counts[id, default: 0] += 1 }
            }
        }
        return counts
    }

    /// Checks which media files are missing on disk, off the main thread. When missing files are
    /// back (drive reconnected), the preview rebuilds and their thumbnails / waveforms load again.
    private func refreshMissing() async {
        let entries = store.project.media.map { (id: $0.id, path: $0.url.path) }
        let result = await Task.detached(priority: .utility) {
            Set(entries.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
        }.value
        guard result != missing else { return }
        let restored = missing.subtracting(result)
        missing = result
        let urls = store.project.media.filter { restored.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        ThumbnailCache.shared.retryFailures(for: urls)
        WaveformCache.shared.retryFailures(for: urls)
        AppEnvironment.shared.playback.rebuildNow()
    }

    /// Lets the user point a missing media item at its new location.
    private func relink(_ media: MediaItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Locate “\(media.url.lastPathComponent)”"
        panel.directoryURL = media.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let probed = try await MediaImporter.probe(url)
                guard probed.kind == media.kind else {
                    store.statusMessage = "Couldn't relink: “\(url.lastPathComponent)” is not \(media.kind == .image ? "an image" : "a \(media.kind.rawValue) file")"
                    return
                }
                store.mutate("Relink Media") { project in
                    guard let i = project.media.firstIndex(where: { $0.id == media.id }) else { return }
                    project.media[i].url = url
                    project.media[i].duration = probed.duration
                    project.media[i].pixelWidth = probed.pixelWidth
                    project.media[i].pixelHeight = probed.pixelHeight
                    project.media[i].frameRate = probed.frameRate
                    project.media[i].hasAudio = probed.hasAudio
                }
                AssetCache.shared.purge(mediaID: media.id)
                AppEnvironment.shared.playback.rebuildNow()
                await refreshMissing()
                store.statusMessage = "Relinked “\(media.name)”"
            } catch {
                store.statusMessage = "Couldn't relink: \(error.localizedDescription)"
            }
        }
    }
}

/// Media bin kind filter.
enum MediaBinFilter: String, CaseIterable, Identifiable {
    case all, video, audio, images
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        }
    }

    var noun: String {
        switch self {
        case .all: "media"
        case .video: "video"
        case .audio: "audio"
        case .images: "images"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .video: "film"
        case .audio: "waveform"
        case .images: "photo"
        }
    }

    func includes(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: true
        case .video: kind == .video
        case .audio: kind == .audio
        case .images: kind == .image
        }
    }
}

/// Shown while the project has no media: a drop zone that also opens the import panel.
private struct MediaBinEmptyState: View {
    let isTargeted: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 4) {
                Text("Drop files here")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("or click Import to add video,\naudio and images")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Import Media…", action: ShellActions.importMedia)
                .buttonStyle(ShellAccentButtonStyle(compact: true))
                .padding(.top, 4)
            Text("MP4 · MOV · MP3 · WAV\nOGG · PNG · JPG")
                .multilineTextAlignment(.center)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Theme.accent.opacity(0.1) : (isHovering ? Color.white.opacity(0.025) : .clear))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Theme.accent : Color.white.opacity(0.14),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [6, 5]))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: ShellActions.importMedia)
        .onHover { isHovering = $0 }
        .padding(12)
    }
}
