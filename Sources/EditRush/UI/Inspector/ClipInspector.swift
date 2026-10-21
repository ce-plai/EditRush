import SwiftUI
import EditRushCore

/// What a clip shows, derived from its media (text clips have none) and its track: any clip on
/// an audio track (including audio detached from a video file) is audio.
enum InspectorClipKind {
    case video, image, audio, text

    init(clip: Clip, media: MediaItem?, trackKind: TrackKind? = nil) {
        if clip.isText { self = .text; return }
        if trackKind == .audio { self = .audio; return }
        switch media?.kind {
        case .audio: self = .audio
        case .image: self = .image
        case .video, nil: self = .video
        }
    }

    var title: String {
        switch self {
        case .video: "Video"
        case .image: "Image"
        case .audio: "Audio"
        case .text: "Title"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .text: "textformat"
        }
    }

    var tint: Color {
        switch self {
        case .video: Theme.videoClip
        case .image: Theme.imageClip
        case .audio: Theme.audioClip
        case .text: Theme.textClip
        }
    }
}

/// Property pages for a single clip.
enum InspectorTab: String, CaseIterable, Identifiable {
    case text, transform, fades, color, filters, audio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .transform: "Transform"
        case .fades: "Fades"
        case .color: "Color"
        case .filters: "Filters"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .transform: "arrow.up.left.and.arrow.down.right"
        case .fades: "circle.righthalf.filled"
        case .color: "camera.aperture"
        case .filters: "camera.filters"
        case .audio: "speaker.wave.2.fill"
        }
    }

    static func available(for kind: InspectorClipKind, media: MediaItem?) -> [InspectorTab] {
        switch kind {
        case .text: return [.text, .transform, .fades]
        case .image: return [.transform, .fades, .color, .filters]
        case .audio: return [.audio, .fades]
        case .video: return [.transform, .fades, .color, .filters] + ((media?.hasAudio ?? false) ? [.audio] : [])
        }
    }
}

/// Header with clip identity and timing, a tab bar and the selected property page.
struct ClipInspector: View {
    let clip: Clip
    @Environment(EditorStore.self) private var store
    /// Last chosen page for media clips, remembered across clips and launches.
    @AppStorage("inspector.tab") private var storedTab = InspectorTab.transform.rawValue
    /// Last chosen page for titles, which start on Text.
    @AppStorage("inspector.tab.title") private var storedTitleTab = InspectorTab.text.rawValue

    var body: some View {
        let media = store.media(clip.mediaID)
        let kind = InspectorClipKind(clip: clip, media: media, trackKind: store.project.track(containing: clip.id)?.kind)
        let tabs = InspectorTab.available(for: kind, media: media)
        let wantsText = kind == .text && InspectorFocus.shared.textEditRequest?.clipID == clip.id
        let stored = InspectorTab(rawValue: kind == .text ? storedTitleTab : storedTab)
        let tab = wantsText ? .text : stored.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]

        VStack(spacing: 0) {
            ClipInspectorHeader(clip: clip, media: media, kind: kind)
            InspectorTabBar(tabs: tabs, selection: tab) { selected in
                if kind == .text { storedTitleTab = selected.rawValue } else { storedTab = selected.rawValue }
            }
            ScrollView(.vertical) {
                page(tab, media: media, kind: kind)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .onChange(of: wantsText, initial: true) { _, wants in
            if wants { storedTitleTab = InspectorTab.text.rawValue }
        }
    }

    @ViewBuilder
    private func page(_ tab: InspectorTab, media: MediaItem?, kind: InspectorClipKind) -> some View {
        switch tab {
        case .text: TextInspectorPage(clip: clip)
        case .transform: TransformInspectorPage(clip: clip, kind: kind)
        case .fades: FadesInspectorPage(clip: clip, kind: kind)
        case .color: ColorInspectorPage(clip: clip)
        case .filters: FilterInspectorPage(clip: clip, media: media)
        case .audio: AudioInspectorPage(clip: clip, kind: kind)
        }
    }
}

/// Icon, editable name, media facts and timecodes.
struct ClipInspectorHeader: View {
    let clip: Clip
    let media: MediaItem?
    let kind: InspectorClipKind
    @Environment(EditorStore.self) private var store

    private var defaultName: String {
        if let text = clip.text {
            let line = text.text.split(separator: "\n").first.map(String.init) ?? ""
            return line.isEmpty ? "Title" : line
        }
        return media?.name ?? "Missing Media"
    }

    private var facts: String {
        var parts = [kind.title]
        if kind != .audio, let media, media.hasVisual, media.pixelWidth > 0 {
            parts.append("\(media.pixelWidth)×\(media.pixelHeight)")
        }
        if kind == .video, let media, media.kind == .video, media.frameRate > 0 {
            parts.append(InspectorFormat.number(media.frameRate, decimals: media.frameRate.rounded() == media.frameRate ? 0 : 2) + " fps")
        }
        if let track = store.project.track(containing: clip.id) {
            parts.append(store.project.displayName(of: track.id))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let fps = store.project.canvas.frameRate
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(kind.tint.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: kind.systemImage).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    InspectorTextField(text: clip.label ?? "", placeholder: defaultName,
                                       font: .system(size: 13, weight: .semibold), boxed: false) { newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateClip(clip.id, "Rename Clip") { $0.label = trimmed.isEmpty ? nil : trimmed }
                    }
                    .help("Clip name shown on the timeline")
                    Text(facts)
                        .font(InspectorMetrics.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .padding(.leading, 3)
                }
            }
            HStack(spacing: 0) {
                timecode("Start", InspectorFormat.timecode(clip.start, fps: fps))
                timecode("Duration", InspectorFormat.timecode(clip.duration, fps: fps))
                timecode(kind == .text || kind == .image ? "Source" : "Source In",
                         kind == .text || kind == .image ? "—" : InspectorFormat.timecode(clip.sourceIn, fps: fps))
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.windowBackground.opacity(0.6)))
        }
        .padding(.horizontal, InspectorMetrics.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func timecode(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Equal-width icon tabs with a selection underline.
struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    let selection: InspectorTab
    let select: (InspectorTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { select(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(height: 16)
                        Text(tab.title)
                            .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selected ? Theme.accent : .clear)
                            .frame(height: 2)
                            .padding(.horizontal, 8)
                    }
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .background(Theme.panelHeader.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}
