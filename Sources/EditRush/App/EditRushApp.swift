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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct EditRushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("EditRush", id: "main") {
            MainView().appEnvironment()
        }
        .defaultSize(width: 1500, height: 920)
    }
}
