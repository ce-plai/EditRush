import AppKit
import Observation

/// Live queries about the key window's first responder, used to route keys and Edit menu
/// commands to text controls instead of the timeline.
@MainActor
enum ShellResponder {
    /// True when the key window's first responder is an editable text view (e.g. the field
    /// editor of a focused text field), so typing must reach it untouched.
    static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }

    /// True when the first responder is any text view, editable or merely selectable
    /// (copy / select all should then act on the text).
    static var isTextFocused: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// True when a sheet, modal panel or alert is in front of the main window.
    static var isModalActive: Bool {
        if NSApp.modalWindow != nil { return true }
        guard let key = NSApp.keyWindow else { return false }
        return key.sheetParent != nil || key.attachedSheet != nil || key.isModalPanel
    }

    /// Sends a standard responder-chain action (cut:, copy:, undo:, ...) to the focused control.
    static func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

/// Observable mirror of `ShellResponder.isTextFocused` so menu item enabled states and titles
/// update when the user focuses / leaves a text field. Observes the key window's
/// `firstResponder` (KVO compliant) and key-window changes.
@MainActor
@Observable
final class ShellResponderTracker {
    private(set) var isTextFocused = false
    @ObservationIgnored private var firstResponderObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyWindowObserver: NSObjectProtocol?

    func start() {
        guard keyWindowObserver == nil else { return }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.track(window) }
        }
        track(NSApp.keyWindow)
    }

    private func track(_ window: NSWindow?) {
        firstResponderObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                let focused = window.firstResponder is NSText
                guard let self, self.isTextFocused != focused else { return }
                self.isTextFocused = focused
            }
        }
        if window == nil { isTextFocused = false }
    }
}
