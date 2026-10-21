import Foundation
import Combine
import Observation

public enum TrimEdge: Sendable { case leading, trailing }

/// The single source of truth for the open project and editor UI state.
/// All edits go through `mutate` so that undo/redo, dirty tracking, autosave and
/// engine notifications (`changes`) happen in one place.
@MainActor
@Observable
public final class EditorStore {
    // MARK: Document
    public private(set) var project: Project
    /// File the project was last saved to / opened from.
    public var projectURL: URL?
    public private(set) var isDirty = false
    /// Increments on every project change (edits, undo, redo, load).
    public private(set) var revision = 0

    // MARK: Editor UI state (not part of undo)
    /// Selected clip IDs.
    public var selection: Set<UUID> = []
    /// Media selected in the media bin.
    public var selectedMediaID: UUID?
    /// Timeline playhead position. While playing, PlaybackController updates this.
    /// UI code that wants the video to follow must call `PlaybackController.seek(to:)`.
    public var playhead: Seconds = 0
    /// Timeline zoom.
    public var pixelsPerSecond: Double = 80
    public var snappingEnabled = true
    /// Transient status message shown in the UI (errors, "Saved", ...).
    public var statusMessage: String?

    /// Fires (on the main actor) after every project change with the new project.
    @ObservationIgnored public let changes = PassthroughSubject<Project, Never>()

    // MARK: Undo
    @ObservationIgnored private var undoStack: [(name: String, project: Project)] = []
    @ObservationIgnored private var redoStack: [(name: String, project: Project)] = []
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceDate = Date.distantPast
    public private(set) var undoActionName: String?
    public private(set) var redoActionName: String?
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public static let undoLimit = 300

    public init(project: Project = .empty()) {
        self.project = project
    }

    // MARK: - Core mutation

    /// Applies `body` to the project as one undoable action.
    /// - Parameter coalesce: when non-nil and equal to the previous action's key within 1.5 s,
    ///   no new undo step is recorded (use for slider drags / live dragging, e.g. "transform-<clipID>").
    public func mutate(_ actionName: String, coalesce: String? = nil, _ body: (inout Project) -> Void) {
        var next = project
        body(&next)
        guard next != project else { return }
        let now = Date()
        let coalescing = coalesce != nil && coalesce == lastCoalesceKey && now.timeIntervalSince(lastCoalesceDate) < 1.5
        if !coalescing {
            undoStack.append((actionName, project))
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        }
        redoStack.removeAll()
        lastCoalesceKey = coalesce
        lastCoalesceDate = now
        apply(next)
    }

