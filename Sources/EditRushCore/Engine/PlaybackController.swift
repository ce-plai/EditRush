import AVFoundation
import Combine
import Observation

/// Owns the AVPlayer used by the preview and keeps it in sync with the store.
///
/// * Subscribes to `store.changes`; rebuilds the composition (coalescing bursts of edits) and
///   swaps it into the player while preserving the current time and play state. Property-only
///   edits are cheap (reuse the AVPlayerItem; swap videoComposition/audioMix; re-seek when
///   paused so the visible frame refreshes).
/// * Structural edits that stream in (dragging or trimming a clip) are installed only once the
///   edits pause for `structuralSettleDelay`: a new player item shows no picture until its first
///   frame decodes, so installing one per mouse event would leave the preview black for the
///   whole gesture. Until then the current item keeps showing its last frame.
/// * While playing, updates `store.playhead` ~30×/s; stops at the end of the timeline.
/// * `seek(to:)` is the only way UI should move the playhead; scrubbing coalesces seeks
///   (chase-time pattern) so dragging the playhead stays smooth.
@MainActor
@Observable
public final class PlaybackController {
    public let player = AVPlayer()
    public private(set) var isPlaying = false
    /// Last error from building the composition (shown in the preview).
    public private(set) var lastError: String?
    /// True once a player item for the project has been installed.
    public private(set) var isReady = false
    @ObservationIgnored public let store: EditorStore

    /// Preview render size cap (long side); larger canvases render scaled down.
    public static let maxPreviewDimension = 1920.0
    /// Quiet time after a burst of edits before a structural rebuild replaces the player item.
    public static let structuralSettleDelay: Duration = .milliseconds(120)

    @ObservationIgnored private let assets: AssetCache
    @ObservationIgnored private var built: BuiltComposition?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var needsBuild = false
    @ObservationIgnored private var forceFullBuild = false
    @ObservationIgnored private var lastChange = ContinuousClock.now.advanced(by: .seconds(-3600))
    /// True while edits arrive less than `structuralSettleDelay` apart (a live drag / trim).
    @ObservationIgnored private var editsStreaming = false
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var itemSubscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var timeObserver: Any?

    // Chase-time seeking (Apple QA1820): at most one seek in flight; the latest request wins.
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var seekPending = false
    @ObservationIgnored private var seekTarget = CMTime.zero
    @ObservationIgnored private var seekPrecise = true

    public init(store: EditorStore) {
        self.store = store
        self.assets = .shared
        configure()
    }

    public init(store: EditorStore, assets: AssetCache) {
        self.store = store
        self.assets = assets
        configure()
    }

