import Foundation

/// Three-way merge of two edits of the same project, used when the project file changes on disk
/// (another app or an agent wrote it) while the editor has edits not yet saved to it.
///
/// Works per entity: the canvas, each media item, each track's settings and order, and each clip
/// (by id, including which track it is on). Whichever side changed an entity wins; when both changed
/// it differently, `ours` wins and it counts as a conflict. If the combined timeline breaks the
/// model invariants (e.g. both sides put clips in the same place), the merge gives up and returns
/// `theirs` with `droppedOurs` set.
public enum ProjectMerge {
    public struct Outcome: Sendable {
        public var project: Project
        /// Entities both sides changed differently (ours kept).
        public var conflicts: Int
        /// True when the edits couldn't be combined and `project` is just `theirs`.
        public var droppedOurs: Bool
    }

    public static func merge(base: Project, ours: Project, theirs: Project) -> Outcome {
        var conflicts = 0
        /// Three-way choice for one entity; nil = absent (deleted or not yet created).
        func pick<T: Equatable>(_ b: T?, _ o: T?, _ t: T?) -> T? {
            if o == b { return t }
            if t == b || t == o { return o }
            conflicts += 1
            return o
        }
        /// Ids in `primary` order, then the ones only in `secondary`.
        func order(_ primary: [UUID], _ secondary: [UUID]) -> [UUID] {
            let known = Set(primary)
            return primary + secondary.filter { !known.contains($0) }
        }

        var p = ours
        p.version = max(ours.version, theirs.version)
        p.canvas = pick(base.canvas, ours.canvas, theirs.canvas) ?? ours.canvas

        let media = (base: index(base.media), ours: index(ours.media), theirs: index(theirs.media))
        p.media = order(ours.media.map(\.id), theirs.media.map(\.id))
            .compactMap { pick(media.base[$0], media.ours[$0], media.theirs[$0]) }

        // Track order: theirs unless we reordered.
        let tracks = (base: settings(base), ours: settings(ours), theirs: settings(theirs))
        let trackOrder = ours.tracks.map(\.id) == base.tracks.map(\.id)
            ? order(theirs.tracks.map(\.id), ours.tracks.map(\.id))
            : order(ours.tracks.map(\.id), theirs.tracks.map(\.id))
        p.tracks = trackOrder.compactMap { pick(tracks.base[$0], tracks.ours[$0], tracks.theirs[$0]) }

        let clips = (base: placements(base), ours: placements(ours), theirs: placements(theirs))
        for id in order(ours.tracks.flatMap(\.clips).map(\.id), theirs.tracks.flatMap(\.clips).map(\.id)) {
            guard let placed = pick(clips.base[id], clips.ours[id], clips.theirs[id]) else { continue }
            guard let ti = p.trackIndex(placed.track) else { conflicts += 1; continue }  // its track was deleted
            p.tracks[ti].clips.append(placed.clip)
        }
        for ti in p.tracks.indices { StoreTimeline.sortClips(&p, track: ti) }

        let broken = ProjectValidator.issues(in: p, checkFiles: false).contains { $0.severity == .error }
            && !ProjectValidator.issues(in: ours, checkFiles: false).contains { $0.severity == .error }
        if broken { return Outcome(project: theirs, conflicts: conflicts, droppedOurs: true) }
        return Outcome(project: p, conflicts: conflicts, droppedOurs: false)
    }

    private struct Placement: Equatable {
        var track: UUID
        var clip: Clip
    }

    private static func index(_ media: [MediaItem]) -> [UUID: MediaItem] {
        Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Each track without its clips.
    private static func settings(_ p: Project) -> [UUID: Track] {
        Dictionary(p.tracks.map { t in
            var t = t
            t.clips = []
            return (t.id, t)
        }, uniquingKeysWith: { a, _ in a })
    }

    private static func placements(_ p: Project) -> [UUID: Placement] {
        Dictionary(p.tracks.flatMap { t in t.clips.map { ($0.id, Placement(track: t.id, clip: $0)) } },
                   uniquingKeysWith: { a, _ in a })
    }
}
