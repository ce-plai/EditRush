import SwiftUI
import EditRushCore

/// Maps between canvas pixels (top-left origin, +y down) and viewer points.
struct PreviewCanvasMapping: Equatable {
    /// Canvas size in pixels.
    var canvasSize: CGSize
    /// Where the canvas is drawn inside the viewer, in points.
    var viewRect: CGRect

    /// Fits a canvas of `canvasSize` inside `container` (minus `insets`), centred.
    init(canvasSize: CGSize, container: CGSize, insets: EdgeInsets) {
        self.canvasSize = canvasSize
        let avail = CGSize(width: max(1, container.width - insets.leading - insets.trailing),
                           height: max(1, container.height - insets.top - insets.bottom))
        let cw = max(1, canvasSize.width), ch = max(1, canvasSize.height)
        let k = min(avail.width / cw, avail.height / ch)
        let size = CGSize(width: (cw * k).rounded(), height: (ch * k).rounded())
        let origin = CGPoint(x: (insets.leading + (avail.width - size.width) / 2).rounded(),
                             y: (insets.top + (avail.height - size.height) / 2).rounded())
        viewRect = CGRect(origin: origin, size: size)
    }

    /// Points per canvas pixel.
    var scale: CGFloat { viewRect.width / max(1, canvasSize.width) }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: viewRect.minX + p.x * scale, y: viewRect.minY + p.y * scale)
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - viewRect.minX) / scale, y: (p.y - viewRect.minY) / scale)
    }
}

/// A clip's on-screen frame in viewer points: an unrotated size about `center`, rotated
/// clockwise by `rotation` degrees.
struct PreviewClipFrame: Equatable {
    var center: CGPoint
    var size: CGSize
    var rotation: Double

    private var radians: Double { rotation * .pi / 180 }

    /// Converts a point given relative to the centre in the clip's unrotated frame to viewer points.
    func point(local p: CGPoint) -> CGPoint {
        let c = cos(radians), s = sin(radians)
        return CGPoint(x: center.x + p.x * c - p.y * s, y: center.y + p.x * s + p.y * c)
    }

    /// Converts a viewer point into the clip's unrotated frame, relative to the centre.
    func local(_ p: CGPoint) -> CGPoint {
        let dx = p.x - center.x, dy = p.y - center.y
        let c = cos(-radians), s = sin(-radians)
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }

    /// Corners in viewer points: top-left, top-right, bottom-right, bottom-left (before rotation).
    var corners: [CGPoint] {
        let w = size.width / 2, h = size.height / 2
        return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map(point(local:))
    }

    /// Axis-aligned bounds of the rotated frame.
    var bounds: CGRect {
        let pts = corners
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Hit test honouring rotation; `outset` grows the frame by that many points on every side.
    func contains(_ p: CGPoint, outset: CGFloat = 0) -> Bool {
        let l = local(p)
        return abs(l.x) <= size.width / 2 + outset && abs(l.y) <= size.height / 2 + outset
    }

    /// Midpoint of the top edge, and the rotation handle placed `distance` points above it.
    func topMid() -> CGPoint { point(local: CGPoint(x: 0, y: -size.height / 2)) }
    func rotationHandle(distance: CGFloat) -> CGPoint { point(local: CGPoint(x: 0, y: -size.height / 2 - distance)) }

    var path: Path {
        var p = Path()
        p.addLines(corners)
        p.closeSubpath()
        return p
    }
}

/// Clip placement queries shared by the overlay's drawing and hit-testing.
enum PreviewLayout {
    /// Content size used by `ClipGeometry.rect` for a visual clip, or nil for audio clips.
    static func contentSize(of clip: Clip, in project: Project) -> CGSize? {
        if let style = clip.text { return TextRenderer.size(for: style, canvas: project.canvas.size) }
        guard let media = project.media(clip.mediaID), media.hasVisual else { return nil }
        return media.pixelSize
    }

    /// The clip's displayed rectangle (before rotation) in canvas pixels.
    static func canvasRect(of clip: Clip, in project: Project) -> CGRect? {
        guard let content = contentSize(of: clip, in: project) else { return nil }
        return ClipGeometry.rect(content: content, canvas: project.canvas.size, transform: clip.transform, isText: clip.isText)
    }

    static func frame(of clip: Clip, in project: Project, mapping: PreviewCanvasMapping) -> PreviewClipFrame? {
        guard let r = canvasRect(of: clip, in: project) else { return nil }
        return PreviewClipFrame(center: mapping.toView(CGPoint(x: r.midX, y: r.midY)),
                                size: CGSize(width: r.width * mapping.scale, height: r.height * mapping.scale),
                                rotation: clip.transform.rotation)
    }

    /// Visual clips on visible video tracks that are active at `t`, topmost first.
    static func activeVisualClips(in project: Project, at t: Seconds) -> [(clip: Clip, track: Track)] {
        var result: [(Clip, Track)] = []
        for track in project.tracks.reversed() where track.kind == .video && !track.isHidden {
            for clip in track.clips where clip.contains(t) && contentSize(of: clip, in: project) != nil {
                result.append((clip, track))
            }
        }
        return result
    }

    /// The single selected clip if it is visual, on a visible video track, and active at `t`.
    @MainActor static func editableSelection(store: EditorStore, at t: Seconds) -> (clip: Clip, track: Track)? {
        guard store.selection.count == 1, let id = store.selection.first,
              let loc = store.project.locate(clip: id) else { return nil }
        let track = store.project.tracks[loc.track]
        let clip = track.clips[loc.clip]
        guard track.kind == .video, !track.isHidden, clip.contains(t),
              contentSize(of: clip, in: store.project) != nil else { return nil }
        return (clip, track)
    }
}

/// HH:MM:SS:FF formatting at the canvas frame rate.
enum PreviewTimecode {
    static func string(_ t: Seconds, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        let totalFrames = max(0, Int((t * fps + 1e-6).rounded(.down)))
        let frames = totalFrames % rate
        let totalSeconds = totalFrames / rate
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames)
    }
}

/// Short aspect label for a canvas, e.g. "16:9", "9:16", "4:5".
enum PreviewCanvasLabel {
    static func ratio(_ c: CanvasSettings) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(1, gcd(c.width, c.height))
        let w = c.width / g, h = c.height / g
        if w > 50 || h > 50 { return String(format: "%.2f:1", c.aspect) }
        return "\(w):\(h)"
    }

    /// Name of the preset matching `c`'s dimensions, if any.
    static func presetName(_ c: CanvasSettings) -> String? {
        CanvasSettings.presets.first { $0.settings.width == c.width && $0.settings.height == c.height }?.name
    }
}
