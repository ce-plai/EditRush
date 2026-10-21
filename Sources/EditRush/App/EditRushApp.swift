import SwiftUI
import AppKit
import EditRushCore

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { SnapshotRunner.run() }
        } else {
            EditRushApp.main()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment { .shared }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        env.documents.startSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        ShellKeyMonitor.shared.install()
        env.responder.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        env.documents.open(urls)
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
