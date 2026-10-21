import SwiftUI
import AppKit
import EditRushCore

/// Hosts the track headers (SwiftUI) and the timeline canvas (AppKit) side by side.
struct TimelineBodyRepresentable: NSViewRepresentable {
    let store: EditorStore
    let playback: PlaybackController
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache

    func makeNSView(context: Context) -> TimelineBodyView {
        TimelineBodyView(store: store, playback: playback, thumbnails: thumbnails, waveforms: waveforms)
    }

    func updateNSView(_ nsView: TimelineBodyView, context: Context) {}
}

/// Container: fixed header column on the left, canvas (ruler + tracks) filling the rest.
@MainActor
final class TimelineBodyView: NSView {
    let canvas: TimelineCanvasView
    private let headers: TimelineHeaderHostingView
    private let separator = NSBox()

    init(store: EditorStore, playback: PlaybackController, thumbnails: ThumbnailCache, waveforms: WaveformCache) {
        let shared = TimelineSharedState()
        canvas = TimelineCanvasView(store: store, playback: playback, thumbnails: thumbnails,
                                    waveforms: waveforms, shared: shared)
        headers = TimelineHeaderHostingView(rootView: TrackHeaderColumn(store: store, shared: shared))
        headers.sizingOptions = []
        headers.canvas = canvas
        super.init(frame: .zero)
        clipsToBounds = true
        headers.clipsToBounds = true
        canvas.clipsToBounds = true
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = NSColor.black.withAlphaComponent(0.5)
        addSubview(headers)
        addSubview(separator)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = Theme.trackHeaderWidth
        headers.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        separator.frame = CGRect(x: w, y: 0, width: 1, height: bounds.height)
        canvas.frame = CGRect(x: w + 1, y: 0, width: max(0, bounds.width - w - 1), height: bounds.height)
    }
}

/// Header column host that forwards scroll / zoom gestures to the canvas, so the headers
/// scroll the tracks just like the clip area does.
final class TimelineHeaderHostingView: NSHostingView<TrackHeaderColumn> {
    weak var canvas: TimelineCanvasView?

    override func scrollWheel(with event: NSEvent) {
        if let canvas { canvas.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if let canvas { canvas.magnify(with: event) } else { super.magnify(with: event) }
    }
}
