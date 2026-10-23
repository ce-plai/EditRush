import Foundation
import Combine
import Observation
#if canImport(AppKit)
import AppKit
#endif

public enum TrimEdge: Sendable { case leading, trailing }

/// Errors thrown while reading or writing `.editrush` files.
public enum ProjectFileError: LocalizedError, Equatable {
    /// The file was written by a newer EditRush (its `version` is above `Project.currentVersion`).
    case newerVersion(found: Int, supported: Int)
    /// The file is not a valid EditRush project.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .newerVersion(found, supported):
            "This project was saved by a newer version of EditRush (format \(found); this version reads up to \(supported)). Please update EditRush to open it."
        case let .unreadable(reason):
            "The file isn't a valid EditRush project (\(reason))."
        }
    }
}

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
    /// True when the project differs from the last saved / opened / restored state.
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

    /// Clips copied by `copySelection` / `cutSelection` (internal clipboard, not NSPasteboard).
    var clipboard: [EditorClipboardItem] = []

    // MARK: Undo
    @ObservationIgnored private var undoStack: [(name: String, project: Project)] = []
    @ObservationIgnored private var redoStack: [(name: String, project: Project)] = []
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceDate = Date.distantPast
    /// The project as last saved / opened / restored; `isDirty` compares against it.
    @ObservationIgnored private var cleanProject: Project
    public private(set) var undoActionName: String?
    public private(set) var redoActionName: String?
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// Maximum number of undo steps kept (the oldest are dropped).
    public static let undoLimit = 1000

    // MARK: Autosave
    /// Where `autosave()` writes and `restoreAutosave()` reads. Defaults to `EditorStore.autosaveURL`.
    @ObservationIgnored public var autosaveFileURL: URL = EditorStore.autosaveURL
    @ObservationIgnored private var lastAutosaved: (revision: Int, url: URL?)?

    public init(project: Project = .empty()) {
        self.project = project
        self.cleanProject = project
    }

    // MARK: - Core mutation

    /// Applies `body` to the project as one undoable action.
    /// - Parameters:
    ///   - coalesce: when non-nil and equal to the previous action's key, no new undo step is
    ///     recorded. The key stays open until `endCoalescing()`, undo/redo, or a mutation with a
    ///     different (or no) key — use a per-gesture key (e.g. "timeline-move-<UUID>") and call
    ///     `endCoalescing()` when the gesture ends.
    ///   - coalesceTimeout: only for edits with no end event (key repeats, color wells): also
    ///     starts a new step when more than this many seconds passed since the previous edit.
    public func mutate(_ actionName: String, coalesce: String? = nil, coalesceTimeout: TimeInterval? = nil,
                       _ body: (inout Project) -> Void) {
        var next = project
        body(&next)
        guard next != project else { return }
        let now = Date()
        let coalescing = coalesce != nil && coalesce == lastCoalesceKey
            && coalesceTimeout.map { now.timeIntervalSince(lastCoalesceDate) < $0 } ?? true
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

    /// The project before the coalesced action that `key` would continue (the current project when
    /// it starts a new one), so a live drag can recompute each step from where the gesture began.
    func coalescingBase(_ key: String?) -> Project {
        guard let key, key == lastCoalesceKey, let base = undoStack.last?.project else { return project }
        return base
    }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append((step.name, project))
        lastCoalesceKey = nil
        apply(keepingName(step.project))
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append((step.name, project))
        lastCoalesceKey = nil
        apply(keepingName(step.project))
    }

    /// The project name follows the file name (set on save/open), so history never reverts it.
    private func keepingName(_ p: Project) -> Project {
        var p = p
        p.name = project.name
        return p
    }

    /// Replaces the whole project without recording undo (load / new). Clears undo history.
    public func replaceProject(_ p: Project, url: URL?) {
        undoStack.removeAll(); redoStack.removeAll(); lastCoalesceKey = nil
        projectURL = url
        selection = []
        selectedMediaID = nil
        playhead = 0
        cleanProject = p
        apply(p)
        isDirty = false
    }

    private func apply(_ p: Project) {
        project = p
        isDirty = p != cleanProject
        revision += 1
        undoActionName = undoStack.last?.name
        redoActionName = redoStack.last?.name
        // Drop selection of clips that no longer exist.
        if !selection.isEmpty {
            let existing = Set(p.tracks.lazy.flatMap(\.clips).map(\.id))
            let kept = selection.intersection(existing)
            if kept.count != selection.count { selection = kept }
        }
        changes.send(p)
    }

    // MARK: - Queries

    public func clip(_ id: UUID) -> Clip? { project.clip(id) }
    public func media(_ id: UUID?) -> MediaItem? { project.media(id) }
    public var selectedClips: [Clip] { selection.compactMap { project.clip($0) }.sorted { $0.start < $1.start } }
    /// The single selected clip, if exactly one is selected.
    public var primarySelection: Clip? { selection.count == 1 ? selection.first.flatMap { project.clip($0) } : nil }
    public var frameDuration: Seconds { project.canvas.frameDuration }

    // MARK: - Media

    /// Adds imported media to the project bin (dedupes by URL).
    public func addMedia(_ items: [MediaItem]) {
        mutate("Import Media") { p in
            var known = Set(p.media.map { $0.url.standardizedFileURL })
            for item in items where known.insert(item.url.standardizedFileURL).inserted {
                p.media.append(item)
            }
        }
    }

    /// Removes media and every clip that uses it.
    public func removeMedia(_ id: UUID) {
        mutate("Remove Media") { p in
            p.media.removeAll { $0.id == id }
            for ti in p.tracks.indices { p.tracks[ti].clips.removeAll { $0.mediaID == id } }
        }
        if selectedMediaID == id { selectedMediaID = nil }
    }

    // MARK: - Timeline zoom

    /// Visible width in points of the timeline's clip area — set by the timeline view on resize.
    public var timelineViewportWidth: Double = 1000
    public static let zoomRange: ClosedRange<Double> = 5...2000
    /// Multiplies `pixelsPerSecond` by `factor`, clamped to `zoomRange`.
    public func zoom(by factor: Double) {
        pixelsPerSecond = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, pixelsPerSecond * factor))
    }
    /// Fits the whole project (plus a little margin) into the visible timeline width.
    public func zoomToFit() {
        let d = max(project.duration, 5) * 1.05
        pixelsPerSecond = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, timelineViewportWidth / d))
    }

    // MARK: - Canvas

    public func setCanvas(_ c: CanvasSettings) {
        mutate("Change Canvas") { $0.canvas = c }
    }

    // MARK: - Project files

    /// Writes the project as pretty JSON (`.editrush`) and clears `isDirty`.
    /// The project takes its name from the file name.
    public func save(to url: URL) throws {
        var p = project
        p.name = url.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(p).write(to: url, options: .atomic)
        projectURL = url
        if p != project {
            project = p
            revision += 1
            changes.send(p)
        }
        cleanProject = p
        isDirty = false
    }

    /// Loads a `.editrush` file (replaces the project, clears undo).
    /// Throws `ProjectFileError.newerVersion` for files from a newer EditRush; reports
    /// media files that no longer exist in `statusMessage`.
    public func open(_ url: URL) throws {
        replaceProject(ProjectValidator.normalized(try Self.readProjectFile(url)), url: url)
        reportMissingMedia()
    }

    /// Decodes a `.editrush` file as written, before `ProjectValidator.normalized`; relative
    /// media paths resolve against the file's folder and the name follows the file name.
    public nonisolated static func readProjectFile(_ url: URL) throws -> Project {
        var p = try decodeProject(Data(contentsOf: url), relativeTo: url.deletingLastPathComponent())
        p.name = url.deletingPathExtension().lastPathComponent
        return p
    }

    public func newProject() { replaceProject(.empty(), url: nil) }

    // MARK: - Outside changes

    /// The project as last saved / opened, i.e. what its file holds as far as the editor knows.
    public var savedProject: Project { cleanProject }

    /// Why the project file couldn't be loaded the last time it changed outside EditRush, or nil.
    @ObservationIgnored private var unusableFileReason: String?

    /// Brings in a version of the project file written by another app (e.g. an agent) as one
    /// undoable step. Edits not yet saved are merged with it (`ProjectMerge`); afterwards the store
    /// is dirty only when those edits still need writing to the file.
    @discardableResult
    public func applyExternalChange(_ theirs: Project) -> ProjectMerge.Outcome {
        var outcome = isDirty
            ? ProjectMerge.merge(base: cleanProject, ours: project, theirs: theirs)
            : ProjectMerge.Outcome(project: theirs, conflicts: 0, droppedOurs: false)
        outcome.project.name = project.name
        cleanProject = theirs
        lastCoalesceKey = nil
        mutate("Outside Change") { $0 = outcome.project }
        isDirty = project != cleanProject
        return outcome
    }

    /// Loads changes made to the project file outside EditRush since it was last saved or opened,
    /// and says so in `statusMessage`. Returns false while the file can't be used (unreadable, or
    /// invalid per `ProjectValidator`): callers must not overwrite it then, so the other app's
    /// work isn't lost.
    @discardableResult
    public func syncWithFile() -> Bool {
        guard let url = projectURL, FileManager.default.fileExists(atPath: url.path) else { return true }
        let raw: Project
        do {
            raw = try Self.readProjectFile(url)
        } catch {
            return reportUnusableFile(url, error.localizedDescription)
        }
        let theirs = ProjectValidator.normalized(raw)
        guard theirs != cleanProject else {
            unusableFileReason = nil
            return true
        }
        if let issue = ProjectValidator.issues(in: raw, checkFiles: false).first(where: { $0.severity == .error }) {
            return reportUnusableFile(url, "\(issue.path): \(issue.message)")
        }
        unusableFileReason = nil
        let outcome = applyExternalChange(theirs)
        var message = "Loaded changes made to “\(url.lastPathComponent)” outside EditRush"
        if outcome.droppedOurs {
            message += ". They clashed with your latest edits, which were set aside (Undo brings them back)."
        } else if outcome.conflicts > 0 {
            message += ". Where you'd both changed the same thing, your version was kept."
        }
        statusMessage = message
        return true
    }

    private func reportUnusableFile(_ url: URL, _ reason: String) -> Bool {
        if reason != unusableFileReason {
            unusableFileReason = reason
            statusMessage = "“\(url.lastPathComponent)” was changed outside EditRush but can't be loaded (\(reason)). "
                + "Your edits won't be saved to it until it's fixed."
        }
        return false
    }

    /// Writes the current project to `autosaveFileURL` plus a small sidecar recording `projectURL`.
    /// Cheap: skipped when nothing changed since the last autosave; encoding and the atomic
    /// write happen on a background queue (`flushPendingAutosaves()` waits for them).
    public func autosave() {
        _ = Self.terminationHook
        if let last = lastAutosaved, last.revision == revision, last.url == projectURL { return }
        lastAutosaved = (revision, projectURL)
        let snapshot = project
        let state = EditorAutosaveState(projectURL: projectURL)
        let fileURL = autosaveFileURL
        let stateURL = Self.autosaveStateURL(for: fileURL)
        Self.autosaveQueue.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
                try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("EditRush autosave failed: \(error.localizedDescription)")
            }
        }
    }

    /// Restores the autosave if present (on launch). Returns true if restored.
    /// Restores `projectURL` from the sidecar; the restored project is not dirty.
    @discardableResult
    public func restoreAutosave() -> Bool {
        Self.flushPendingAutosaves()
        let fileURL = autosaveFileURL
        guard let data = try? Data(contentsOf: fileURL), let p = try? Self.decodeProject(data) else { return false }
        let state = (try? Data(contentsOf: Self.autosaveStateURL(for: fileURL)))
            .flatMap { try? JSONDecoder().decode(EditorAutosaveState.self, from: $0) }
        replaceProject(p, url: state?.projectURL)
        lastAutosaved = (revision, projectURL)
        reportMissingMedia()
        return true
    }

    /// Blocks until queued autosave writes have finished (call before quitting; done automatically
    /// when the app terminates).
    public nonisolated static func flushPendingAutosaves() {
        autosaveQueue.sync {}
    }

    /// ~/Library/Application Support/EditRush/Autosave.editrush
    public static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EditRush", isDirectory: true)
        return dir.appendingPathComponent("Autosave.\(Project.fileExtension)")
    }

    /// Sidecar next to the autosave file, e.g. `Autosave.state.json`.
    static func autosaveStateURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("state.json")
    }

    private nonisolated static let autosaveQueue = DispatchQueue(label: "EditRush.autosave", qos: .utility)

    private static let terminationHook: Void = {
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            EditorStore.flushPendingAutosaves()
        }
        #endif
    }()

    private nonisolated static func decodeProject(_ data: Data, relativeTo directory: URL? = nil) throws -> Project {
        let decoder = JSONDecoder()
        decoder.userInfo[.projectDirectory] = directory
        let probe: EditorProjectVersionProbe
        do { probe = try decoder.decode(EditorProjectVersionProbe.self, from: data) } catch {
            throw ProjectFileError.unreadable("not JSON")
        }
        if let v = probe.version, v > Project.currentVersion {
            throw ProjectFileError.newerVersion(found: v, supported: Project.currentVersion)
        }
        do { return try decoder.decode(Project.self, from: data) } catch let error as DecodingError {
            throw ProjectFileError.unreadable(Self.describe(error))
        }
    }

    private nonisolated static func describe(_ error: DecodingError) -> String {
        func location(_ c: DecodingError.Context) -> String {
            c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        func path(_ c: DecodingError.Context) -> String {
            let p = location(c)
            return p.isEmpty ? c.debugDescription : "\(p): \(c.debugDescription)"
        }
        switch error {
        case let .keyNotFound(key, c):
            let p = location(c)
            return p.isEmpty ? "missing \(key.stringValue)" : "missing \(key.stringValue) at \(p)"
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c): return path(c)
        @unknown default: return error.localizedDescription
        }
    }

    private func reportMissingMedia() {
        let missing = project.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard !missing.isEmpty else { return }
        let names = missing.prefix(3).map(\.url.lastPathComponent).joined(separator: ", ")
        let more = missing.count > 3 ? " and \(missing.count - 3) more" : ""
        statusMessage = "Missing media: \(names)\(more)"
    }
}

/// One copied clip with the track it came from.
struct EditorClipboardItem: Hashable, Sendable {
    var clip: Clip
    var trackKind: TrackKind
    /// Index among tracks of the same kind (0 = V1 / A1).
    var trackOrdinal: Int
}

private struct EditorAutosaveState: Codable, Sendable {
    var projectURL: URL?
}

private struct EditorProjectVersionProbe: Decodable {
    var version: Int?
}
