import AppKit
import Combine
import Observation
import EditRushCore

/// The ruler + track area of the timeline, drawn with Core Graphics.
///
/// The view is always viewport-sized and manages its own scroll offsets, so drawing cost is
/// proportional to what is visible regardless of project length or zoom. Clip content redraws
/// only when something it reads changes (tracked with Observation inside `draw(_:)`); the
/// playhead is a separate subview that just moves, so playback never redraws clips.
@MainActor
final class TimelineCanvasView: NSView {
    let store: EditorStore
    let playback: PlaybackController
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    let shared: TimelineSharedState
    let recorder: VoiceoverRecorder

    /// Horizontal scroll offset in points (content x at the left edge of the view).
    var scrollX: CGFloat = 0
    /// Layout of the current project (refreshed on every project change).
    private(set) var rows = TimelineLayout(project: Project())
    private(set) var mediaIndex: [UUID: MediaItem] = [:]
    private var layoutRevision = -1
    /// Zoom level the current `scrollX` was computed for.
    var appliedPPS: Double

    /// Media whose file is missing on disk (checked off the main thread).
    var offlineMediaIDs: Set<UUID> = []
    private var checkedMediaURLs: [UUID: URL] = [:]

    // Interaction state
    var drag: CanvasDrag = .none
    var hover: CanvasHover = .none
    var snapGuide: Seconds?
    var dropPreview: TimelineDropPreview?
    /// Pasteboard contents of the current drag session (read once per session).
    var cachedDropSource: (sequence: Int, source: TimelineDropSource?)?
    var autoscrollTimer: Timer?
    var lastDragPoint: CGPoint?

    let playheadView = TimelinePlayheadView()
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?

    init(store: EditorStore, playback: PlaybackController, thumbnails: ThumbnailCache,
         waveforms: WaveformCache, shared: TimelineSharedState, recorder: VoiceoverRecorder) {
        self.store = store
        self.playback = playback
        self.thumbnails = thumbnails
        self.waveforms = waveforms
        self.shared = shared
        self.recorder = recorder
        self.appliedPPS = store.pixelsPerSecond
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(playheadView)
        registerForDraggedTypes(TimelineDropPreview.acceptedTypes)
        syncLayout()
        store.changes
            .sink { [weak self] _ in self?.projectDidChange() }
            .store(in: &cancellables)
        observePlayback()
        installNotifications()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    var pps: CGFloat { CGFloat(store.pixelsPerSecond) }
    var rulerHeight: CGFloat { Theme.rulerHeight }
    var trackViewportHeight: CGFloat { max(0, bounds.height - rulerHeight) }

    /// View x of timeline time `t`.
    func x(for t: Seconds) -> CGFloat { TimelineMetrics.leadingPadding + CGFloat(t) * pps - scrollX }
    /// Timeline time at view x (not clamped).
    func rawTime(atX x: CGFloat) -> Seconds { Seconds((x + scrollX - TimelineMetrics.leadingPadding) / pps) }
    /// Timeline time at view x, clamped at 0.
    func time(atX x: CGFloat) -> Seconds { max(0, rawTime(atX: x)) }
    func viewY(_ contentY: CGFloat) -> CGFloat { rulerHeight + contentY - shared.offsetY }
    func contentY(_ viewY: CGFloat) -> CGFloat { viewY - rulerHeight + shared.offsetY }

    /// Seconds of timeline the content area spans: the project plus a generous tail.
    var contentDuration: Seconds {
        let visible = Double(bounds.width / pps)
        return max(store.project.duration + max(30, visible * 0.6), visible)
    }
    var contentWidth: CGFloat { TimelineMetrics.leadingPadding + CGFloat(contentDuration) * pps }
    var maxScrollX: CGFloat { max(0, contentWidth - bounds.width) }
    var maxScrollY: CGFloat { max(0, rows.contentHeight - trackViewportHeight) }
    var hasVerticalOverflow: Bool { maxScrollY > 0.5 }

    func row(atViewY y: CGFloat) -> TimelineRow? {
        guard y >= rulerHeight else { return nil }
        return rows.row(atY: contentY(y))
    }

    func clipRect(_ clip: Clip, in row: TimelineRow) -> CGRect {
        let x0 = x(for: clip.start), x1 = x(for: clip.end)
        return CGRect(x: x0, y: viewY(row.y) + TimelineMetrics.clipInset,
                      width: max(1, x1 - x0), height: row.height - 2 * TimelineMetrics.clipInset)
    }

    func track(_ id: UUID) -> Track? { store.project.tracks.first { $0.id == id } }

    /// Content kind of a clip (nil = text), matching `Track.accepts`.
    func contentKind(of clip: Clip) -> MediaKind? {
        clip.isText ? nil : mediaIndex[clip.mediaID ?? UUID()]?.kind
    }

    // MARK: - Project changes

    private func projectDidChange() {
        syncLayout()
        clampScroll()
        updatePlayhead()
        refreshOfflineMedia()
        needsDisplay = true
    }

    /// Recomputes rows / media lookup for the current project revision and publishes header rows.
    func syncLayout() {
        guard layoutRevision != store.revision else { return }
        layoutRevision = store.revision
        let project = store.project
        let layout = TimelineLayout(project: project)
        rows = layout
        mediaIndex = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if shared.layout != layout { shared.layout = layout }
    }

    /// Checks media files for existence off the main thread whenever the media set changes.
    func refreshOfflineMedia(force: Bool = false) {
        let current = Dictionary(store.project.media.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        guard force || current != checkedMediaURLs else { return }
        checkedMediaURLs = current
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(current.filter { !FileManager.default.fileExists(atPath: $0.value.path) }.keys)
            }.value
            guard let self, self.offlineMediaIDs != missing else { return }
            self.offlineMediaIDs = missing
            self.needsDisplay = true
        }
    }

