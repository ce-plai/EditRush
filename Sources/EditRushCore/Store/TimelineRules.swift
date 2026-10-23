import Foundation

// MARK: - Track placement queries (public: the timeline UI may use them for drag previews)

extension Track {
    /// True when `[start, start + duration)` overlaps no clip on this track other than `excluding`.
    public func isFree(start: Seconds, duration: Seconds, excluding: Set<UUID> = []) -> Bool {
        let end = start + duration
        return !clips.contains { c in
            !excluding.contains(c.id) && c.start < end - StoreTimeline.epsilon && start < c.end - StoreTimeline.epsilon
        }
    }

    /// The start ≥ 0 closest to `desired` where a clip of `duration` fits without overlapping
    /// clips other than `excluding`. Ties prefer the earlier start; the space after the last clip always fits.
    public func nearestFreeStart(duration: Seconds, near desired: Seconds, excluding: Set<UUID> = []) -> Seconds {
        let desired = max(0, desired)
        let eps = StoreTimeline.epsilon
        var best: Seconds?
        func consider(_ lo: Seconds, _ hi: Seconds) {
            guard hi >= lo - eps else { return }
            let candidate = min(max(desired, lo), max(lo, hi))
            if best.map({ abs(candidate - desired) < abs($0 - desired) - eps }) ?? true { best = candidate }
        }
        var gapStart: Seconds = 0
        for c in clips.sorted(by: { $0.start < $1.start }) where !excluding.contains(c.id) {
            consider(gapStart, c.start - duration)
            gapStart = max(gapStart, c.end)
        }
        consider(gapStart, .infinity)
        return best ?? gapStart
    }

    /// True when automatic placement (no explicit target track) may put new clips here:
    /// the track is unlocked and visible.
    public var allowsAutomaticPlacement: Bool { !isLocked && !isHidden }
}

// MARK: - Store-internal editing rules

/// Pure helpers shared by the store's edit operations. They keep the track invariants:
/// frame-quantized times, sorted non-overlapping clips, ≥ 1 frame durations, valid property ranges.
enum StoreTimeline {
    static let epsilon: Seconds = 1e-6

    /// Rounds `t` down to a frame boundary (tolerating floating-point noise).
    static func floorFrame(_ t: Seconds, _ canvas: CanvasSettings) -> Seconds {
        let fps = max(1, canvas.frameRate)
        return (t * fps + 1e-6).rounded(.down) / fps
    }

    /// Rounds `t` up to a frame boundary (tolerating floating-point noise).
    static func ceilFrame(_ t: Seconds, _ canvas: CanvasSettings) -> Seconds {
        let fps = max(1, canvas.frameRate)
        return (t * fps - 1e-6).rounded(.up) / fps
    }

    /// True for clips that play a time range of their media (video and audio), i.e. whose
    /// `sourceIn` is meaningful. Images and text are unbounded.
    static func playsSourceRange(_ clip: Clip, in p: Project) -> Bool {
        guard clip.mediaID != nil else { return false }
        return p.media(clip.mediaID)?.kind != .image
    }

    /// Source duration bounding a clip's media range, or nil when unbounded (images, text, unknown length).
    static func sourceDuration(of clip: Clip, in p: Project) -> Seconds? {
        guard let m = p.media(clip.mediaID), m.kind != .image, m.duration > 0 else { return nil }
        return m.duration
    }

    static func clamp(_ v: Double, _ range: ClosedRange<Double>, default d: Double) -> Double {
        guard v.isFinite else { return d }
        return min(range.upperBound, max(range.lowerBound, v))
    }

