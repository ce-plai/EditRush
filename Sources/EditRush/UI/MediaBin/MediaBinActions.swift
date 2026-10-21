import Foundation
import EditRushCore

/// Adds media-bin items to the timeline the way Rush builds a sequence.
@MainActor
enum MediaBinActions {
    /// Appends `items` one after another as a single undo step. Visual media goes on the lowest
    /// unlocked, visible video track and audio on the lowest such audio track (a track is created
    /// only when there is none), at the first start at or after the playhead where the whole clip
    /// fits. The playhead then moves to the end of the last added clip, so repeated adds follow
    /// each other. Selects the added clips.
    static func append(_ items: [MediaItem], store: EditorStore, playback: PlaybackController) {
        guard !items.isEmpty else { return }
        let key = "bin-add-\(UUID())"
        var added: [UUID] = []
        var time = store.playhead
        for media in items {
            let kind: TrackKind = media.kind == .audio ? .audio : .video
            let track = store.project.tracks.first { $0.kind == kind && $0.allowsAutomaticPlacement }
            let start = track.map { firstFreeStart(on: $0, duration: clipDuration(of: media, in: store.project), from: time) } ?? time
            guard let id = store.addClip(mediaID: media.id, trackID: track?.id, at: start, coalesce: key),
                  let clip = store.clip(id) else { continue }
            added.append(id)
            time = clip.end
        }
        store.endCoalescing()
        guard !added.isEmpty else { return }
        store.selection = Set(added)
        playback.seek(to: time)
        NotificationCenter.default.post(name: ShellActions.revealPlayheadNotification, object: nil)
    }

    /// Timeline length `EditorStore.addClip` gives a new clip of `media` (images: 5 s).
    static func clipDuration(of media: MediaItem, in project: Project) -> Seconds {
        let canvas = project.canvas
        guard media.kind != .image, media.duration > 0 else { return 5 }
        let fps = max(1, canvas.frameRate)
        return max(canvas.frameDuration, (media.duration * fps + 1e-6).rounded(.down) / fps)
    }

    /// The earliest start at or after `time` where `[start, start + duration)`
    /// overlaps no clip on `track`.
    static func firstFreeStart(on track: Track, duration: Seconds, from time: Seconds) -> Seconds {
        let eps = 1e-6
        var start = max(0, time)
        for clip in track.clips.sorted(by: { $0.start < $1.start }) where clip.end > start + eps {
            if clip.start >= start + duration - eps { break }
            start = clip.end
        }
        return start
    }
}
