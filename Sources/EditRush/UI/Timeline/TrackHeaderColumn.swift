import SwiftUI
import EditRushCore

/// Fixed column of track headers (name, hide / mute / lock) that scrolls vertically with the
/// tracks. Reads only `TimelineSharedState`, which changes when tracks change — not on clip edits.
struct TrackHeaderColumn: View {
    let store: EditorStore
    let shared: TimelineSharedState

    var body: some View {
        VStack(spacing: 0) {
            TrackHeaderCorner(store: store)
                .frame(height: Theme.rulerHeight)
            TrackHeaderRows(store: store, shared: shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(width: Theme.trackHeaderWidth)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
    }
}

private struct TrackHeaderRows: View {
    let store: EditorStore
    let shared: TimelineSharedState

    var body: some View {
        let layout = shared.layout
        // An overlay so the (possibly taller) row stack never affects the column's own layout.
        Color.clear.overlay(alignment: .topLeading) {
            rows(layout)
                .offset(y: -shared.offsetY)
        }
    }

    private func rows(_ layout: TimelineLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.rows) { row in
                TrackHeaderRow(row: row, store: store)
                    .frame(width: Theme.trackHeaderWidth, height: row.height)
                    .offset(y: row.y)
            }
            if let separator = layout.groupSeparatorY {
                Rectangle()
                    .fill(Theme.windowBackground)
                    .frame(height: TimelineMetrics.groupGap)
                    .offset(y: separator - TimelineMetrics.groupGap / 2)
            }
            AddTrackButtons(store: store)
                .offset(y: layout.tracksHeight + 8)
        }
        .frame(width: Theme.trackHeaderWidth, height: layout.contentHeight, alignment: .topLeading)
    }
}

/// Top-left corner above the headers: add-track menu.
private struct TrackHeaderCorner: View {
    let store: EditorStore

    var body: some View {
        HStack(spacing: 6) {
            Text("Tracks")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            Menu {
                Button("Add Video Track") { store.addTrack(.video) }
                Button("Add Audio Track") { store.addTrack(.audio) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Track")
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1) }
    }
}

private struct TrackHeaderRow: View {
    let row: TimelineRow
    let store: EditorStore

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(row.kind == .video ? Theme.videoClip : Theme.audioClip)
                .frame(width: 3)
                .opacity(row.isLocked ? 0.4 : 1)
            VStack(alignment: .leading, spacing: row.kind == .video ? 8 : 3) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: row.kind == .video ? "film" : "waveform")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
                HStack(spacing: 2) {
                    if row.kind == .video {
                        TrackToggleButton(icon: row.isHidden ? "eye.slash.fill" : "eye.fill", isOn: row.isHidden,
                                          tint: Theme.accent, help: row.isHidden ? "Show Track" : "Hide Track") {
                            store.setTrack(row.trackID, hidden: !row.isHidden)
                        }
                    }
                    TrackToggleButton(icon: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", isOn: row.isMuted,
                                      tint: Theme.playhead, help: row.isMuted ? "Unmute Track" : "Mute Track") {
                        store.setTrack(row.trackID, muted: !row.isMuted)
                    }
                    TrackToggleButton(icon: row.isLocked ? "lock.fill" : "lock.open.fill", isOn: row.isLocked,
                                      tint: Theme.selection, help: row.isLocked ? "Unlock Track" : "Lock Track") {
                        store.setTrack(row.trackID, locked: !row.isLocked)
                    }
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .contentShape(Rectangle())
        .contextMenu {
            if row.kind == .video {
                Button(row.isHidden ? "Show Track" : "Hide Track") { store.setTrack(row.trackID, hidden: !row.isHidden) }
            }
            Button(row.isMuted ? "Unmute Track" : "Mute Track") { store.setTrack(row.trackID, muted: !row.isMuted) }
            Button(row.isLocked ? "Unlock Track" : "Lock Track") { store.setTrack(row.trackID, locked: !row.isLocked) }
            Divider()
            Button("Add Video Track") { store.addTrack(.video) }
            Button("Add Audio Track") { store.addTrack(.audio) }
            Divider()
            Button("Remove Track \(row.name)", role: .destructive) { store.removeTrack(row.trackID) }
        }
    }
}

private struct TrackToggleButton: View {
    let icon: String
    let isOn: Bool
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOn ? tint : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? tint.opacity(0.18) : Color.white.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct AddTrackButtons: View {
    let store: EditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AddTrackButton(title: "Video Track") { store.addTrack(.video) }
            AddTrackButton(title: "Audio Track") { store.addTrack(.audio) }
        }
        .padding(.leading, 8)
    }
}

private struct AddTrackButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add \(title)")
    }
}
