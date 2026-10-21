import SwiftUI
import AppKit
import EditRushCore

/// Headless UI snapshot tool for development / verification:
///
///   EditRush --snapshot out.png [--demo <media folder> | --project file.editrush]
///            [--size 1600x1000] [--select-first] [--playhead 2.5] [--wait 2]
///
/// Renders `MainView` offscreen to a PNG and exits. AVPlayerLayer / Metal content is not
/// captured by `cacheDisplay`, so views check `AppEnvironment.shared.isSnapshotMode` and show
/// a `FrameRenderer` still in place of live video.
@MainActor
enum SnapshotRunner {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        let out = URL(fileURLWithPath: value("--snapshot") ?? "snapshot.png")
        var size = CGSize(width: 1600, height: 1000)
        if let s = value("--size")?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
            size = CGSize(width: w, height: h)
        }
        let env = AppEnvironment.shared
        env.isSnapshotMode = true

        Task { @MainActor in
            if let demo = value("--demo") {
                env.store.replaceProject(await DemoProject.make(from: URL(fileURLWithPath: demo)), url: nil)
            } else if let path = value("--project") {
                do { try env.store.open(URL(fileURLWithPath: path)) } catch { print("open failed:", error) }
            }
            if args.contains("--select-first"),
               let c = env.store.project.tracks.flatMap(\.clips).first {
                env.store.selection = [c.id]
            }
            if let t = value("--playhead").flatMap(Double.init) { env.playback.seek(to: t) }

            let root = MainView().appEnvironment(env).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()

            try? await Task.sleep(for: .seconds(value("--wait").flatMap(Double.init) ?? 2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("no rep"); exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            do {
                try rep.representation(using: .png, properties: [:])!.write(to: out)
                print("snapshot written:", out.path)
                exit(0)
            } catch {
                print("snapshot failed:", error); exit(1)
            }
        }
        app.run()
    }
}
