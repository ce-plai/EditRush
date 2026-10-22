import Foundation

/// Checks a project read from disk against the model invariants (see the conventions at the top of
/// `Project.swift`). Store edits keep these by construction; hand- or tool-written files may not.
///
/// Errors break the timeline (overlaps, dangling media, clips on the wrong kind of track, unknown
/// media length). Warnings are values that `normalized` adjusts on load (out-of-range properties,
/// times off the frame grid, clips running past the end of their media).
public enum ProjectValidator {
    public struct Issue: CustomStringConvertible, Equatable, Sendable {
        public enum Severity: String, Sendable { case error, warning }
        public var severity: Severity
        /// Where in the file, e.g. `tracks[0].clips[2]`.
        public var path: String
        public var message: String
        public var description: String { "\(severity.rawValue): \(path): \(message)" }
    }

    /// The project with every clip clamped to valid ranges and frame-quantized, and each track's
    /// clips sorted by start. Overlaps and other errors are left as they are.
    public static func normalized(_ p: Project) -> Project {
        var p = p
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices {
                var c = p.tracks[ti].clips[ci]
                StoreTimeline.normalize(&c, in: p)
                p.tracks[ti].clips[ci] = c
            }
            StoreTimeline.sortClips(&p, track: ti)
        }
        return p
    }

    /// All issues in `p` (as read, before `normalized`). `checkFiles` also reports missing media files.
    public static func issues(in p: Project, checkFiles: Bool = true) -> [Issue] {
        var issues: [Issue] = []
        func error(_ path: String, _ message: String) { issues.append(Issue(severity: .error, path: path, message: message)) }
        func warning(_ path: String, _ message: String) { issues.append(Issue(severity: .warning, path: path, message: message)) }

        if p.canvas.width <= 0 || p.canvas.height <= 0 {
            error("canvas", "width and height must be positive")
        } else if p.canvas.width % 2 != 0 || p.canvas.height % 2 != 0 {
            warning("canvas", "odd width or height; video encoders need even dimensions")
        }
        if !(1...240).contains(p.canvas.frameRate) { error("canvas.frameRate", "must be between 1 and 240") }

        var mediaIDs = Set<UUID>()
        for (i, m) in p.media.enumerated() {
            let path = "media[\(i)]"
            if !mediaIDs.insert(m.id).inserted { error(path, "duplicate id \(m.id)") }
            if !m.url.isFileURL {
                error(path, "url must be a file path or file:// URL")
            } else if checkFiles, !FileManager.default.fileExists(atPath: m.url.path) {
                error(path, "file not found: \(m.url.path)")
            }
            if m.kind != .image, !(m.duration > 0) {
                error(path, "duration unknown; fill it in from `EditRush --probe \(m.url.lastPathComponent)`")
            }
            if m.hasVisual, m.pixelWidth <= 0 || m.pixelHeight <= 0 {
                error(path, "pixelWidth / pixelHeight unknown; fill them in from `EditRush --probe \(m.url.lastPathComponent)`")
            }
        }

        let normal = normalized(p)
        var trackIDs = Set<UUID>(), clipIDs = Set<UUID>()
        for (ti, track) in p.tracks.enumerated() {
            if !trackIDs.insert(track.id).inserted { error("tracks[\(ti)]", "duplicate id \(track.id)") }
            var paths: [UUID: String] = [:]
            for (ci, c) in track.clips.enumerated() {
                let path = "tracks[\(ti)].clips[\(ci)]"
                paths[c.id] = path
                if !clipIDs.insert(c.id).inserted { error(path, "duplicate id \(c.id)") }
                switch (c.mediaID, c.text) {
                case (nil, nil): error(path, "needs either mediaID or text")
                case (_?, _?): error(path, "has both mediaID and text; a clip is one or the other")
                case (let id?, nil):
                    if let m = p.media(id) {
                        if !track.accepts(m.kind) { error(path, "\(m.kind) clip on a \(track.kind) track") }
                    } else {
                        error(path, "mediaID \(id) is not in media")
                    }
                case (nil, _?):
                    if track.kind != .video { error(path, "text clip on an audio track") }
                }
                if !c.start.isFinite || c.start < 0 { error(path, "start must be ≥ 0") }
                if !c.duration.isFinite || c.duration <= 0 { error(path, "duration must be > 0") }
                if let adjusted = normal.clip(c.id) {
                    let changes = changes(c, adjusted, path: "")
                    if !changes.isEmpty { warning(path, "adjusted on load: " + changes.joined(separator: ", ")) }
                }
            }
            // Overlaps, checked on the normalized (sorted, quantized) clips.
            let clips = normal.tracks[ti].clips
            for (a, b) in zip(clips, clips.dropFirst()) where b.start < a.end - StoreTimeline.epsilon {
                error(paths[b.id] ?? "tracks[\(ti)]",
                      "overlaps \(paths[a.id] ?? "another clip") (\(format(b.start))–\(format(b.end)) vs \(format(a.start))–\(format(a.end)))")
            }
        }
        return issues
    }

    /// "field old → new" for each Double that differs (normalize only ever changes Doubles).
    private static func changes(_ a: Any, _ b: Any, path: String) -> [String] {
        let ma = Mirror(reflecting: a), mb = Mirror(reflecting: b)
        switch ma.displayStyle {
        case .struct?:
            return zip(ma.children, mb.children).flatMap { ca, cb in
                let label = ca.label ?? "?"
                return changes(ca.value, cb.value, path: path.isEmpty ? label : "\(path).\(label)")
            }
        case .optional?:
            guard let va = ma.children.first?.value, let vb = mb.children.first?.value else { return [] }
            return changes(va, vb, path: path)
        default:
            guard let x = a as? Double, let y = b as? Double, !(abs(x - y) <= 1e-6) else { return [] }
            return ["\(path) \(format(x)) → \(format(y))"]
        }
    }

    private static func format(_ v: Double) -> String {
        v.isFinite ? String(format: "%g", v) : "\(v)"
    }
}
