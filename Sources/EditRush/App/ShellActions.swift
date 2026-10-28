import AppKit
import EditRushCore

/// Every editor command reachable from the menus, toolbar and keyboard, in one place so all
/// three entry points behave identically.
@MainActor
enum ShellActions {
    /// Posted after Zoom to Fit so the timeline can also scroll to the start.
    static let zoomToFitNotification = Notification.Name("EditRushZoomToFit")
    /// Posted after the playhead is moved from the keyboard / menus so the timeline scrolls it into view.
    static let revealPlayheadNotification = Notification.Name("EditRushRevealPlayhead")

    private static var env: AppEnvironment { .shared }
    private static var store: EditorStore { env.store }
    private static var playback: PlaybackController { env.playback }
    private static var recorder: VoiceoverRecorder { env.recorder }

    // MARK: File

    static func newProject() { env.documents.newProject() }
    static func openProject() { env.documents.openWithPanel() }
    static func save() { env.documents.save() }
    static func saveAs() { env.documents.saveAs() }

    /// Renames the project (and its file, when it has one). Returns false if that failed.
    @discardableResult
    static func renameProject(_ name: String) -> Bool { env.documents.renameProject(to: name) }

    static func importMedia() {
        Task { await ImportActions.presentImportPanel(store: store) }
    }

    static var canExport: Bool { store.project.duration > 0 }

    static func showExport() {
        guard canExport || env.shell.exportSessionActive else {
            store.statusMessage = "Add something to the timeline before exporting."
            return
        }
        env.shell.isExportSheetPresented = true
    }

    // MARK: Edit

    static func undo() {
        if ShellResponder.isTextFocused { ShellResponder.send(Selector(("undo:"))) } else { store.undo() }
    }

    static func redo() {
        if ShellResponder.isTextFocused { ShellResponder.send(Selector(("redo:"))) } else { store.redo() }
    }

    static func cut() {
        if ShellResponder.isTextFocused { ShellResponder.send(#selector(NSText.cut(_:))) } else { store.cutSelection() }
    }

    static func copy() {
        if ShellResponder.isTextFocused { ShellResponder.send(#selector(NSText.copy(_:))) } else { store.copySelection() }
    }

    static func paste() {
        if ShellResponder.isTextFocused { ShellResponder.send(#selector(NSText.paste(_:))) } else { store.pasteAtPlayhead() }
    }

    static func selectAll() {
        if ShellResponder.isTextFocused { ShellResponder.send(#selector(NSText.selectAll(_:))) } else { store.selectAll() }
    }

    static func delete(ripple: Bool) {
        if ShellResponder.isEditingText { ShellResponder.send(#selector(NSText.delete(_:))) } else { store.deleteSelection(ripple: ripple) }
    }

    static func duplicate() { store.duplicateSelection() }

    // MARK: Clip

    static func split() { store.splitAtPlayhead() }
    static func join() { store.joinSelection() }
    static func closeGaps() { store.closeGaps() }

    /// Selected video clips whose embedded audio can still be detached.
    static var detachableClipIDs: [UUID] {
        store.selectedClips.filter { clip in
            guard !clip.audioMuted, let media = store.media(clip.mediaID) else { return false }
            return media.kind == .video && media.hasAudio
        }.map(\.id)
    }

    /// Detaches audio from every detachable selected clip as one undo step.
    static func detachAudio() {
        let key = "detach-\(UUID())"
        for id in detachableClipIDs { store.detachAudio(id, coalesce: key) }
        store.endCoalescing()
    }

    static func addTitle() { store.addTextClip() }
    /// Starts a voiceover on a free audio track, or stops the one in progress.
    static func toggleVoiceover() { recorder.toggle() }
    static func fadeIn() { store.setFades(in: 1, out: nil) }
    static func fadeOut() { store.setFades(in: nil, out: 1) }
    static func removeFades() { store.setFades(in: 0, out: 0) }

    // MARK: View

    static func zoomIn() { store.zoom(by: 1.5) }
    static func zoomOut() { store.zoom(by: 1 / 1.5) }

    static func zoomToFit() {
        store.zoomToFit()
        NotificationCenter.default.post(name: zoomToFitNotification, object: nil)
    }

    static func toggleSnapping() {
        store.snappingEnabled.toggle()
        store.statusMessage = store.snappingEnabled ? "Snapping on" : "Snapping off"
    }

    // MARK: Playback

    // While a voiceover is counting down or recording, play / pause end it instead.

    static func togglePlay() { recorder.isActive ? recorder.stop() : playback.togglePlay() }
    static func play() { if !recorder.isActive { playback.play() } }
    static func pause() { recorder.isActive ? recorder.stop() : playback.pause() }
    /// Esc: ends a voiceover (cancels during the countdown). Returns false when none is in progress.
    static func stopVoiceover() -> Bool {
        guard recorder.isActive else { return false }
        recorder.stop()
        return true
    }

    static func stepFrames(_ n: Int) {
        playback.stepFrames(n)
        revealPlayhead()
    }

    static func jump(by seconds: Seconds) {
        playback.seek(to: store.playhead + seconds, precise: true)
        revealPlayhead()
    }

    static func goToStart() {
        playback.goToStart()
        revealPlayhead()
    }

    static func goToEnd() {
        playback.goToEnd()
        revealPlayhead()
    }

    static func nudge(frames: Int) { store.nudgeSelection(frames: frames) }

    private static func revealPlayhead() {
        NotificationCenter.default.post(name: revealPlayheadNotification, object: nil)
    }
}