    private func configure() {
        player.actionAtItemEnd = .pause
        Task.detached(priority: .utility) { FrameCompositor.prewarm() }
        player.automaticallyWaitsToMinimizeStalling = false
        store.changes
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.projectChanged() }
            }
            .store(in: &subscriptions)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeAdvanced(time) }
        }
        scheduleBuild()
    }

    // MARK: - Transport

    public func play() {
        guard store.project.duration > 0 else { return }
        if store.playhead >= store.project.duration - store.frameDuration / 2 {
            store.playhead = 0
            requestSeek(to: .zero, precise: true)
        }
        isPlaying = true
        if player.currentItem != nil { player.play() }
    }

    public func pause() {
        isPlaying = false
        player.pause()
        if player.currentItem != nil, !seekInFlight {
            let t = player.currentTime().seconds
            if t.isFinite { store.playhead = max(0, min(t, store.project.duration)) }
        }
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// Moves the playhead (clamped to 0...project.duration) and seeks the player.
    /// `precise` = zero tolerance (use for frame steps and scrub end).
    public func seek(to t: Seconds, precise: Bool = true) {
        let duration = store.project.duration
        let clamped = max(0, min(t.isFinite ? t : 0, duration))
        store.playhead = clamped
        requestSeek(to: playerTime(for: clamped), precise: precise)
    }

    public func stepFrames(_ n: Int) { seek(to: store.playhead + Double(n) * store.frameDuration) }
    public func goToStart() { seek(to: 0) }
    public func goToEnd() { seek(to: store.project.duration) }

    /// Forces an immediate rebuild (e.g. after relinking media).
    public func rebuildNow() {
        scheduleBuild(full: true)
    }

    /// Render scale used for preview: canvases whose long side exceeds `maxPreviewDimension`
    /// (e.g. 4K) render scaled down to keep playback real-time.
    public static func previewScale(for canvas: CanvasSettings) -> Double {
        min(1, maxPreviewDimension / Double(max(1, max(canvas.width, canvas.height))))
    }

    // MARK: - Building

    private func projectChanged() {
        let now = ContinuousClock.now
        editsStreaming = lastChange.duration(to: now) < Self.structuralSettleDelay
        lastChange = now
        scheduleBuild()
    }

    /// True while a burst of edits is still arriving.
    private var isStreamingEdits: Bool {
        editsStreaming && lastChange.duration(to: .now) < Self.structuralSettleDelay
    }

    /// Sleeps until no edit has arrived for `structuralSettleDelay`.
    private func waitForEditsToSettle() async {
        while true {
            let remaining = Self.structuralSettleDelay - lastChange.duration(to: .now)
            guard remaining > .zero else { return }
            try? await Task.sleep(for: remaining)
        }
    }

    private func scheduleBuild(full: Bool = false) {
        needsBuild = true
        if full { forceFullBuild = true }
        guard buildTask == nil else { return }
        buildTask = Task { [weak self] in
            await self?.runBuilds()
        }
    }

    /// Builds until no edits are pending. Edits arriving during a build collapse into one
    /// follow-up build of the latest project.
    private func runBuilds() async {
        while needsBuild {
            needsBuild = false
            let project = store.project
            let previous = forceFullBuild ? nil : built
            forceFullBuild = false
            do {
                let result = try await CompositionBuilder.build(project: project, assets: assets,
                                                                renderScale: Self.previewScale(for: project.canvas),
                                                                reusing: previous)
                let replacesItem = player.currentItem != nil && !(previous.map(result.sharesComposition) ?? false)
                if replacesItem {
                    // Keep the current item on screen while edits stream in; never install a
                    // structure that a newer edit has already replaced.
                    if isStreamingEdits { await waitForEditsToSettle() }
                    if needsBuild { continue }
                }
                install(result)
            } catch {
                lastError = error.localizedDescription
            }
        }
        buildTask = nil
    }

    private func install(_ result: BuiltComposition) {
        let previous = built
        built = result
        lastError = result.missingMedia.isEmpty ? nil : "Missing media: " + result.missingMedia.joined(separator: ", ")

        if let item = player.currentItem, let previous, result.sharesComposition(with: previous) {
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
            if !isPlaying { requestSeek(to: playerTime(for: store.playhead), precise: true) }
            return
        }

        let wasPlaying = isPlaying
        var resume = store.playhead
        if wasPlaying, player.currentItem != nil {
            let t = player.currentTime().seconds
            if t.isFinite { resume = t }
        }
        resume = max(0, min(resume, result.duration))

        let item = AVPlayerItem(asset: result.composition)
        item.videoComposition = result.videoComposition
        item.audioMix = result.audioMix
        observe(item)
        player.replaceCurrentItem(with: item)
        isReady = true

        if store.playhead > store.project.duration { store.playhead = store.project.duration }
        seekInFlight = false
        requestSeek(to: playerTime(for: resume), precise: true)
        if wasPlaying {
            if resume >= result.duration - store.frameDuration / 2 { pause() } else { player.play() }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemSubscriptions.removeAll()
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.didPlayToEnd() }
            }
            .store(in: &itemSubscriptions)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                MainActor.assumeIsolated {
                    guard status == .failed, let self else { return }
                    self.lastError = item?.error?.localizedDescription ?? "Playback failed"
                    self.isPlaying = false
                }
            }
            .store(in: &itemSubscriptions)
    }

    private func didPlayToEnd() {
        isPlaying = false
        store.playhead = store.project.duration
    }

    private func playerTimeAdvanced(_ time: CMTime) {
        guard isPlaying, !seekInFlight, !seekPending else { return }
        let t = time.seconds
        guard t.isFinite else { return }
        store.playhead = max(0, min(t, store.project.duration))
    }

    // MARK: - Seeking

    /// The player time that displays timeline time `t`: the end of the timeline shows the last frame.
    private func playerTime(for t: Seconds) -> CMTime {
        let duration = built?.duration ?? store.project.duration
        let last = max(0, duration - store.frameDuration / 2)
        return CMTime(seconds: min(t, last), preferredTimescale: 6000)
    }

    private func requestSeek(to time: CMTime, precise: Bool) {
        seekTarget = time
        seekPrecise = precise
        seekPending = true
        if !seekInFlight { startPendingSeek() }
    }

    private func startPendingSeek() {
        guard seekPending, player.currentItem != nil else {
            seekInFlight = false
            return
        }
        seekPending = false
        seekInFlight = true
        let tolerance = seekPrecise ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: seekTarget, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in self?.startPendingSeek() }
        }
    }
}
