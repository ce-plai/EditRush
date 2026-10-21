import AppKit
import EditRushCore

/// Protects a running export from quitting the app or closing the editor window (which quits
/// it): asks first, and when the user stops the export, waits until it has cleaned up its
/// temporary file before letting the app go.
@MainActor
enum ShellExportGuard {
    private static var exporter: Exporter { AppEnvironment.shared.exporter }

    /// Asks "Stop Export and Quit" / "Keep Exporting". Returns true when the user chose to stop.
    static func confirmStop() -> Bool {
        let alert = NSAlert()
        alert.messageText = "An export is in progress"
        let name = AppEnvironment.shared.shell.exportURL.map { "“\($0.lastPathComponent)”" } ?? "The video"
        alert.informativeText = "\(name) is \(Int((exporter.progress * 100).rounded(.down)))% exported. "
            + "If you quit now, the export stops and no file is written."
        alert.addButton(withTitle: "Keep Exporting")
        let stop = alert.addButton(withTitle: "Stop Export and Quit")
        stop.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Cancels the export and waits (at most `timeout`) until it has wound down.
    static func stopExport(timeout: Duration = .seconds(5)) async {
        exporter.cancel()
        let deadline = ContinuousClock.now + timeout
        while exporter.isExporting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Makes `window`'s close button and File ▸ Close ask before closing it during an export.
    static func install(on window: NSWindow) {
        guard !(window.delegate is CloseInterceptor) else { return }
        let interceptor = CloseInterceptor(wrapping: window.delegate)
        interceptors[ObjectIdentifier(window)] = interceptor
        window.delegate = interceptor
    }

    private static var interceptors: [ObjectIdentifier: CloseInterceptor] = [:]

    /// Window delegate that answers `windowShouldClose(_:)` and forwards everything else to the
    /// delegate it replaced (SwiftUI's), so the scene keeps working as before.
    @MainActor
    private final class CloseInterceptor: NSObject, NSWindowDelegate {
        nonisolated(unsafe) weak var wrapped: NSWindowDelegate?
        private var isStopping = false

        init(wrapping delegate: NSWindowDelegate?) {
            wrapped = delegate
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (wrapped?.responds(to: selector) ?? false)
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            wrapped?.responds(to: selector) == true ? wrapped : super.forwardingTarget(for: selector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard ShellExportGuard.exporter.isExporting else {
                return wrapped?.windowShouldClose?(sender) ?? true
            }
            guard !isStopping, ShellExportGuard.confirmStop() else { return false }
            isStopping = true
            Task {
                await ShellExportGuard.stopExport()
                isStopping = false
                sender.performClose(nil)
            }
            return false
        }
    }
}
