import Foundation

extension EditorStore {
    // MARK: - Tracks

    /// Adds an empty track (video tracks go above the existing video tracks, audio tracks at the bottom).
    @discardableResult
    public func addTrack(_ kind: TrackKind) -> UUID {
        var id = UUID()
        mutate(kind == .video ? "Add Video Track" : "Add Audio Track") { p in
            let ti = StoreTimeline.insertTrack(kind, in: &p)
            id = p.tracks[ti].id
        }
        return id
    }

    /// Removes a track and its clips. The last video track and locked tracks cannot be removed.
    public func removeTrack(_ id: UUID) {
        guard let ti = project.trackIndex(id) else { return }
        let track = project.tracks[ti]
        if track.isLocked {
            statusMessage = "Unlock \(project.displayName(of: id)) to remove it."
            return
        }
        guard track.kind == .audio || project.videoTracks.count > 1 else {
            statusMessage = "A project needs at least one video track."
            return
        }
        mutate("Remove Track") { p in p.tracks.remove(at: ti) }
    }

    public func setTrack(_ id: UUID, muted: Bool? = nil, hidden: Bool? = nil, locked: Bool? = nil) {
        let name: String
        if let locked { name = locked ? "Lock Track" : "Unlock Track" }
        else if let hidden { name = hidden ? "Hide Track" : "Show Track" }
        else if let muted { name = muted ? "Mute Track" : "Unmute Track" }
        else { return }
        mutate(name) { p in
            guard let ti = p.trackIndex(id) else { return }
            if let muted { p.tracks[ti].isMuted = muted }
            if let hidden { p.tracks[ti].isHidden = hidden }
            if let locked { p.tracks[ti].isLocked = locked }
        }
    }

    // MARK: - Snapping

    /// Clip edges (all tracks, excluding `excluding` clip ids), the playhead, 0 and the end of the
    /// remaining clips. Sorted, without duplicates.
    public func snapTargets(excluding: Set<UUID> = []) -> [Seconds] {
        var targets: Set<Seconds> = [0, playhead]
        var end: Seconds = 0
        for track in project.tracks {
            for c in track.clips where !excluding.contains(c.id) {
                targets.insert(c.start)
                targets.insert(c.end)
                end = max(end, c.end)
            }
        }
        targets.insert(end)
        return targets.sorted()
    }

    /// Snaps `t` to the nearest target within `thresholdSeconds` if snapping is enabled.
    public func snap(_ t: Seconds, excluding: Set<UUID> = [], thresholdSeconds: Seconds) -> Seconds {
        guard snappingEnabled else { return t }
        var best = t, bestDistance = thresholdSeconds
        for target in snapTargets(excluding: excluding) {
            let d = abs(target - t)
            if d <= bestDistance { best = target; bestDistance = d }
        }
        return best
    }

    // MARK: - Selection & clipboard

    /// Selects every clip on unlocked tracks.
    public func selectAll() {
        selection = Set(project.tracks.filter { !$0.isLocked }.flatMap { $0.clips.map(\.id) })
    }

    /// Copies the selected clips (with their track positions) to an internal clipboard.
    public func copySelection() {
        let items = clipboardItems(for: selection, unlockedOnly: false)
        if !items.isEmpty { clipboard = items }
    }

    /// Copy, then delete (non-ripple). Clips on locked tracks are neither copied nor deleted.
    public func cutSelection() {
        let items = clipboardItems(for: selection, unlockedOnly: true)
        guard !items.isEmpty else { return }
        clipboard = items
        let ids = Set(items.map(\.clip.id))
        mutate("Cut") { p in
            for ti in p.tracks.indices where !p.tracks[ti].isLocked { p.tracks[ti].clips.removeAll { ids.contains($0.id) } }
        }
    }

    /// True when the internal clipboard holds clips.
    public var canPaste: Bool { !clipboard.isEmpty }

