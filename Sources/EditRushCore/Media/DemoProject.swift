import Foundation

/// Builds a sample project from a folder of media (used by `--demo` and snapshot tooling).
public enum DemoProject {
    public static func make(from folder: URL) async -> Project {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { MediaImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let (items, _) = await MediaImporter.importFiles(files)
        var p = Project.empty()
        p.name = "Demo"
        p.media = items
        var vt = 0.0, at = 0.0, overlay = 4.0
        for m in items {
            switch m.kind {
            case .video:
                let d = min(m.duration, 5)
                var c = Clip(mediaID: m.id, start: vt, duration: d)
                if vt == 0 { c.fadeIn = 1 }
                p.tracks[0].clips.append(c); vt += d
            case .image:
                var c = Clip(mediaID: m.id, start: overlay, duration: 3)
                c.transform.scale = 0.35; c.transform.offsetX = 0.3; c.transform.offsetY = -0.25
                p.tracks[1].clips.append(c); overlay += 4
            case .audio:
                let d = min(m.duration, 8)
                p.tracks[2].clips.append(Clip(mediaID: m.id, start: at, duration: d)); at += d
            }
        }
        if let last = p.tracks[0].clips.indices.last { p.tracks[0].clips[last].fadeOut = 1 }
        var title = TextStyle(text: "EditRush")
        title.fontSize = 0.12
        var t = Clip(mediaID: nil, start: 0.5, duration: 3, text: title)
        t.transform.offsetY = 0.3
        p.tracks[1].clips.insert(t, at: 0)
        p.tracks[1].clips.sort { $0.start < $1.start }
        return p
    }
}
