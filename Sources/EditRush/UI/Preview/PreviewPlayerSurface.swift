import SwiftUI
import AppKit
import AVFoundation
import EditRushCore

/// Live video: hosts the shared AVPlayer in an AVPlayerLayer. Equatable on player identity so
/// SwiftUI state changes elsewhere never touch the layer.
struct PreviewPlayerSurface: View, Equatable {
    let player: AVPlayer

    nonisolated static func == (a: Self, b: Self) -> Bool { a.player === b.player }

    var body: some View {
        PreviewPlayerLayerRepresentable(player: player)
    }
}

private struct PreviewPlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PreviewPlayerLayerNSView {
        let view = PreviewPlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PreviewPlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Layer-backed view whose backing layer is the AVPlayerLayer itself (no sublayer layout needed).
final class PreviewPlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { playerLayer }
    override var isOpaque: Bool { true }
    /// Mouse handling belongs to the SwiftUI overlay above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Snapshot-mode stand-in for the player: a still rendered by `FrameRenderer`, re-rendered when
/// the project revision, playhead or pixel size changes.
struct PreviewSnapshotFrame: View {
    @Environment(EditorStore.self) private var store
    /// Pixel size to render at.
    let pixelSize: CGSize

    @State private var image: CGImage?
    @State private var failed = false

    private struct RenderKey: Equatable {
        var revision: Int
        var playhead: Seconds
        var width: Int
        var height: Int
    }

    var body: some View {
        let key = RenderKey(revision: store.revision, playhead: store.playhead,
                            width: Int(pixelSize.width), height: Int(pixelSize.height))
        ZStack {
            Color(cgColor: store.project.canvas.backgroundColor.cgColor)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 26, weight: .light))
                    Text("Preview frame unavailable").font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.28))
            }
        }
        .task(id: key) {
            let project = store.project, t = store.playhead
            do {
                let rendered = try await FrameRenderer.image(of: project, at: t, maxSize: pixelSize)
                guard !Task.isCancelled else { return }
                image = rendered
                failed = false
            } catch {
                guard !Task.isCancelled else { return }
                image = nil
                failed = true
            }
        }
    }
}
