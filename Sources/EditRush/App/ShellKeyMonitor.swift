import AppKit
import EditRushCore

/// Handles the editor's plain-key shortcuts (Space, S, arrows, ⌫, J/K/L, N, ⇧Z, comma/period, …).
///
/// The Playback / Edit menus show the same keys, so this monitor consumes every key it maps to
/// make sure each press fires exactly once. While a text control is being edited or a sheet /
/// modal panel is up, mapped keys are delivered straight to the key window instead, which keeps
/// typing intact (plain-key menu equivalents would otherwise swallow the characters).
@MainActor
final class ShellKeyMonitor {
    static let shared = ShellKeyMonitor()

    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var isMenuTracking = false

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let keyEvent = event
            let consumed = MainActor.assumeIsolated { self?.handle(keyEvent) ?? false }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = false }
            },
        ]
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard !isMenuTracking, let shortcut = Self.shortcut(for: event) else { return false }
        let window = event.window ?? NSApp.keyWindow
        if ShellResponder.isEditingText || ShellResponder.isModalActive || window is NSPanel {
            guard let window else { return false }
            window.sendEvent(event)
            return true
        }
        // Held keys auto-repeat only for stepping / nudging; other repeats are swallowed.
        if !event.isARepeat || shortcut.repeats { shortcut.action() }
        return true
    }

    private struct Shortcut {
        var repeats = false
        var action: () -> Void
    }

    /// The editor shortcut for a key press, or nil if the key is not one.
    private static func shortcut(for event: NSEvent) -> Shortcut? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let shift = mods.contains(.shift)

        switch event.keyCode {
        case 49: // space
            return shift ? nil : Shortcut(action: ShellActions.togglePlay)
        case 123: // ←
            return Shortcut(repeats: true) { shift ? ShellActions.jump(by: -1) : ShellActions.stepFrames(-1) }
        case 124: // →
            return Shortcut(repeats: true) { shift ? ShellActions.jump(by: 1) : ShellActions.stepFrames(1) }
        case 126, 115: // ↑, Home
            return shift ? nil : Shortcut(action: ShellActions.goToStart)
        case 125, 119: // ↓, End
            return shift ? nil : Shortcut(action: ShellActions.goToEnd)
        case 51, 117: // ⌫, ⌦
            return Shortcut { ShellActions.delete(ripple: shift) }
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",", "<": return Shortcut(repeats: true) { ShellActions.nudge(frames: shift ? -10 : -1) }
        case ".", ">": return Shortcut(repeats: true) { ShellActions.nudge(frames: shift ? 10 : 1) }
        case "j" where !shift: return Shortcut(repeats: true) { ShellActions.jump(by: -1) }
        case "s" where !shift: return Shortcut(action: ShellActions.split)
        case "k" where !shift: return Shortcut(action: ShellActions.pause)
        case "l" where !shift: return Shortcut(action: ShellActions.play)
        case "n" where !shift: return Shortcut(action: ShellActions.toggleSnapping)
        case "z" where shift: return Shortcut(action: ShellActions.zoomToFit)
        default: return nil
        }
    }
}
