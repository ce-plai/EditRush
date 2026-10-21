import AppKit
import Observation

/// Keyboard focus of the inspector's text controls. Text editing ends (and the field commits)
/// as soon as the user works anywhere else, so editor shortcuts (Space, S, ⌫, ...) never land in
/// a forgotten field. Other panels use `requestTextEditing` to open a title's text for typing.
@MainActor
@Observable
final class InspectorFocus {
    static let shared = InspectorFocus()

    /// Asks the inspector to show a title's Text page with its editor focused and all text selected.
    struct TextEditRequest: Equatable {
        let clipID: UUID
        fileprivate let serial: Int
    }

    /// The pending request, cleared once the editor has taken focus or the selection moved on.
    private(set) var textEditRequest: TextEditRequest?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var clickMonitor: Any?

    /// Requests text editing for `clipID`, which should be the single selected title clip.
    func requestTextEditing(_ clipID: UUID) {
        serial += 1
        textEditRequest = TextEditRequest(clipID: clipID, serial: serial)
    }

    /// Clears `request` if it is still the pending one.
    func consume(_ request: TextEditRequest) {
        if textEditRequest == request { textEditRequest = nil }
    }

    /// Ends text editing in `window` (default: the key window). The focused control commits on
    /// focus loss, matching the timeline canvas.
    static func endTextEditing(in window: NSWindow? = nil) {
        guard let window = window ?? NSApp.keyWindow, window.firstResponder is NSTextView else { return }
        window.makeFirstResponder(nil)
    }

    /// Installs (once) a mouse-down monitor that ends text editing when a click lands outside the
    /// focused text control: on the preview, transport, media bin, toolbar or any other control.
    func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let mouseEvent = event
            MainActor.assumeIsolated { Self.endTextEditingIfOutside(mouseEvent) }
            return event
        }
    }

    private static func endTextEditingIfOutside(_ event: NSEvent) {
        guard let window = event.window, !(window is NSPanel),
              let editor = window.firstResponder as? NSTextView, editor.isEditable,
              let root = window.contentView?.superview ?? window.contentView,
              let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return }
        if isInside(hit, editor: editor) { return }
        // A click on another text control moves focus there by itself.
        if hit is NSText || (hit as? NSTextField)?.isEditable == true { return }
        window.makeFirstResponder(nil)
    }

    /// True when `view` is part of the control that owns `editor` (a field editor's text field,
    /// or the scroll view a text view scrolls in).
    private static func isInside(_ view: NSView, editor: NSTextView) -> Bool {
        if view.isDescendant(of: editor) { return true }
        if let field = editor.delegate as? NSView, view.isDescendant(of: field) { return true }
        if let scroll = editor.enclosingScrollView, scroll.documentView === editor, view.isDescendant(of: scroll) { return true }
        return false
    }
}