    // MARK: - Playback observation

    private func observePlayback() {
        withObservationTracking {
            _ = store.playhead
            _ = store.pixelsPerSecond
            _ = playback.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackStateDidChange()
                self.observePlayback()
            }
        }
    }

    private func playbackStateDidChange() {
        reconcileZoom()
        updatePlayhead()
        if playback.isPlaying, !drag.isScrubbing { followPlayheadWhilePlaying() }
    }

    /// Adjusts the scroll offset after the zoom changed outside of a mouse-anchored zoom
    /// (toolbar slider, zoom to fit, menu commands): anchors on the playhead when visible.
    func reconcileZoom() {
        let newPPS = store.pixelsPerSecond
        guard newPPS != appliedPPS else { return }
        let oldPPS = CGFloat(appliedPPS)
        let playheadX = TimelineMetrics.leadingPadding + CGFloat(store.playhead) * oldPPS - scrollX
        let anchorX = (0...bounds.width).contains(playheadX) ? playheadX : 0
        let anchorTime = Seconds((anchorX + scrollX - TimelineMetrics.leadingPadding) / oldPPS)
        appliedPPS = newPPS
        scrollX = TimelineMetrics.leadingPadding + CGFloat(anchorTime) * pps - anchorX
        clampScroll()
        updatePlayhead()
        needsDisplay = true
    }

    private func followPlayheadWhilePlaying() {
        let px = x(for: store.playhead)
        guard px > bounds.width - 12 || px < 0 else { return }
        // Page: put the playhead near the left edge.
        scrollX = TimelineMetrics.leadingPadding + CGFloat(store.playhead) * pps - 24
        clampScroll()
        updatePlayhead()
        needsDisplay = true
    }

    /// Scrolls so the playhead is visible (centred-left) if it is outside the view.
    func revealPlayhead() {
        reconcileZoom()
        let px = x(for: store.playhead)
        guard px < 0 || px > bounds.width else { return }
        scrollX = TimelineMetrics.leadingPadding + CGFloat(store.playhead) * pps - bounds.width * 0.3
        clampScroll()
        updatePlayhead()
        needsDisplay = true
    }

    func updatePlayhead() {
        let px = x(for: store.playhead)
        let w = TimelinePlayheadView.width
        let frame = CGRect(x: (px - w / 2).rounded(), y: 0, width: w, height: bounds.height)
        if playheadView.frame != frame { playheadView.frame = frame }
        let hidden = px < -w || px > bounds.width + w
        if playheadView.isHidden != hidden { playheadView.isHidden = hidden }
    }

    // MARK: - Scrolling & zoom

    func clampScroll() {
        scrollX = min(max(0, scrollX), maxScrollX)
        let y = min(max(0, shared.offsetY), maxScrollY)
        if y != shared.offsetY { shared.offsetY = y }
    }

    func scroll(byX dx: CGFloat, y dy: CGFloat) {
        let oldX = scrollX, oldY = shared.offsetY
        scrollX += dx
        shared.offsetY += dy
        clampScroll()
        guard oldX != scrollX || oldY != shared.offsetY else { return }
        updatePlayhead()
        needsDisplay = true
    }

    /// Zooms by `factor` keeping the time under view x `anchorX` fixed.
    func zoom(by factor: Double, anchorX: CGFloat) {
        reconcileZoom()
        let anchorTime = rawTime(atX: anchorX)
        store.zoom(by: factor)
        appliedPPS = store.pixelsPerSecond
        scrollX = TimelineMetrics.leadingPadding + CGFloat(anchorTime) * pps - anchorX
        clampScroll()
        updatePlayhead()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            guard delta != 0 else { return }
            zoom(by: exp(Double(delta) * 0.012), anchorX: p.x)
            return
        }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 12; dy *= 12
            // A plain mouse wheel scrolls time when there is nothing to scroll vertically.
            if !hasVerticalOverflow, abs(dy) > abs(dx) { dx = dy; dy = 0 }
        }
        scroll(byX: -dx, y: -dy)
        if drag.isActive, let last = lastDragPoint { continueDrag(at: last) }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + Double(event.magnification), anchorX: p.x)
    }

    override func smartMagnify(with event: NSEvent) {
        store.zoomToFit()
        reconcileZoom()
        scrollX = 0
        clampScroll()
        updatePlayhead()
        needsDisplay = true
    }

    // MARK: - View lifecycle

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
        updatePlayhead()
        let width = Double(newSize.width)
        if width > 0, store.timelineViewportWidth != width {
            Task { @MainActor [weak self] in self?.store.timelineViewportWidth = width }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: Notification.Name("EditRushZoomToFit"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.zoomToFit()
                self.reconcileZoom()
                self.scrollX = 0
                self.clampScroll()
                self.updatePlayhead()
                self.needsDisplay = true
            }
        })
        notificationTokens.append(center.addObserver(forName: Notification.Name("EditRushRevealPlayhead"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealPlayhead() }
        })
        notificationTokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOfflineMedia(force: true) }
        })
    }
}

/// The playhead: a handle in the ruler and a line across all tracks. A separate view so moving
/// it never redraws the timeline content. Transparent to mouse events.
final class TimelinePlayheadView: NSView {
    static let width: CGFloat = 13

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let midX = bounds.midX
        let color = TimelinePalette.playhead
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: midX - 0.75, y: 8, width: 1.5, height: bounds.height - 8))
        // Pin-shaped handle inside the ruler.
        let w = bounds.width, top: CGFloat = 3, body: CGFloat = 12, tip: CGFloat = 18
        let handle = CGMutablePath()
        handle.addRoundedRect(in: CGRect(x: 0.5, y: top, width: w - 1, height: body - top), cornerWidth: 2.5, cornerHeight: 2.5)
        handle.move(to: CGPoint(x: 0.5, y: body - 2))
        handle.addLine(to: CGPoint(x: w - 0.5, y: body - 2))
        handle.addLine(to: CGPoint(x: midX, y: tip))
        handle.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(handle)
        ctx.fillPath()
    }
}