    /// Clamps every clip property to its valid range (timing quantized, ≥ 1 frame; fades fit the
    /// duration, scaled down proportionally when needed).
    static func normalize(_ c: inout Clip, in p: Project) {
        let canvas = p.canvas
        let frame = canvas.frameDuration
        c.start = c.start.isFinite ? max(0, canvas.quantize(c.start)) : 0
        c.duration = c.duration.isFinite ? max(frame, canvas.quantize(c.duration)) : frame
        if playsSourceRange(c, in: p) {
            c.sourceIn = c.sourceIn.isFinite ? max(0, c.sourceIn) : 0
            c.speed = clamp(c.speed, Clip.speedRange, default: 1)
            if let total = sourceDuration(of: c, in: p) {
                c.sourceIn = min(c.sourceIn, max(0, total - frame * c.speed))
                c.duration = max(frame, min(c.duration, floorFrame((total - c.sourceIn) / c.speed, canvas)))
            }
        } else {
            c.sourceIn = 0
            c.speed = 1
        }

        c.transform.opacity = clamp(c.transform.opacity, 0...1, default: 1)
        c.transform.scale = clamp(c.transform.scale, 0.02...20, default: 1)
        c.transform.offsetX = clamp(c.transform.offsetX, -100...100, default: 0)
        c.transform.offsetY = clamp(c.transform.offsetY, -100...100, default: 0)
        c.transform.rotation = clamp(c.transform.rotation, -36_000...36_000, default: 0)
        c.volume = clamp(c.volume, 0...2, default: 1)
        c.filterIntensity = clamp(c.filterIntensity, 0...1, default: 1)

        c.color.exposure = clamp(c.color.exposure, -2...2, default: 0)
        c.color.brightness = clamp(c.color.brightness, -1...1, default: 0)
        c.color.contrast = clamp(c.color.contrast, 0.25...2, default: 1)
        c.color.saturation = clamp(c.color.saturation, 0...2, default: 1)
        c.color.temperature = clamp(c.color.temperature, -1...1, default: 0)
        c.color.vignette = clamp(c.color.vignette, 0...1, default: 0)

        if var t = c.text {
            t.fontSize = clamp(t.fontSize, 0.01...0.6, default: 0.1)
            t.outlineWidth = clamp(t.outlineWidth, 0...1, default: 0)
            c.text = t
        }

        clampFades(&c)
    }

    /// Fades ≥ 0 with fadeIn + fadeOut ≤ duration (both scaled down proportionally when too long).
    static func clampFades(_ c: inout Clip) {
        var fin = c.fadeIn.isFinite ? max(0, c.fadeIn) : 0
        var fout = c.fadeOut.isFinite ? max(0, c.fadeOut) : 0
        let total = fin + fout
        if total > c.duration {
            let k = c.duration / total
            fin *= k; fout *= k
        }
        c.fadeIn = fin; c.fadeOut = fout
    }

    static func sortClips(_ p: inout Project, track ti: Int) {
        p.tracks[ti].clips.sort { $0.start < $1.start }
    }

    /// Inserts a new track: video tracks go above the existing video tracks (right after the last
    /// video track in the array), audio tracks are appended. Returns the new track's index.
    @discardableResult
    static func insertTrack(_ kind: TrackKind, in p: inout Project) -> Int {
        let track = Track(kind: kind)
        switch kind {
        case .video:
            let index = (p.tracks.lastIndex { $0.kind == .video }).map { $0 + 1 } ?? 0
            p.tracks.insert(track, at: index)
            return index
        case .audio:
            p.tracks.append(track)
            return p.tracks.count - 1
        }
    }

    /// Picks the track for a new clip of `kind` occupying `[clip.start, clip.end)`:
    /// the preferred track when it is compatible and unlocked (the clip moves to its nearest free
    /// start there, even when the track is hidden), else the first visible, unlocked compatible
    /// track that is free (bottom-up, or top-down with `topmostFirst`), else a new track.
    /// Inserts the clip and returns the track index.
    @discardableResult
    static func place(_ clip: inout Clip, kind: TrackKind, preferredTrack: UUID?, topmostFirst: Bool,
                      in p: inout Project) -> Int {
        let ti: Int
        if let preferredTrack, let pi = p.trackIndex(preferredTrack),
           p.tracks[pi].kind == kind, !p.tracks[pi].isLocked {
            clip.start = p.canvas.quantize(p.tracks[pi].nearestFreeStart(duration: clip.duration, near: clip.start))
            ti = pi
        } else {
            var candidates = p.tracks.indices.filter { p.tracks[$0].kind == kind && p.tracks[$0].allowsAutomaticPlacement }
            if topmostFirst { candidates.reverse() }
            let start = clip.start, duration = clip.duration
            ti = candidates.first { p.tracks[$0].isFree(start: start, duration: duration) } ?? insertTrack(kind, in: &p)
        }
        p.tracks[ti].clips.append(clip)
        sortClips(&p, track: ti)
        return ti
    }

    /// A closed range of time shifts.
    struct Shift { var lo: Seconds; var hi: Seconds }

