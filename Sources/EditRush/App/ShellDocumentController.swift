import AppKit
import Combine
import UniformTypeIdentifiers
import EditRushCore

/// Project file flows: New / Open / Save / Save As, continuous (Rush-style) saving, launch
/// restore and opening files handed over by Finder or the Dock.
///
/// Every project change is debounced (1.5 s) into `store.autosave()`; projects that have a file
/// are also written back to it, so explicit saving is rarely needed.
@MainActor
final class ShellDocumentController {
    static let projectType = UTType(filenameExtension: Project.fileExtension, conformingTo: .json) ?? .json
    static let autosaveDelay: TimeInterval = 1.5

    private let store: EditorStore
    private let playback: PlaybackController
    private var changesSubscription: AnyCancellable?
    /// Revision last written by `flush()`; skips redundant writes.
    private var flushedRevision = -1

    init(store: EditorStore, playback: PlaybackController) {
        self.store = store
        self.playback = playback
    }

    // MARK: Launch / quit

    /// Restores the last session and starts continuous saving. Call once before the window appears.
    func startSession() {
        store.restoreAutosave()
        flushedRevision = store.revision
        changesSubscription = store.changes
            .debounce(for: .seconds(Self.autosaveDelay), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
    }

    /// Writes pending changes now (autosave + the project file when it has one).
    func flush() {
        guard store.revision != flushedRevision else { return }
        flushedRevision = store.revision
        store.autosave()
        guard let url = store.projectURL, store.isDirty else { return }
        do {
            try store.save(to: url)
        } catch {
            store.statusMessage = "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    // MARK: Commands

    func newProject() {
        guard confirmDiscardingChanges() else { return }
        playback.pause()
        store.newProject()
        flush()
    }

    func openWithPanel() {
        guard confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an EditRush project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    /// Saves to the project's file, or asks for one. Returns false if cancelled or failed.
    @discardableResult
    func save() -> Bool {
        guard let url = store.projectURL else { return saveAs() }
        return write(to: url)
    }

    /// Asks for a location and saves there. Returns false if cancelled or failed.
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileSafeName(store.project.name) + "." + Project.fileExtension
        if let dir = store.projectURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension.lowercased() != Project.fileExtension {
            url.appendPathExtension(Project.fileExtension)
        }
        let name = url.deletingPathExtension().lastPathComponent
        if store.project.name != name {
            store.mutate("Rename Project") { $0.name = name }
        }
        return write(to: url)
    }

    // MARK: Files from Finder / Dock

    /// Opens a project file and/or imports media files handed to the app.
    func open(_ urls: [URL]) {
        let projects = urls.filter { $0.pathExtension.lowercased() == Project.fileExtension }
        let media = urls.filter { $0.pathExtension.lowercased() != Project.fileExtension }
        if let project = projects.first, confirmDiscardingChanges() {
            load(project)
        }
        if !media.isEmpty {
            Task { await ImportActions.importURLs(media, store: store) }
        }
    }

    // MARK: Helpers

    private func load(_ url: URL) {
        playback.pause()
        do {
            try store.open(url)
            flushedRevision = store.revision
            store.autosave()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            store.statusMessage = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    private func write(to url: URL) -> Bool {
        do {
            try store.save(to: url)
            store.projectURL = url
            flushedRevision = store.revision
            store.autosave()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            store.statusMessage = "Saved “\(url.lastPathComponent)”"
            return true
        } catch {
            store.statusMessage = "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return false
        }
    }

    private var hasContent: Bool {
        !store.project.media.isEmpty || store.project.tracks.contains { !$0.clips.isEmpty }
    }

    /// True when replacing the current project would lose work: it has never been saved to a
    /// file (only the autosave holds it), or it has edits not yet written to its file.
    private var hasUnsavedWork: Bool {
        hasContent && (store.projectURL == nil || store.isDirty)
    }

    /// Asks Save / Don't Save / Cancel when needed. Returns true if the caller may proceed.
    private func confirmDiscardingChanges() -> Bool {
        if store.projectURL != nil { flush() }
        guard hasUnsavedWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(store.project.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: store.projectURL == nil ? "Save…" : "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    static func fileSafeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
