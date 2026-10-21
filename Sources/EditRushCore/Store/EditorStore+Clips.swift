import Foundation

extension EditorStore {
    // MARK: - Adding clips

    /// Places a clip for `mediaID` on the timeline.
    /// - trackID: target track (must accept the media kind); nil = pick the lowest compatible
    ///   track that is free at `time` for the clip's length, creating a new track if none is.
    ///   An incompatible or locked `trackID` falls back to the automatic choice.
    /// - time: timeline start; nil = playhead. Overlaps are resolved to the nearest free start.
    /// Video/audio clips default to the full media duration; images default to 5 s.
    /// Selects the new clip and returns its id.
    @discardableResult
    public func addClip(mediaID: UUID, trackID: UUID? = nil, at time: Seconds? = nil) -> UUID? {
        guard let m = media(mediaID) else { return nil }
        let canvas = project.canvas
        let duration = m.kind == .image || m.duration <= 0
            ? 5
            : max(canvas.frameDuration, StoreTimeline.floorFrame(m.duration, canvas))
        var clip = Clip(mediaID: mediaID, start: canvas.quantize(max(0, time ?? playhead)), duration: duration)
        let kind: TrackKind = m.kind == .audio ? .audio : .video
        mutate("Add Clip") { p in
            StoreTimeline.place(&clip, kind: kind, preferredTrack: trackID, topmostFirst: false, in: &p)
        }
        selection = [clip.id]
        return clip.id
    }

    /// Adds a 5 s text clip (default `TextStyle`) at `time` (nil = playhead) on `trackID`
    /// (nil = topmost video track that is free there, creating a new video track if needed).
    @discardableResult
    public func addTextClip(at time: Seconds? = nil, trackID: UUID? = nil, style: TextStyle = TextStyle()) -> UUID? {
        let canvas = project.canvas
        var clip = Clip(mediaID: nil, start: canvas.quantize(max(0, time ?? playhead)), duration: 5, text: style)
        mutate("Add Text") { p in
            StoreTimeline.normalize(&clip, in: p)
            StoreTimeline.place(&clip, kind: .video, preferredTrack: trackID, topmostFirst: true, in: &p)
        }
        selection = [clip.id]
        return clip.id
    }

    // MARK: - Split & join

    /// Splits at the playhead: the selected clips under the playhead, or — if no selected clip
    /// is under the playhead — every clip on unlocked tracks under the playhead.
    /// Selects the right-hand parts.
    public func splitAtPlayhead() {
        let t = project.canvas.quantize(playhead)
        let frame = frameDuration
        var selected: [UUID] = [], all: [UUID] = []
        for track in project.tracks where !track.isLocked {
            for c in track.clips where StoreTimeline.canSplit(c, at: t, frame: frame) {
                all.append(c.id)
                if selection.contains(c.id) { selected.append(c.id) }
            }
        }
        let targets = selected.isEmpty ? all : selected
        guard !targets.isEmpty else { return }
        var rights: [UUID] = []
        mutate("Split") { p in
            rights = targets.compactMap { StoreTimeline.split($0, at: t, in: &p) }
        }
        if !rights.isEmpty { selection = Set(rights) }
    }

    /// Splits one clip at timeline time `t` (frame quantized). No-op within one frame of an edge.
    /// The right part gets a new id; fadeOut stays on the right part, fadeIn on the left part.
    /// Selects the right part.
    @discardableResult
    public func split(clipID: UUID, at t: Seconds) -> UUID? {
        var right: UUID?
        mutate("Split") { p in right = StoreTimeline.split(clipID, at: t, in: &p) }
        if let right { selection = [right] }
        return right
    }

    /// True if the selection is ≥2 clips on one unlocked track that are adjacent with no gap and
    /// can merge (same media with continuous source; see `joinSelection`).
    public var canJoinSelection: Bool { joinCandidates() != nil }

