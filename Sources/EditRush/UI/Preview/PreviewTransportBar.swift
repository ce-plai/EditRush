import SwiftUI
import EditRushCore

/// Timecode, transport controls and the canvas aspect menu below the viewer.
struct PreviewTransportBar: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        // Equal-width side columns keep the transport centred; each side compacts when narrow.
        HStack(spacing: 10) {
            PreviewTimecodeLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                PreviewTransportButton(symbol: "backward.end.fill", help: "Go to Start") { playback.goToStart() }
                PreviewTransportButton(symbol: "backward.frame.fill", help: "Previous Frame") { playback.stepFrames(-1) }
                PreviewPlayPauseButton()
                    .padding(.horizontal, 4)
                PreviewTransportButton(symbol: "forward.frame.fill", help: "Next Frame") { playback.stepFrames(1) }
                PreviewTransportButton(symbol: "forward.end.fill", help: "Go to End") { playback.goToEnd() }
            }
            .fixedSize()
            PreviewCanvasMenu()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.panelHeader)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// Current time / total duration; the only transport view that observes the playhead.
private struct PreviewTimecodeLabel: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        let fps = store.project.canvas.frameRate
        let current = Text(PreviewTimecode.string(store.playhead, fps: fps)).foregroundStyle(Theme.textPrimary)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                current
                Text("/")
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                Text(PreviewTimecode.string(store.project.duration, fps: fps))
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize()
            current.fixedSize()
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
    }
}

private struct PreviewPlayPauseButton: View {
    @Environment(PlaybackController.self) private var playback
    @State private var isHovered = false

    var body: some View {
        Button { playback.togglePlay() } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .offset(x: playback.isPlaying ? 0 : 1.5)
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(isHovered ? 1 : 0.9)))
                .contentShape(Circle())
        }
        .buttonStyle(PreviewPressableStyle())
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(playback.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
    }
}

private struct PreviewTransportButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PreviewPressableStyle())
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct PreviewPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Canvas aspect / size menu plus the viewer zoom label.
private struct PreviewCanvasMenu: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(detailed: true)
            content(detailed: false)
        }
    }

    private func content(detailed: Bool) -> some View {
        let canvas = store.project.canvas
        return HStack(spacing: 10) {
            Menu {
                ForEach(CanvasSettings.presets, id: \.name) { preset in
                    Button {
                        var next = preset.settings
                        next.frameRate = canvas.frameRate
                        next.backgroundColor = canvas.backgroundColor
                        store.setCanvas(next)
                    } label: {
                        let current = preset.settings.width == canvas.width && preset.settings.height == canvas.height
                        if current {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: canvas.width >= canvas.height ? "rectangle" : "rectangle.portrait")
                        .font(.system(size: 11, weight: .medium))
                    Text(PreviewCanvasLabel.ratio(canvas))
                        .font(.system(size: 12, weight: .semibold))
                    if detailed {
                        Text(verbatim: "\(canvas.width)×\(canvas.height)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help("Canvas size: \(PreviewCanvasLabel.presetName(canvas) ?? "Custom")")

            if detailed {
                Text("Fit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.divider, lineWidth: 1))
                    .help("The viewer is scaled to fit the panel")
            }
        }
        .fixedSize()
    }
}