    /// Ends any in-progress coalescing so the next `mutate` records a fresh undo step.
    public func endCoalescing() { lastCoalesceKey = nil }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append((step.name, project))
        lastCoalesceKey = nil
        apply(step.project)
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append((step.name, project))
        lastCoalesceKey = nil
        apply(step.project)
    }

    /// Replaces the whole project without recording undo (load / new). Clears undo history.
    public func replaceProject(_ p: Project, url: URL?) {
        undoStack.removeAll(); redoStack.removeAll(); lastCoalesceKey = nil
        projectURL = url
        selection = []
        selectedMediaID = nil
        playhead = 0
        apply(p)
        isDirty = false
    }

    private func apply(_ p: Project) {
        project = p
        isDirty = true
        revision += 1
        undoActionName = undoStack.last?.name
        redoActionName = redoStack.last?.name
        // Drop selection of clips that no longer exist.
        selection = selection.filter { p.locate(clip: $0) != nil }
        changes.send(p)
    }

    // MARK: - Queries

    public func clip(_ id: UUID) -> Clip? { project.clip(id) }
    public func media(_ id: UUID?) -> MediaItem? { project.media(id) }
    public var selectedClips: [Clip] { selection.compactMap { project.clip($0) }.sorted { $0.start < $1.start } }
    /// The single selected clip, if exactly one is selected.
    public var primarySelection: Clip? { selection.count == 1 ? selection.first.flatMap { project.clip($0) } : nil }
    public var frameDuration: Seconds { project.canvas.frameDuration }

    // MARK: - Media (STUB — implemented by the store module)

    /// Adds imported media to the project bin (dedupes by URL).
    public func addMedia(_ items: [MediaItem]) {
        mutate("Import Media") { p in p.media.append(contentsOf: items) }
    }

    /// Removes media and every clip that uses it.
    public func removeMedia(_ id: UUID) {}

    // MARK: - Clip operations (STUBS — implemented by the store module)

    /// Places a clip for `mediaID` on the timeline.
    /// - trackID: target track (must accept the media kind); nil = pick the lowest compatible
    ///   track that is free at `time` for the clip's length, creating a new track if none is.
    /// - time: timeline start; nil = playhead. Overlaps are resolved to the nearest free start.
    /// Video/audio clips default to the full media duration; images default to 5 s.
    /// Selects the new clip and returns its id.
    @discardableResult
    public func addClip(mediaID: UUID, trackID: UUID? = nil, at time: Seconds? = nil) -> UUID? { nil }

    /// Adds a 5 s text clip (default `TextStyle`) at `time` (nil = playhead) on `trackID`
    /// (nil = topmost video track that is free there, creating a new video track if needed).
    @discardableResult
    public func addTextClip(at time: Seconds? = nil, trackID: UUID? = nil, style: TextStyle = TextStyle()) -> UUID? { nil }

    /// Splits at the playhead: the selected clips under the playhead, or — if no selected clip
    /// is under the playhead — every clip on unlocked tracks under the playhead.
    public func splitAtPlayhead() {}

    /// Splits one clip at timeline time `t` (frame quantized). No-op within one frame of an edge.
    /// The right part gets a new id; fadeOut stays on the right part, fadeIn on the left part.
    @discardableResult
    public func split(clipID: UUID, at t: Seconds) -> UUID? { nil }

    /// True if the selection is ≥2 clips on one track that are adjacent with no gap.
    public var canJoinSelection: Bool { false }

    /// Joins the selected adjacent clips. Clips from the same media with continuous source
    /// (a.sourceOut == b.sourceIn) merge into one clip. Otherwise (different media / non-
    /// continuous) the selection cannot be merged and this is a no-op.
    public func joinSelection() {}

    /// Removes the gap before each selected clip (or, with no selection, all gaps on all tracks),
    /// shifting later clips on the same track left.
    public func closeGaps() {}

    /// Deletes selected clips. `ripple` shifts later clips on the same track left by the deleted length.
    public func deleteSelection(ripple: Bool) {}

    /// Duplicates selected clips, placing each copy right after the original on its track
    /// (nearest free spot). Selects the copies.
    public func duplicateSelection() {}

    /// Moves a clip to `trackID` (must accept the clip's content) at `start`.
    /// Overlaps resolve to the nearest free start on the target track. Returns false if refused
    /// (locked track / incompatible). Use `coalesce` for live drags.
    @discardableResult
    public func moveClip(_ id: UUID, toTrack trackID: UUID, start: Seconds, coalesce: String? = nil) -> Bool { false }

    /// Trims a clip edge to timeline time `t`, clamped by neighbours, media bounds (video/audio
    /// cannot extend past the source; images/text are unbounded), and a 1-frame minimum.
    /// Leading-edge trims move `start` and `sourceIn` together.
    public func trimClip(_ id: UUID, edge: TrimEdge, to t: Seconds, coalesce: String? = nil) {}

    /// Edits arbitrary clip properties (transform, color, text, fades, volume...).
    /// Values are clamped to valid ranges (fadeIn + fadeOut ≤ duration, opacity 0...1, etc).
    public func updateClip(_ id: UUID, _ actionName: String, coalesce: String? = nil, _ body: (inout Clip) -> Void) {
        mutate(actionName, coalesce: coalesce) { p in
            guard let l = p.locate(clip: id) else { return }
            body(&p.tracks[l.track].clips[l.clip])
        }
    }

    /// Moves a video clip's embedded audio onto an audio track as a separate audio clip
    /// (same media, start, sourceIn, duration, volume, fades) and sets `audioMuted` on the video clip.
    public func detachAudio(_ clipID: UUID) {}

    /// Applies a fade-in and/or fade-out (seconds) to the selected clips; nil leaves that side unchanged.
    public func setFades(in fadeIn: Seconds?, out fadeOut: Seconds?) {}

    // MARK: - Tracks (STUBS)

    @discardableResult
    public func addTrack(_ kind: TrackKind) -> UUID { UUID() }
    /// Removes a track and its clips.
    public func removeTrack(_ id: UUID) {}
    public func setTrack(_ id: UUID, muted: Bool? = nil, hidden: Bool? = nil, locked: Bool? = nil) {}

    // MARK: - Snapping (STUBS)

    /// Clip edges (all tracks, excluding `excluding` clip ids), the playhead and 0.
    public func snapTargets(excluding: Set<UUID> = []) -> [Seconds] { [0] }
    /// Snaps `t` to the nearest target within `thresholdSeconds` if snapping is enabled.
    public func snap(_ t: Seconds, excluding: Set<UUID> = [], thresholdSeconds: Seconds) -> Seconds { t }

    // MARK: - Canvas

    public func setCanvas(_ c: CanvasSettings) {
        mutate("Change Canvas") { $0.canvas = c }
    }

    // MARK: - Project files (STUBS)

    /// Writes the project as pretty JSON (`.editrush`) and clears `isDirty`.
    public func save(to url: URL) throws {}
    /// Loads a `.editrush` file (replaces the project, clears undo).
    public func open(_ url: URL) throws {}
    public func newProject() { replaceProject(.empty(), url: nil) }
    /// Writes the current project to `EditorStore.autosaveURL` (cheap; call after edits, debounced).
    public func autosave() {}
    /// Restores the autosave if present (on launch). Returns true if restored.
    @discardableResult
    public func restoreAutosave() -> Bool { false }

    /// ~/Library/Application Support/EditRush/Autosave.editrush
    public static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EditRush", isDirectory: true)
        return dir.appendingPathComponent("Autosave.\(Project.fileExtension)")
    }
}