    /// Sorted, disjoint ranges of shifts `d` for which every clip of `group`, moved to
    /// `[start + d, end + d)` on its track, stays at or after 0 and overlaps no clip outside
    /// `excluding`. Shifts never make group clips collide with each other (they all move together).
    static func validShifts(_ group: [(track: Int, clip: Clip)], excluding: Set<UUID>, in p: Project) -> [Shift] {
        var gapsByTrack: [Int: [Shift]] = [:]
        var result = [Shift(lo: -.infinity, hi: .infinity)]
        for (ti, c) in group {
            let gaps: [Shift]
            if let cached = gapsByTrack[ti] {
                gaps = cached
            } else {
                var g: [Shift] = []
                var gapStart: Seconds = 0
                for o in p.tracks[ti].clips where !excluding.contains(o.id) {
                    if o.start > gapStart { g.append(Shift(lo: gapStart, hi: o.start)) }
                    gapStart = max(gapStart, o.end)
                }
                g.append(Shift(lo: gapStart, hi: .infinity))
                gapsByTrack[ti] = g
                gaps = g
            }
            let fits = gaps.compactMap { g -> Shift? in
                let lo = g.lo - c.start, hi = g.hi - c.end
                return hi >= lo - epsilon ? Shift(lo: lo, hi: max(lo, hi)) : nil
            }
            result = intersect(result, fits)
            if result.isEmpty { break }
        }
        return result
    }

    /// Intersection of two sorted, disjoint shift range lists.
    static func intersect(_ a: [Shift], _ b: [Shift]) -> [Shift] {
        var r: [Shift] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let lo = max(a[i].lo, b[j].lo), hi = min(a[i].hi, b[j].hi)
            if hi >= lo - epsilon { r.append(Shift(lo: lo, hi: max(lo, hi))) }
            if a[i].hi < b[j].hi { i += 1 } else { j += 1 }
        }
        return r
    }

    /// The value in `ranges` closest to `d` (ties prefer the smaller value), or nil when empty.
    static func nearest(_ d: Seconds, in ranges: [Shift]) -> Seconds? {
        var best: Seconds?
        for r in ranges {
            let candidate = min(max(d, r.lo), r.hi)
            if best.map({ abs(candidate - d) < abs($0 - d) - epsilon }) ?? true { best = candidate }
        }
        return best
    }

    /// True when `t` is at least one frame inside the clip on both sides.
    static func canSplit(_ c: Clip, at t: Seconds, frame: Seconds) -> Bool {
        t - c.start >= frame - epsilon && c.end - t >= frame - epsilon
    }

    /// Splits clip `id` at the frame-quantized time `t`; returns the right part's id.
    static func split(_ id: UUID, at t: Seconds, in p: inout Project) -> UUID? {
        guard let l = p.locate(clip: id), !p.tracks[l.track].isLocked else { return nil }
        let canvas = p.canvas
        let t = canvas.quantize(t)
        let original = p.tracks[l.track].clips[l.clip]
        guard canSplit(original, at: t, frame: canvas.frameDuration) else { return nil }

        var left = original
        left.duration = canvas.quantize(t - original.start)
        left.fadeOut = 0
        clampFades(&left)

        var right = original
        right.id = UUID()
        right.start = t
        right.duration = canvas.quantize(original.end - t)
        if playsSourceRange(original, in: p) { right.sourceIn = original.sourceIn + left.duration * original.speed }
        right.fadeIn = 0
        clampFades(&right)

        p.tracks[l.track].clips[l.clip] = left
        p.tracks[l.track].clips.insert(right, at: l.clip + 1)
        return right.id
    }

    /// True when `b` continues `a` seamlessly: same media and speed with a continuous source range
    /// (images and identical text styles are always continuous).
    static func continues(_ a: Clip, _ b: Clip, in p: Project, frame: Seconds) -> Bool {
        guard abs(a.end - b.start) < frame / 2 else { return false }
        if let ta = a.text { return a.mediaID == nil && b.mediaID == nil && b.text == ta }
        guard b.text == nil, let mid = a.mediaID, mid == b.mediaID else { return false }
        if !playsSourceRange(a, in: p) { return true }
        return abs(a.speed - b.speed) < 1e-9 && abs(a.sourceOut - b.sourceIn) < frame * a.speed / 2
    }
}
