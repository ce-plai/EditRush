import AVFoundation
import Combine
import Observation

/// Owns the AVPlayer used by the preview and keeps it in sync with the store (STUB — engine module).
///
/// * Subscribes to `store.changes`; rebuilds the composition (coalescing bursts of edits) and
///   swaps it into the player while preserving the current time and play state. Property-only
///   edits should be cheap (reuse the AVPlayerItem; swap videoComposition/audioMix; re-seek when
///   paused so the visible frame refreshes).
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
    @ObservationIgnored public let store: EditorStore

    public init(store: EditorStore) {
        self.store = store
    }

    public func play() {}
    public func pause() {}
    public func togglePlay() { isPlaying ? pause() : play() }
    /// Moves the playhead (clamped to 0...project.duration) and seeks the player.
    /// `precise` = zero tolerance (use for frame steps and scrub end).
    public func seek(to t: Seconds, precise: Bool = true) { store.playhead = max(0, t) }
    public func stepFrames(_ n: Int) { seek(to: store.playhead + Double(n) * store.frameDuration) }
    public func goToStart() { seek(to: 0) }
    public func goToEnd() { seek(to: store.project.duration) }
    /// Forces an immediate rebuild (e.g. after relinking media).
    public func rebuildNow() {}
}
