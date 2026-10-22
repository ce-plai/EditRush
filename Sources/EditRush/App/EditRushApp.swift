import SwiftUI
import AppKit
import EditRushCore

@main
enum Entry {
    static func main() {
        if CommandLineTool.handles(CommandLine.arguments) {
            MainActor.assumeIsolated { CommandLineTool.run(CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { SnapshotRunner.run() }
        } else {
            EditRushApp.main()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment { .shared }
    private var windowObserver: NSObjectProtocol?
    private var keyedWindows: Set<ObjectIdentifier> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        env.documents.startSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        ShellKeyMonitor.shared.install()
        env.responder.start()
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { window.map { self?.prepare($0, becameKey: true) } }
        }
        ShellResponder.mainWindow.map { prepare($0, becameKey: false) }
    }

    /// Installs the export close guard on the editor window and, until it has first become key,
    /// drops the text field AppKit picks as initial first responder, so Space / J / K / L work at once.
    private func prepare(_ window: NSWindow, becameKey: Bool) {
        guard window.identifier?.rawValue == "main", !keyedWindows.contains(ObjectIdentifier(window)) else { return }
        if becameKey { keyedWindows.insert(ObjectIdentifier(window)) }
        ShellExportGuard.install(on: window)
        ShellResponder.endTextEditing(in: window)
        DispatchQueue.main.async { ShellResponder.endTextEditing(in: window) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        env.documents.open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard env.exporter.isExporting else { return .terminateNow }
        guard ShellExportGuard.confirmStop() else { return .terminateCancel }
        Task {
            await ShellExportGuard.stopExport()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.documents.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

struct EditRushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("EditRush", id: "main") {
            MainView().appEnvironment()
        }
        .defaultSize(width: 1500, height: 920)
        .windowToolbarStyle(.unified)
        .commands { ShellCommands(env: .shared) }
    }
}
