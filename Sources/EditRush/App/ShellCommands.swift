import SwiftUI
import EditRushCore

/// Menu bar: About / Check for Updates, File, Edit, Clip, View and Playback commands.
///
/// Items are small views so their titles and enabled states track the store. Plain-key
/// shortcuts shown here (Space, arrows, ⌫, J/K/L, …) are actually dispatched by
/// `ShellKeyMonitor`, which consumes those keys first so nothing fires twice.
struct ShellCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About EditRush", action: AboutPanel.show)
            if let updater = AppUpdater.shared.updater { CheckForUpdatesMenuItem(updater: updater) }
        }
        CommandGroup(replacing: .newItem) { FileMenuItems(store: env.store) }
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .undoRedo) { UndoRedoMenuItems(store: env.store, responder: env.responder) }
        CommandGroup(replacing: .pasteboard) { PasteboardMenuItems(store: env.store, responder: env.responder) }
        CommandMenu("Clip") { ClipMenuItems(store: env.store, recorder: env.recorder) }
        CommandGroup(before: .toolbar) { ViewMenuItems(store: env.store) }
        CommandMenu("Playback") { PlaybackMenuItems(store: env.store, playback: env.playback) }
    }
}

private struct FileMenuItems: View {
    let store: EditorStore

    var body: some View {
        Button("New Project", action: ShellActions.newProject).keyboardShortcut("n")
        Button("Open…", action: ShellActions.openProject).keyboardShortcut("o")
        Divider()
        Button("Save", action: ShellActions.save).keyboardShortcut("s")
        Button("Save As…", action: ShellActions.saveAs).keyboardShortcut("s", modifiers: [.command, .shift])
        Divider()
        Button("Import Media…", action: ShellActions.importMedia).keyboardShortcut("i")
        Button("Export…", action: ShellActions.showExport).keyboardShortcut("e")
            .disabled(store.project.duration <= 0)
        Divider()
    }
}

private struct UndoRedoMenuItems: View {
    let store: EditorStore
    let responder: ShellResponderTracker

    var body: some View {
        let text = responder.isTextFocused
        Button(text ? "Undo" : store.undoActionName.map { "Undo \($0)" } ?? "Undo", action: ShellActions.undo)
            .keyboardShortcut("z")
            .disabled(!text && store.undoActionName == nil)
        Button(text ? "Redo" : store.redoActionName.map { "Redo \($0)" } ?? "Redo", action: ShellActions.redo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!text && store.redoActionName == nil)
    }
}

private struct PasteboardMenuItems: View {
    let store: EditorStore
    let responder: ShellResponderTracker

    var body: some View {
        let text = responder.isTextFocused
        let noSelection = store.selection.isEmpty
        Button("Cut", action: ShellActions.cut).keyboardShortcut("x").disabled(!text && noSelection)
        Button("Copy", action: ShellActions.copy).keyboardShortcut("c").disabled(!text && noSelection)
        Button("Paste", action: ShellActions.paste).keyboardShortcut("v")
        Button("Duplicate", action: ShellActions.duplicate).keyboardShortcut("d").disabled(noSelection)
        Divider()
        Button("Delete") { ShellActions.delete(ripple: false) }
            .keyboardShortcut(.delete, modifiers: []).disabled(noSelection)
        Button("Ripple Delete") { ShellActions.delete(ripple: true) }
            .keyboardShortcut(.delete, modifiers: .shift).disabled(noSelection)
        Divider()
        Button("Select All", action: ShellActions.selectAll).keyboardShortcut("a")
    }
}

private struct ClipMenuItems: View {
    let store: EditorStore
    @Bindable var recorder: VoiceoverRecorder

    var body: some View {
        let hasClips = store.project.duration > 0
        let noSelection = store.selection.isEmpty
        Button("Split at Playhead", action: ShellActions.split).keyboardShortcut("b").disabled(!hasClips)
        Button("Join Clips", action: ShellActions.join).keyboardShortcut("j").disabled(!store.canJoinSelection)
        Button("Close Gaps", action: ShellActions.closeGaps).disabled(!hasClips)
        Button("Detach Audio", action: ShellActions.detachAudio).disabled(ShellActions.detachableClipIDs.isEmpty)
        Divider()
        Button("Add Title", action: ShellActions.addTitle).keyboardShortcut("t")
        Button(recorder.isActive ? "Stop Recording" : "Record Voiceover", action: ShellActions.toggleVoiceover)
            .keyboardShortcut("r", modifiers: [.command, .shift])
        VoiceoverMicrophonePicker(recorder: recorder)
        Toggle("Mute Timeline While Recording", isOn: $recorder.mutesTimeline)
        Divider()
        Button("Fade In 1s", action: ShellActions.fadeIn).disabled(noSelection)
        Button("Fade Out 1s", action: ShellActions.fadeOut).disabled(noSelection)
        Button("Remove Fades", action: ShellActions.removeFades).disabled(noSelection)
    }
}

private struct ViewMenuItems: View {
    let store: EditorStore

    var body: some View {
        Button("Zoom In", action: ShellActions.zoomIn).keyboardShortcut("=")
        Button("Zoom Out", action: ShellActions.zoomOut).keyboardShortcut("-")
        Button("Zoom to Fit", action: ShellActions.zoomToFit).keyboardShortcut("z", modifiers: .shift)
        Divider()
        Toggle("Snapping", isOn: Binding(get: { store.snappingEnabled }, set: { _ in ShellActions.toggleSnapping() }))
            .keyboardShortcut("n", modifiers: [])
        Divider()
    }
}

private struct PlaybackMenuItems: View {
    let store: EditorStore
    let playback: PlaybackController

    var body: some View {
        let hasSelection = !store.selection.isEmpty
        Button(playback.isPlaying ? "Pause" : "Play", action: ShellActions.togglePlay)
            .keyboardShortcut(.space, modifiers: [])
        Divider()
        Button("Previous Frame") { ShellActions.stepFrames(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
        Button("Next Frame") { ShellActions.stepFrames(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        Button("Back 1 Second") { ShellActions.jump(by: -1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
        Button("Forward 1 Second") { ShellActions.jump(by: 1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
        Divider()
        Button("Go to Start", action: ShellActions.goToStart).keyboardShortcut(.home, modifiers: [])
        Button("Go to End", action: ShellActions.goToEnd).keyboardShortcut(.end, modifiers: [])
        Divider()
        Button("Shuttle Back 1 Second") { ShellActions.jump(by: -1) }.keyboardShortcut("j", modifiers: [])
        Button("Stop", action: ShellActions.pause).keyboardShortcut("k", modifiers: [])
        Button("Play Forward", action: ShellActions.play).keyboardShortcut("l", modifiers: [])
        Divider()
        Button("Nudge Left") { ShellActions.nudge(frames: -1) }.keyboardShortcut(",", modifiers: []).disabled(!hasSelection)
        Button("Nudge Right") { ShellActions.nudge(frames: 1) }.keyboardShortcut(".", modifiers: []).disabled(!hasSelection)
    }
}

/// Microphone choice for voiceovers (a submenu with a checkmark on the current one).
struct VoiceoverMicrophonePicker: View {
    @Bindable var recorder: VoiceoverRecorder

    var body: some View {
        Picker("Microphone", selection: $recorder.microphoneID) {
            Text("System Default").tag(String?.none)
            ForEach(recorder.microphones, id: \.id) { mic in
                Text(mic.name).tag(Optional(mic.id))
            }
        }
        .disabled(recorder.isActive)
    }
}
