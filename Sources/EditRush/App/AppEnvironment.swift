import SwiftUI
import EditRushCore

/// Long-lived app objects shared by every view (inject with `.environment(...)`).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let store: EditorStore
    let playback: PlaybackController
    let exporter: Exporter
    /// Voiceover recording onto audio tracks.
    let recorder: VoiceoverRecorder
    /// Window-level UI state owned by the app shell (sheets, export session).
    let shell: ShellState
    /// New / Open / Save / autosave flows.
    let documents: ShellDocumentController
    /// Tracks whether a text control is being edited (for Edit menu routing).
    let responder: ShellResponderTracker
    /// True when running `--snapshot` (views must not depend on live AVPlayer layers / windows).
    var isSnapshotMode = false

    private init() {
        store = EditorStore()
        playback = PlaybackController(store: store)
        exporter = Exporter()
        recorder = VoiceoverRecorder(store: store, playback: playback)
        shell = ShellState()
        documents = ShellDocumentController(store: store, playback: playback)
        responder = ShellResponderTracker()
    }
}

/// UI state of the main window that menus, toolbar and key handlers share.
@MainActor
@Observable
final class ShellState {
    /// Export sheet visibility (toolbar button, ⌘E).
    var isExportSheetPresented = false
    /// True from the moment an export is started until the user dismisses its result,
    /// so reopening the sheet shows progress / the outcome instead of the settings form.
    var exportSessionActive = false
    /// Destination and start time of the current / last export (for progress and result UI).
    var exportURL: URL?
    var exportStartedAt: Date?
}

extension View {
    /// Injects all shared app objects.
    @MainActor func appEnvironment(_ env: AppEnvironment? = nil) -> some View {
        let env = env ?? .shared
        return self.environment(env.store)
            .environment(env.playback)
            .environment(env.exporter)
            .environment(env.recorder)
            .environment(env.shell)
            .environment(ThumbnailCache.shared)
            .environment(WaveformCache.shared)
    }
}
