import SwiftUI
import AppKit
import EditRushCore

/// One media item in the bin: poster / waveform, kind and duration badges, name.
struct MediaBinTile: View {
    let media: MediaItem
    let isSelected: Bool
    let isMissing: Bool
    let usageCount: Int
    let relink: () -> Void

    @Environment(EditorStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MediaBinThumbnail(media: media)
                .overlay(alignment: .topLeading) { kindBadge.padding(5) }
                .overlay(alignment: .topTrailing) { cornerAccessory.padding(5) }
                .overlay(alignment: .bottomTrailing) { durationBadge.padding(5) }
                .overlay { if isMissing { missingOverlay } }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                }
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0.2), radius: isHovering ? 6 : 3, y: 2)

            Text(media.name)
                .font(.caption)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: addToTimeline)
        .simultaneousGesture(TapGesture().onEnded {
            ShellResponder.endTextEditing()
            store.selectedMediaID = media.id
        })
        .draggable(MediaDragPayload.string(for: media.id)) {
            MediaBinThumbnail(media: media)
                .frame(width: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .opacity(0.9)
        }
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .help(helpText)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    // MARK: Decorations

    private var borderColor: Color {
        if isSelected { return Theme.accent }
        return isHovering ? Color.white.opacity(0.28) : Color.white.opacity(0.07)
    }

    private var kindBadge: some View {
        Image(systemName: MediaBinTile.symbol(for: media.kind))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(MediaBinTile.tint(for: media.kind).opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var cornerAccessory: some View {
        if isHovering && !isMissing {
            Button(action: addToTimeline) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add to the timeline after the playhead")
        } else if usageCount > 0 {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.black.opacity(0.55), in: Circle())
                .help("Used \(usageCount) time\(usageCount == 1 ? "" : "s") in the timeline")
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if media.kind != .image {
            Text(MediaBinTile.format(media.duration))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var missingOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                Text("Missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var helpText: String {
        var parts = [media.url.lastPathComponent]
        switch media.kind {
        case .video:
            parts.append("\(media.pixelWidth)×\(media.pixelHeight) · \(Int(media.frameRate.rounded())) fps · \(MediaBinTile.format(media.duration))")
        case .image:
            parts.append("\(media.pixelWidth)×\(media.pixelHeight) image")
        case .audio:
            parts.append("Audio · \(MediaBinTile.format(media.duration))")
        }
        if isMissing { parts.append("File is missing — right-click to locate it") }
        return parts.joined(separator: "\n")
    }

    // MARK: Actions

    @ViewBuilder
    private var contextMenu: some View {
        Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle", action: addToTimeline)
            .disabled(isMissing)
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([media.url])
        }
        .disabled(isMissing)
        if isMissing {
            Button("Locate File…", systemImage: "magnifyingglass", action: relink)
        }
        Divider()
        Button(role: .destructive) {
            store.removeMedia(media.id)
        } label: {
            Label(usageCount > 0 ? "Remove from Project (and \(usageCount) clip\(usageCount == 1 ? "" : "s"))" : "Remove from Project",
                  systemImage: "trash")
        }
    }

    private func addToTimeline() {
        guard !isMissing else {
            store.statusMessage = "“\(media.url.lastPathComponent)” is missing — right-click it to locate the file."
            return
        }
        ShellResponder.endTextEditing()
        store.selectedMediaID = media.id
        MediaBinActions.append([media], store: store, playback: AppEnvironment.shared.playback)
    }

    // MARK: Shared styling

    static func symbol(for kind: MediaKind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    static func tint(for kind: MediaKind) -> Color {
        switch kind {
        case .video: Theme.videoClip
        case .audio: Theme.audioClip
        case .image: Theme.imageClip
        }
    }

    /// "0:06", "12:40", "1:02:03".
    static func format(_ seconds: Seconds) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 16:10 poster (video / image) or waveform (audio) for a media item.
struct MediaBinThumbnail: View {
    let media: MediaItem
    @Environment(ThumbnailCache.self) private var thumbnails
    @Environment(WaveformCache.self) private var waveforms

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background { placeholder }
            .overlay { content }
            .clipped()
    }

    private var placeholder: some View {
        let tint = MediaBinTile.tint(for: media.kind)
        return LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(Theme.raised)
    }

    @ViewBuilder
    private var content: some View {
        if media.kind == .audio {
            let _ = waveforms.version
            if let peaks = waveforms.peaks(for: media), !peaks.isEmpty {
                MediaBinWaveform(bars: MediaBinWaveform.bars(for: media.id, peaks: peaks))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        } else {
            let _ = thumbnails.version
            if let poster = thumbnails.poster(for: media) {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: MediaBinTile.symbol(for: media.kind))
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// Mirrored bar waveform drawn from a downsampled peak envelope.
struct MediaBinWaveform: View {
    let bars: [Float]

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let step = size.width / CGFloat(bars.count)
            let barWidth = max(1, step * 0.6)
            for (i, peak) in bars.enumerated() {
                let h = max(1.5, CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(i) * step + (step - barWidth) / 2, y: (size.height - h) / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(0.85)))
            }
        }
    }

    static let barCount = 36
    @MainActor private static var cache: [UUID: (sourceCount: Int, bars: [Float])] = [:]

    /// Max-pooled bars for `peaks`, memoized per media so re-renders stay cheap.
    @MainActor
    static func bars(for id: UUID, peaks: [Float]) -> [Float] {
        if let hit = cache[id], hit.sourceCount == peaks.count { return hit.bars }
        let bucket = max(1, peaks.count / barCount)
        var bars: [Float] = []
        bars.reserveCapacity(barCount)
        var i = 0
        while i < peaks.count && bars.count < barCount {
            bars.append(peaks[i..<min(peaks.count, i + bucket)].max() ?? 0)
            i += bucket
        }
        let loudest = max(bars.max() ?? 1, 0.05)
        bars = bars.map { min(1, $0 / loudest) }
        cache[id] = (peaks.count, bars)
        return bars
    }
}
