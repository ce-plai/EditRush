import Foundation
import CoreGraphics
import Observation
import EditRushCore

/// One timeline row (a track) in content coordinates: `y` is measured from the top of the
/// track area (just below the ruler), before vertical scrolling.
struct TimelineRow: Equatable, Identifiable {
    let trackID: UUID
    let kind: TrackKind
    let name: String
    let y: CGFloat
    let height: CGFloat
    let isMuted: Bool
    let isHidden: Bool
    let isLocked: Bool

    var id: UUID { trackID }
    var maxY: CGFloat { y + height }
}

/// Fixed metrics of the timeline panel (shared by the AppKit canvas and the SwiftUI headers).
enum TimelineMetrics {
    /// Gap above the first track.
    static let topPadding: CGFloat = 4
    /// Separator between the video and the audio track groups.
    static let groupGap: CGFloat = 8
    /// Empty area below the last track (drop zone for new tracks + add-track buttons).
    static let bottomPadding: CGFloat = 56
    /// Horizontal inset of time 0 from the left edge of the clip area.
    static let leadingPadding: CGFloat = 10
    /// Vertical inset of a clip inside its row.
    static let clipInset: CGFloat = 3
    /// Width of the trim zones at each clip edge.
    static let trimHandleWidth: CGFloat = 7
    /// Snapping distance in points.
    static let snapDistance: CGFloat = 8
    /// Thickness of the overlay scroll bars.
    static let scrollerThickness: CGFloat = 9
    static let headerToolbarHeight: CGFloat = 36
}

/// Row layout for a project: video tracks top→bottom in reverse array order (top row = top
/// layer), then audio tracks in array order.
struct TimelineLayout: Equatable {
    let rows: [TimelineRow]
    /// Height of all rows including paddings (excluding `bottomPadding`).
    let tracksHeight: CGFloat

    init(project: Project) {
        var rows: [TimelineRow] = []
        var y = TimelineMetrics.topPadding
        let video = project.tracks.filter { $0.kind == .video }.reversed()
        let audio = project.tracks.filter { $0.kind == .audio }
        for t in video {
            rows.append(Self.row(t, project: project, y: y, height: Theme.videoTrackHeight))
            y += Theme.videoTrackHeight
        }
        if !video.isEmpty && !audio.isEmpty { y += TimelineMetrics.groupGap }
        for t in audio {
            rows.append(Self.row(t, project: project, y: y, height: Theme.audioTrackHeight))
            y += Theme.audioTrackHeight
        }
        self.rows = rows
        self.tracksHeight = y
    }

    private static func row(_ t: Track, project: Project, y: CGFloat, height: CGFloat) -> TimelineRow {
        TimelineRow(trackID: t.id, kind: t.kind, name: project.displayName(of: t.id), y: y, height: height,
                    isMuted: t.isMuted, isHidden: t.isHidden, isLocked: t.isLocked)
    }

    var contentHeight: CGFloat { tracksHeight + TimelineMetrics.bottomPadding }

    /// Row containing content-space `y`, if any.
    func row(atY y: CGFloat) -> TimelineRow? { rows.first { y >= $0.y && y < $0.maxY } }
    func row(for trackID: UUID) -> TimelineRow? { rows.first { $0.trackID == trackID } }

    /// Y of the separator between the video and audio groups (nil when one group is empty).
    var groupSeparatorY: CGFloat? {
        guard let lastVideo = rows.last(where: { $0.kind == .video }),
              rows.contains(where: { $0.kind == .audio }) else { return nil }
        return lastVideo.maxY + TimelineMetrics.groupGap / 2
    }
}

/// State shared between the AppKit timeline canvas and the SwiftUI track headers. The canvas
/// publishes header rows only when they change so the headers never re-render during drags.
@MainActor
@Observable
final class TimelineSharedState {
    /// Vertical scroll offset of the track area in points.
    var offsetY: CGFloat = 0
    var layout = TimelineLayout(project: Project())
}

// MARK: - Ruler scale

/// Tick spacing for the ruler at a given zoom.
struct RulerScale: Equatable {
    /// Seconds between labelled ticks.
    let major: Seconds
    /// Number of minor subdivisions between labelled ticks (1 = none).
    let divisions: Int
    /// Major interval expressed in frames when it is shorter than one second.
    let majorFrames: Int?

    /// Picks the smallest "nice" interval whose labelled ticks are at least `minSpacing` points apart.
    static func make(pixelsPerSecond pps: Double, frameRate: Double, minSpacing: Double = 76) -> RulerScale {
        let fps = max(1, frameRate.rounded())
        let frameSteps = [1, 2, 5, 10, 15].filter { Double($0) < fps }
        for f in frameSteps {
            let s = Double(f) / fps
            if s * pps >= minSpacing {
                return RulerScale(major: s, divisions: divisions(frames: f, spacing: s * pps), majorFrames: f)
            }
        }
        let secondSteps: [(Seconds, [Int])] = [
            (1, [10, 5, 2]), (2, [4, 2]), (5, [5]), (10, [10, 5, 2]), (15, [3]), (30, [6, 3]),
            (60, [12, 6, 4, 2]), (120, [4, 2]), (300, [5]), (600, [10, 2]), (900, [3]),
            (1800, [6, 3]), (3600, [12, 6, 4, 2]), (7200, [4, 2]), (18000, [5]), (36000, [10, 2]),
        ]
        for (s, subs) in secondSteps where s * pps >= minSpacing || s == secondSteps.last!.0 {
            let n = subs.first { s * pps / Double($0) >= 7 } ?? 1
            return RulerScale(major: s, divisions: n, majorFrames: nil)
        }
        return RulerScale(major: 3600, divisions: 1, majorFrames: nil)
    }

    private static func divisions(frames: Int, spacing: Double) -> Int {
        // Prefer one tick per frame, otherwise the largest divisor of `frames` that stays legible.
        let candidates = (1...frames).reversed().filter { frames % $0 == 0 }
        return candidates.first { spacing / Double($0) >= 7 } ?? 1
    }

    /// Label for a labelled tick at `t`.
    func label(for t: Seconds, frameRate: Double) -> String {
        if majorFrames != nil {
            let fps = max(1, frameRate.rounded())
            let frame = Int((t * fps).rounded()) % Int(fps)
            if frame != 0 { return "\(frame)f" }
        }
        return TimelineFormat.rulerTime(t)
    }
}

// MARK: - Formatting

enum TimelineFormat {
    /// "m:ss" or "h:mm:ss" for whole-second ruler labels.
    static func rulerTime(_ t: Seconds) -> String {
        let total = Int((t + 0.0005).rounded(.down))
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "HH:MM:SS:FF" at `frameRate` (non-drop).
    static func timecode(_ t: Seconds, frameRate: Double) -> String {
        let fps = max(1, Int(frameRate.rounded()))
        let frames = max(0, Int((max(0, t) * frameRate + 0.001).rounded(.down)))
        let ff = frames % fps
        let total = frames / fps
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60, ff)
    }

    /// Short human duration, e.g. "4.5s" or "1:12".
    static func shortDuration(_ d: Seconds) -> String {
        d < 60 ? String(format: "%.1fs", d) : rulerTime(d)
    }
}