    /// Joins the selected adjacent clips. Clips from the same media with continuous source
    /// (a.sourceOut == b.sourceIn) merge into one clip. Otherwise (different media / non-
    /// continuous) the selection cannot be merged and this is a no-op.
    /// The merged clip keeps the first clip's id and properties and the last clip's fadeOut.
    public func joinSelection() {
        guard let (ti, clips) = joinCandidates(), let first = clips.first, let last = clips.last else { return }
        mutate("Join Clips") { p in
            var merged = first
            merged.duration = p.canvas.quantize(last.end - first.start)
            merged.fadeOut = last.fadeOut
            StoreTimeline.clampFades(&merged)
            let removed = Set(clips.dropFirst().map(\.id))
            p.tracks[ti].clips.removeAll { removed.contains($0.id) }
            if let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == first.id }) { p.tracks[ti].clips[ci] = merged }
        }
        selection = [first.id]
    }

    /// The selected clips (track index, clips in timeline order) when they can be joined.
    private func joinCandidates() -> (Int, [Clip])? {
        guard selection.count >= 2 else { return nil }
        let locations = selection.compactMap { project.locate(clip: $0) }
        guard locations.count == selection.count, let ti = locations.first?.track,
              locations.allSatisfy({ $0.track == ti }), !project.tracks[ti].isLocked else { return nil }
        let clips = locations.map(\.clip).sorted().map { project.tracks[ti].clips[$0] }
        let frame = frameDuration
        for (a, b) in zip(clips, clips.dropFirst()) where !StoreTimeline.continues(a, b, in: project, frame: frame) {
            return nil
        }
        return (ti, clips)
    }

    // MARK: - Delete, gaps, duplicate

    /// Removes the gap before each selected clip (or, with no selection, all gaps on all tracks),
    /// shifting later clips on the same track left. Locked tracks are untouched.
    public func closeGaps() {
        let targets = selection
        mutate("Close Gaps") { p in
            let canvas = p.canvas
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                var clips = p.tracks[ti].clips
                var previousEnd: Seconds = 0
                for i in clips.indices {
                    let gap = clips[i].start - previousEnd
                    if gap > StoreTimeline.epsilon, targets.isEmpty || targets.contains(clips[i].id) {
                        for j in i..<clips.count { clips[j].start = max(0, canvas.quantize(clips[j].start - gap)) }
                    }
                    previousEnd = clips[i].end
                }
                p.tracks[ti].clips = clips
            }
        }
    }

    /// Deletes selected clips. `ripple` shifts later clips on the same track left by the deleted length.
    /// Clips on locked tracks are kept.
    public func deleteSelection(ripple: Bool) {
        let targets = selection
        guard !targets.isEmpty else { return }
        mutate(ripple ? "Ripple Delete" : "Delete") { p in
            let canvas = p.canvas
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                let doomed = p.tracks[ti].clips.filter { targets.contains($0.id) }.sorted { $0.start > $1.start }
                for d in doomed {
                    p.tracks[ti].clips.removeAll { $0.id == d.id }
                    guard ripple else { continue }
                    for j in p.tracks[ti].clips.indices where p.tracks[ti].clips[j].start >= d.end - StoreTimeline.epsilon {
                        p.tracks[ti].clips[j].start = max(0, canvas.quantize(p.tracks[ti].clips[j].start - d.duration))
                    }
                }
            }
        }
    }

    /// Duplicates selected clips, placing each copy right after the original on its track
    /// (nearest free spot). Selects the copies.
    public func duplicateSelection() {
        let originals = selectedClips
        guard !originals.isEmpty else { return }
        var copies: [UUID] = []
        mutate("Duplicate") { p in
            for original in originals {
                guard let l = p.locate(clip: original.id), !p.tracks[l.track].isLocked else { continue }
                var copy = original
                copy.id = UUID()
                copy.start = p.canvas.quantize(p.tracks[l.track].nearestFreeStart(duration: copy.duration, near: original.end))
                p.tracks[l.track].clips.append(copy)
                StoreTimeline.sortClips(&p, track: l.track)
                copies.append(copy.id)
            }
        }
        if !copies.isEmpty { selection = Set(copies) }
    }

    // MARK: - Move & trim

    /// Moves a clip to `trackID` (must accept the clip's content) at `start`.
    /// Overlaps resolve to the nearest free start on the target track. Returns false if refused
    /// (locked track / incompatible). Use `coalesce` for live drags.
    @discardableResult
    public func moveClip(_ id: UUID, toTrack trackID: UUID, start: Seconds, coalesce: String? = nil) -> Bool {
        guard let l = project.locate(clip: id), let target = project.trackIndex(trackID) else { return false }
        let source = project.tracks[l.track], destination = project.tracks[target]
        guard !source.isLocked, !destination.isLocked, source.kind == destination.kind else { return false }
        mutate("Move Clip", coalesce: coalesce) { p in
            var clip = p.tracks[l.track].clips.remove(at: l.clip)
            let desired = p.canvas.quantize(max(0, start))
            clip.start = p.canvas.quantize(p.tracks[target].nearestFreeStart(duration: clip.duration, near: desired, excluding: [id]))
            p.tracks[target].clips.append(clip)
            StoreTimeline.sortClips(&p, track: target)
        }
        return true
    }

    /// Trims a clip edge to timeline time `t`, clamped by neighbours, media bounds (video/audio
    /// cannot extend past the source; images/text are unbounded), and a 1-frame minimum.
    /// Leading-edge trims move `start` and `sourceIn` together.
    public func trimClip(_ id: UUID, edge: TrimEdge, to t: Seconds, coalesce: String? = nil) {
        mutate("Trim Clip", coalesce: coalesce) { p in
            guard let l = p.locate(clip: id), !p.tracks[l.track].isLocked else { return }
            let canvas = p.canvas, frame = canvas.frameDuration
            let clips = p.tracks[l.track].clips
            var c = clips[l.clip]
            let t = canvas.quantize(t)
            let total = StoreTimeline.sourceDuration(of: c, in: p)
            switch edge {
            case .leading:
                var lower = l.clip > 0 ? clips[l.clip - 1].end : 0
                if StoreTimeline.playsSourceRange(c, in: p) {
                    lower = max(lower, StoreTimeline.ceilFrame(c.start - c.sourceIn, canvas))
                }
                let upper = canvas.quantize(c.end - frame)
                let newStart = min(max(t, lower), upper)
                let delta = newStart - c.start
                if StoreTimeline.playsSourceRange(c, in: p) { c.sourceIn = max(0, c.sourceIn + delta) }
                c.duration = canvas.quantize(c.end - newStart)
                c.start = newStart
            case .trailing:
                var upper = l.clip + 1 < clips.count ? clips[l.clip + 1].start : .infinity
                if let total { upper = min(upper, StoreTimeline.floorFrame(c.start + total - c.sourceIn, canvas)) }
                let newEnd = max(min(t, upper), c.start + frame)
                c.duration = canvas.quantize(newEnd - c.start)
            }
            StoreTimeline.clampFades(&c)
            p.tracks[l.track].clips[l.clip] = c
        }
    }

    // MARK: - Properties

    /// Edits arbitrary clip properties (transform, color, text, fades, volume...).
    /// Values are clamped to valid ranges (fadeIn + fadeOut ≤ duration, opacity 0...1, etc).
    /// Timing changes are frame-quantized and kept overlap-free. Clips on locked tracks are not edited.
    public func updateClip(_ id: UUID, _ actionName: String, coalesce: String? = nil, _ body: (inout Clip) -> Void) {
        mutate(actionName, coalesce: coalesce) { p in
            guard let l = p.locate(clip: id), !p.tracks[l.track].isLocked else { return }
            let original = p.tracks[l.track].clips[l.clip]
            var c = original
            body(&c)
            c.id = original.id
            StoreTimeline.normalize(&c, in: p)
            if c.start != original.start || c.duration != original.duration,
               !p.tracks[l.track].isFree(start: c.start, duration: c.duration, excluding: [id]) {
                c.start = p.canvas.quantize(p.tracks[l.track].nearestFreeStart(duration: c.duration, near: c.start, excluding: [id]))
            }
            p.tracks[l.track].clips[l.clip] = c
            StoreTimeline.sortClips(&p, track: l.track)
        }
    }

    /// Moves a video clip's embedded audio onto an audio track as a separate audio clip
    /// (same media, start, sourceIn, duration, volume, fades) and sets `audioMuted` on the video clip.
    /// Uses the lowest unlocked audio track that is free for the clip's range, else a new audio track.
    public func detachAudio(_ clipID: UUID) {
        mutate("Detach Audio") { p in
            guard let l = p.locate(clip: clipID), p.tracks[l.track].kind == .video, !p.tracks[l.track].isLocked else { return }
            let video = p.tracks[l.track].clips[l.clip]
            guard let m = p.media(video.mediaID), m.kind == .video, m.hasAudio, !video.audioMuted else { return }
            var audio = Clip(mediaID: m.id, start: video.start, duration: video.duration, sourceIn: video.sourceIn)
            audio.volume = video.volume
            audio.fadeIn = video.fadeIn
            audio.fadeOut = video.fadeOut
            audio.label = video.label
            p.tracks[l.track].clips[l.clip].audioMuted = true
            StoreTimeline.place(&audio, kind: .audio, preferredTrack: nil, topmostFirst: false, in: &p)
        }
    }

    /// Applies a fade-in and/or fade-out (seconds) to the selected clips; nil leaves that side unchanged.
    /// Fades are clamped so fadeIn + fadeOut ≤ duration.
    public func setFades(in fadeIn: Seconds?, out fadeOut: Seconds?) {
        let targets = selection
        guard !targets.isEmpty, fadeIn != nil || fadeOut != nil else { return }
        mutate("Set Fades") { p in
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                for ci in p.tracks[ti].clips.indices where targets.contains(p.tracks[ti].clips[ci].id) {
                    var c = p.tracks[ti].clips[ci]
                    if let fadeIn { c.fadeIn = fadeIn }
                    if let fadeOut { c.fadeOut = fadeOut }
                    StoreTimeline.clampFades(&c)
                    p.tracks[ti].clips[ci] = c
                }
            }
        }
    }
}