    /// Pastes clipboard clips at the playhead, keeping their relative timing and tracks (falls back
    /// to compatible tracks / new tracks when needed; overlaps resolve to the nearest free start).
    /// Selects the pasted clips.
    ///
    /// Clips copied from one track stay together: they go to the same-numbered track when they fit
    /// there at their pasted times, else the first other unlocked compatible track where they fit,
    /// else a new track. Clips whose media was removed since copying are skipped.
    public func pasteAtPlayhead() {
        guard let base = clipboard.map(\.clip.start).min() else { return }
        let origin = project.canvas.quantize(playhead)
        let groups = Dictionary(grouping: clipboard) { EditorClipboardGroupKey(kind: $0.trackKind, ordinal: $0.trackOrdinal) }
            .sorted { ($0.key.kind == .video ? 0 : 1, $0.key.ordinal) < ($1.key.kind == .video ? 0 : 1, $1.key.ordinal) }
        var pasted: [UUID] = []
        mutate("Paste") { p in
            for (key, items) in groups {
                let clips: [Clip] = items.compactMap { item in
                    guard item.clip.mediaID == nil || p.media(item.clip.mediaID) != nil else { return nil }
                    var c = item.clip
                    c.id = UUID()
                    c.start = p.canvas.quantize(origin + (c.start - base))
                    return c
                }
                guard !clips.isEmpty else { continue }
                let kindTracks = p.tracks.indices.filter { p.tracks[$0].kind == key.kind }
                let preferred = kindTracks.indices.contains(key.ordinal) ? kindTracks[key.ordinal] : nil
                let candidates = ([preferred].compactMap { $0 } + kindTracks.filter { $0 != preferred })
                    .filter { !p.tracks[$0].isLocked }
                let ti = candidates.first { ti in
                    clips.allSatisfy { p.tracks[ti].isFree(start: $0.start, duration: $0.duration) }
                } ?? StoreTimeline.insertTrack(key.kind, in: &p)
                for c in clips {
                    var c = c
                    c.start = p.canvas.quantize(p.tracks[ti].nearestFreeStart(duration: c.duration, near: c.start))
                    p.tracks[ti].clips.append(c)
                    StoreTimeline.sortClips(&p, track: ti)
                    pasted.append(c.id)
                }
            }
        }
        if !pasted.isEmpty { selection = Set(pasted) }
    }

    /// Moves the selected clips by `frames` (negative = left), clamped at 0 and by neighbours.
    /// All selected clips on unlocked tracks move by the same amount; repeated nudges coalesce into one undo step.
    public func nudgeSelection(frames: Int) {
        guard frames != 0, !selection.isEmpty else { return }
        let frame = frameDuration
        var allowed = frames
        var moving = false
        for track in project.tracks where !track.isLocked {
            let clips = track.clips
            for (i, c) in clips.enumerated() where selection.contains(c.id) {
                moving = true
                if frames < 0 {
                    let bound = clips[..<i].last { !selection.contains($0.id) }?.end ?? 0
                    allowed = max(allowed, -Int(((c.start - bound) / frame + 1e-6).rounded(.down)))
                } else if let next = clips[(i + 1)...].first(where: { !selection.contains($0.id) }) {
                    allowed = min(allowed, Int(((next.start - c.end) / frame + 1e-6).rounded(.down)))
                }
            }
        }
        guard moving, allowed != 0 else { return }
        let delta = Double(allowed) * frame
        let targets = selection
        mutate("Nudge", coalesce: "nudge-selection") { p in
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                for ci in p.tracks[ti].clips.indices where targets.contains(p.tracks[ti].clips[ci].id) {
                    p.tracks[ti].clips[ci].start = max(0, p.canvas.quantize(p.tracks[ti].clips[ci].start + delta))
                }
                StoreTimeline.sortClips(&p, track: ti)
            }
        }
    }

    private func clipboardItems(for ids: Set<UUID>, unlockedOnly: Bool) -> [EditorClipboardItem] {
        var items: [EditorClipboardItem] = []
        var ordinals: [TrackKind: Int] = [:]
        for track in project.tracks {
            let ordinal = ordinals[track.kind, default: 0]
            ordinals[track.kind] = ordinal + 1
            guard !(unlockedOnly && track.isLocked) else { continue }
            for c in track.clips where ids.contains(c.id) {
                items.append(EditorClipboardItem(clip: c, trackKind: track.kind, trackOrdinal: ordinal))
            }
        }
        return items
    }
}

private struct EditorClipboardGroupKey: Hashable {
    var kind: TrackKind
    var ordinal: Int
}
