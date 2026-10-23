import AppKit
import SwiftUI
import EditRushCore

/// Core Graphics colours and text attributes for the timeline canvas.
enum TimelinePalette {
    static func cg(_ color: Color, alpha: CGFloat = 1) -> CGColor {
        (NSColor(color).usingColorSpace(.sRGB) ?? .gray).withAlphaComponent(alpha).cgColor
    }
    static func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
    static func black(_ a: CGFloat) -> CGColor { CGColor(gray: 0, alpha: a) }

    static let panel = cg(Theme.panelBackground)
    static let ruler = cg(Theme.panelHeader)
    static let videoRow = CGColor(srgbRed: 0.165, green: 0.165, blue: 0.178, alpha: 1)
    static let audioRow = CGColor(srgbRed: 0.155, green: 0.160, blue: 0.165, alpha: 1)
    static let groupGap = cg(Theme.windowBackground)
    static let divider = white(0.07)
    static let grid = white(0.035)
    static let tick = white(0.32)
    static let minorTick = white(0.16)
    static let playhead = cg(Theme.playhead)
    static let selection = cg(Theme.selection)
    static let accent = cg(Theme.accent)
    static let accentFill = cg(Theme.accent, alpha: 0.22)
    static let snap = CGColor(srgbRed: 0.40, green: 0.88, blue: 1.0, alpha: 1)
    static let offline = CGColor(srgbRed: 0.85, green: 0.12, blue: 0.12, alpha: 0.55)

    static let labelGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [black(0.55), black(0)] as CFArray, locations: [0, 1])!

    static let rulerLabel: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor(Theme.textSecondary),
    ]
    static let clipLabel: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        return [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .shadow: shadow,
            .paragraphStyle: truncating,
        ]
    }()
    static let clipDetail: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        .paragraphStyle: truncating,
    ]
    static let textClipBody: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: truncating,
    ]
    static let hint: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(Theme.textSecondary),
    ]
    static let badge: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
}

/// Colours of one clip kind.
struct TimelineClipStyle {
    let body: CGColor
    let fill: CGColor
    let border: CGColor
    let waveform: CGColor

    init(_ color: Color) {
        let base = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        body = (base.blended(withFraction: 0.55, of: .black) ?? base).cgColor
        fill = (base.blended(withFraction: 0.15, of: .black) ?? base).cgColor
        border = (base.blended(withFraction: 0.35, of: .white) ?? base).cgColor
        waveform = (base.blended(withFraction: 0.55, of: .white) ?? base).withAlphaComponent(0.9).cgColor
    }

    static let video = TimelineClipStyle(Theme.videoClip)
    static let image = TimelineClipStyle(Theme.imageClip)
    static let text = TimelineClipStyle(Theme.textClip)
    static let audio = TimelineClipStyle(Theme.audioClip)
}

extension TimelineCanvasView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if store.pixelsPerSecond != appliedPPS { reconcileZoom() }
        // Everything read while drawing is observed; any change schedules exactly one redraw.
        withObservationTracking {
            drawTimeline(in: ctx)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.needsDisplay = true }
        }
    }

    private func drawTimeline(in ctx: CGContext) {
        _ = thumbnails.version
        _ = waveforms.version
        let project = store.project
        let scale = RulerScale.make(pixelsPerSecond: Double(pps), frameRate: project.canvas.frameRate)
        let visible = (start: rawTime(atX: -16), end: rawTime(atX: bounds.width + 16))

        ctx.setFillColor(TimelinePalette.panel)
        ctx.fill(bounds)

        let trackArea = CGRect(x: 0, y: rulerHeight, width: bounds.width, height: trackViewportHeight)
        ctx.saveGState()
        ctx.clip(to: trackArea)
        drawRowBackgrounds(in: ctx)
        drawGrid(in: ctx, scale: scale, visible: visible, area: trackArea)
        let endX = x(for: project.duration)
        if endX < bounds.width {
            ctx.setFillColor(TimelinePalette.black(0.14))
            ctx.fill(CGRect(x: max(0, endX), y: rulerHeight, width: bounds.width - max(0, endX), height: trackArea.height))
        }
        drawClips(in: ctx, project: project, visible: visible)
        if let preview = dropPreview { drawDropPreview(preview, in: ctx) }
        if project.tracks.allSatisfy({ $0.clips.isEmpty }), dropPreview == nil { drawEmptyHint(in: ctx, area: trackArea) }
        if case .marquee(let mq) = drag {
            let r = marqueeRect(mq)
            ctx.setFillColor(TimelinePalette.cg(Theme.accent, alpha: 0.12))
            ctx.fill(r)
            ctx.setStrokeColor(TimelinePalette.cg(Theme.accent, alpha: 0.8))
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5), width: 1)
        }
        ctx.restoreGState()

        drawRuler(in: ctx, scale: scale, visible: visible, frameRate: project.canvas.frameRate)
        if let t = snapGuide { drawSnapGuide(at: t, in: ctx) }
        drawScrollers(in: ctx)
    }

    // MARK: - Background, grid, ruler

    private func drawRowBackgrounds(in ctx: CGContext) {
        for row in rows.rows {
            let r = CGRect(x: 0, y: viewY(row.y), width: bounds.width, height: row.height)
            guard r.maxY >= rulerHeight, r.minY <= bounds.height else { continue }
            ctx.setFillColor(row.kind == .video ? TimelinePalette.videoRow : TimelinePalette.audioRow)
            ctx.fill(r)
            ctx.setFillColor(TimelinePalette.divider)
            ctx.fill(CGRect(x: 0, y: r.maxY - 1, width: bounds.width, height: 1))
        }
        if let sepY = rows.groupSeparatorY {
            let y = viewY(sepY - TimelineMetrics.groupGap / 2)
            ctx.setFillColor(TimelinePalette.groupGap)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: TimelineMetrics.groupGap))
        }
    }

    private func forEachTick(_ scale: RulerScale, from t0: Seconds, to t1: Seconds,
                             _ body: (_ t: Seconds, _ level: Int) -> Void) {
        let minor = scale.major / Double(scale.divisions)
        let first = max(0, Int((t0 / minor).rounded(.down)))
        let last = Int((t1 / minor).rounded(.up))
        guard last >= first else { return }
        for i in first...last {
            let level: Int
            if i % scale.divisions == 0 { level = 2 } else if scale.divisions % 2 == 0, i % scale.divisions == scale.divisions / 2 { level = 1 } else { level = 0 }
            body(Double(i) * minor, level)
        }
    }

    private func drawGrid(in ctx: CGContext, scale: RulerScale, visible: (start: Seconds, end: Seconds), area: CGRect) {
        ctx.setFillColor(TimelinePalette.grid)
        forEachTick(scale, from: visible.start, to: visible.end) { t, level in
            guard level == 2 else { return }
            ctx.fill(CGRect(x: x(for: t).rounded(), y: area.minY, width: 1, height: area.height))
        }
    }

    private func drawRuler(in ctx: CGContext, scale: RulerScale, visible: (start: Seconds, end: Seconds), frameRate: Double) {
        let h = rulerHeight
        ctx.setFillColor(TimelinePalette.ruler)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: h))
        let endX = x(for: store.project.duration)
        if endX > 0 {
            ctx.setFillColor(TimelinePalette.white(0.025))
            ctx.fill(CGRect(x: 0, y: 0, width: min(endX, bounds.width), height: h))
        }
        forEachTick(scale, from: visible.start, to: visible.end) { t, level in
            let x = x(for: t).rounded()
            let len: CGFloat = level == 2 ? 10 : level == 1 ? 7 : 4
            ctx.setFillColor(level == 0 ? TimelinePalette.minorTick : TimelinePalette.tick)
            ctx.fill(CGRect(x: x, y: h - len - 1, width: 1, height: len))
            if level == 2 {
                let label = scale.label(for: t, frameRate: frameRate) as NSString
                label.draw(at: CGPoint(x: x + 4, y: 3), withAttributes: TimelinePalette.rulerLabel)
            }
        }
        ctx.setFillColor(TimelinePalette.black(0.45))
        ctx.fill(CGRect(x: 0, y: h - 1, width: bounds.width, height: 1))
    }

    private func drawSnapGuide(at t: Seconds, in ctx: CGContext) {
        let x = x(for: t).rounded()
        ctx.setFillColor(TimelinePalette.snap)
        ctx.fill(CGRect(x: x - 0.5, y: rulerHeight - 6, width: 1.5, height: bounds.height - rulerHeight + 6))
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: x - 4.5, y: rulerHeight - 6))
        tri.addLine(to: CGPoint(x: x + 5, y: rulerHeight - 6))
        tri.addLine(to: CGPoint(x: x + 0.25, y: rulerHeight))
        tri.closeSubpath()
        ctx.addPath(tri)
        ctx.fillPath()
    }

    private func drawScrollers(in ctx: CGContext) {
        let active: Bool = {
            if case .scroller = drag { return true }
            return hover == .scroller
        }()
        for bar in [horizontalScroller(), verticalScroller()].compactMap({ $0 }) {
            let r = TimelineMetrics.scrollerThickness / 2
            if active {
                ctx.setFillColor(TimelinePalette.black(0.35))
                ctx.addPath(CGPath(roundedRect: bar.track, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            ctx.setFillColor(TimelinePalette.white(active ? 0.42 : 0.22))
            ctx.addPath(CGPath(roundedRect: bar.knob.insetBy(dx: 1, dy: 1), cornerWidth: r - 1, cornerHeight: r - 1, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawEmptyHint(in ctx: CGContext, area: CGRect) {
        let text = "Drag media here to start editing — or press ⌘I to import" as NSString
        let size = text.size(withAttributes: TimelinePalette.hint)
        // Centre on V1 when visible so the box never straddles the group gap.
        let anchorRow = rows.rows.last { $0.kind == .video } ?? rows.rows.first
        let midY = anchorRow.map { viewY($0.y + $0.height / 2) }.flatMap { area.contains(CGPoint(x: area.midX, y: $0)) ? $0 : nil } ?? area.midY
        let box = CGRect(x: (area.midX - size.width / 2 - 18).rounded(), y: (midY - size.height / 2 - 10).rounded(),
                         width: size.width + 36, height: size.height + 20)
        ctx.setStrokeColor(TimelinePalette.white(0.14))
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        text.draw(at: CGPoint(x: box.minX + 18, y: box.minY + 10), withAttributes: TimelinePalette.hint)
    }

    // MARK: - Clips

    private func drawClips(in ctx: CGContext, project: Project, visible: (start: Seconds, end: Seconds)) {
        let selection = store.selection
        for row in rows.rows {
            let top = viewY(row.y)
            guard top < bounds.height, top + row.height > rulerHeight,
                  let track = project.tracks.first(where: { $0.id == row.trackID }) else { continue }
            for clip in track.clips {
                if clip.end < visible.start { continue }
                if clip.start > visible.end { break }
                drawClip(clip, track: track, row: row, selected: selection.contains(clip.id), in: ctx)
            }
        }
    }

    private func drawClip(_ clip: Clip, track: Track, row: TimelineRow, selected: Bool, in ctx: CGContext) {
        let rect = clipRect(clip, in: row)
        let media = mediaIndex[clip.mediaID ?? UUID()]
        // Detached audio keeps its video media, so audio tracks decide by track kind.
        let kind: MediaKind? = clip.isText ? nil : (track.kind == .audio ? .audio : media?.kind)
        let style: TimelineClipStyle
        switch kind {
        case .video: style = .video
        case .image: style = .image
        case .audio: style = .audio
        case nil: style = .text
        }
        // Clamp huge clips to just beyond the viewport so paths stay small; the clamped
        // corners are off screen.
        let minX = max(rect.minX, -16), maxX = min(rect.maxX, bounds.width + 16)
        let shape = CGRect(x: minX, y: rect.minY, width: max(1, maxX - minX), height: rect.height)
        let radius = min(Theme.cornerRadius, rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let dimmed = track.isLocked || (track.kind == .video && track.isHidden) || (track.kind == .audio && track.isMuted)
        let offline = media.map { offlineMediaIDs.contains($0.id) } ?? false

        ctx.saveGState()
        if dimmed { ctx.setAlpha(0.42) }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(style.body)
        ctx.fill(shape)

        switch kind {
        case .video:
            guard let media else { break }
            let hasSound = media.hasAudio && !clip.audioMuted && rect.height > 36
            let strip: CGFloat = hasSound ? 13 : 0
            drawFilmstrip(media: media, clip: clip, clipRect: rect,
                          area: CGRect(x: shape.minX, y: shape.minY, width: shape.width, height: shape.height - strip), in: ctx)
            if hasSound {
                let stripRect = CGRect(x: shape.minX, y: shape.maxY - strip, width: shape.width, height: strip)
                ctx.setFillColor(TimelinePalette.black(0.55))
                ctx.fill(stripRect)
                let muted = track.isMuted
                drawWaveform(media: media, clip: clip, clipRect: rect, area: stripRect.insetBy(dx: 0, dy: 1.5),
                             color: muted ? TimelinePalette.white(0.25) : style.waveform, in: ctx)
            }
        case .image:
            if let media {
                drawFilmstrip(media: media, clip: clip, clipRect: rect, area: shape, in: ctx)
            }
        case .audio:
            ctx.setFillColor(style.fill)
            ctx.fill(shape)
            ctx.setFillColor(TimelinePalette.black(0.18))
            ctx.fill(CGRect(x: shape.minX, y: shape.minY, width: shape.width, height: 16))
            if let media {
                drawWaveform(media: media, clip: clip, clipRect: rect,
                             area: CGRect(x: shape.minX, y: shape.minY + 16, width: shape.width, height: shape.height - 18),
                             color: style.waveform, in: ctx)
            }
        case nil:
            drawTextClipBody(clip, rect: rect, shape: shape, style: style, in: ctx)
        }

        if kind != .audio, kind != nil {
            ctx.drawLinearGradient(TimelinePalette.labelGradient, start: CGPoint(x: 0, y: shape.minY),
                                   end: CGPoint(x: 0, y: shape.minY + 22), options: [])
        }
        drawFades(clip, rect: rect, in: ctx)
        if track.isLocked { drawLockStripes(shape, in: ctx) }
        if offline {
            ctx.setFillColor(TimelinePalette.offline)
            ctx.fill(shape)
        }
        ctx.restoreGState()

        // Text clips show their text in the body instead of a label.
        if kind != nil { drawLabel(for: clip, media: media, offline: offline, rect: rect, in: ctx) }

        // Border
        if selected {
            ctx.setStrokeColor(TimelinePalette.selection)
            ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: shape.insetBy(dx: 1, dy: 1), cornerWidth: max(0, radius - 1),
                               cornerHeight: max(0, radius - 1), transform: nil))
            ctx.strokePath()
        } else {
            let hovered = hover.clipID == clip.id
            ctx.setStrokeColor(hovered ? TimelinePalette.white(0.75) : style.border)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: shape.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, radius - 0.5),
                               cornerHeight: max(0, radius - 0.5), transform: nil))
            ctx.strokePath()
        }
        if !track.isLocked, showsFadeHandles(for: clip, rect: rect) {
            drawFadeHandle(fadeHandleCenter(for: clip, rect: rect, fadeIn: true), active: clip.fadeIn > 0, in: ctx)
            drawFadeHandle(fadeHandleCenter(for: clip, rect: rect, fadeIn: false), active: clip.fadeOut > 0, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawLabel(for clip: Clip, media: MediaItem?, offline: Bool, rect: CGRect, in ctx: CGContext) {
        var title = clip.label ?? media?.name ?? clip.text?.text ?? "Clip"
        if offline { title = "⚠︎ Media Offline — " + title }
        var x = max(rect.minX, 0) + 7
        var trailingInset: CGFloat = 7
        // Keep the label clear of the fade handles.
        if showsFadeHandles(for: clip, rect: rect) {
            let handle = fadeHandleCenter(for: clip, rect: rect, fadeIn: true)
            if handle.x + 7 > x, handle.x - 7 < x + 40 { x = handle.x + 8 }
            let outHandle = fadeHandleCenter(for: clip, rect: rect, fadeIn: false)
            if outHandle.x > min(rect.maxX, bounds.width) - 48 {
                trailingInset = max(trailingInset, min(rect.maxX, bounds.width) - outHandle.x + 9)
            }
        }
        let available = rect.maxX - 6 - x
        guard available > 14 else { return }
        var titleWidth = available
        if rect.width > 150 {
            var detail = TimelineFormat.shortDuration(clip.duration)
            if clip.speed != 1 { detail = TimelineFormat.speed(clip.speed) + " · " + detail }
            let detailText = detail as NSString
            let size = detailText.size(withAttributes: TimelinePalette.clipDetail)
            let detailX = min(rect.maxX, bounds.width) - trailingInset - size.width
            if detailX - x > 60 {
                detailText.draw(at: CGPoint(x: detailX, y: rect.minY + 4), withAttributes: TimelinePalette.clipDetail)
                titleWidth = detailX - 8 - x
            }
        }
        (title as NSString).draw(in: CGRect(x: x, y: rect.minY + 2.5, width: titleWidth, height: 15),
                                 withAttributes: TimelinePalette.clipLabel)
    }

    private func drawTextClipBody(_ clip: Clip, rect: CGRect, shape: CGRect, style: TimelineClipStyle, in ctx: CGContext) {
        ctx.setFillColor(style.fill)
        ctx.fill(shape)
        // Subtle diagonal texture so titles read as generated content.
        ctx.saveGState()
        ctx.setStrokeColor(TimelinePalette.white(0.06))
        ctx.setLineWidth(6)
        var x = shape.minX - shape.minX.truncatingRemainder(dividingBy: 18) - shape.height
        while x < shape.maxX {
            ctx.move(to: CGPoint(x: x, y: shape.maxY))
            ctx.addLine(to: CGPoint(x: x + shape.height, y: shape.minY))
            x += 18
        }
        ctx.strokePath()
        ctx.restoreGState()

        let visibleMinX = max(rect.minX, 0)
        let badge = CGRect(x: visibleMinX + 7, y: (rect.midY - 9).rounded(), width: 18, height: 18)
        guard rect.maxX - badge.maxX > -4 else { return }
        ctx.setFillColor(TimelinePalette.black(0.28))
        ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ("T" as NSString).draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 1.5), withAttributes: TimelinePalette.textClipBody)
        let text = (clip.label ?? clip.text?.text ?? "Title").replacingOccurrences(of: "\n", with: " ") as NSString
        let width = rect.maxX - badge.maxX - 14
        if width > 12 {
            text.draw(in: CGRect(x: badge.maxX + 7, y: badge.minY + 0.5, width: width, height: 18), withAttributes: TimelinePalette.textClipBody)
        }
    }

    private func drawFades(_ clip: Clip, rect: CGRect, in ctx: CGContext) {
        func ramp(_ a: CGPoint, _ b: CGPoint, _ corner: CGPoint) {
            let tri = CGMutablePath()
            tri.move(to: a); tri.addLine(to: b); tri.addLine(to: corner); tri.closeSubpath()
            ctx.setFillColor(TimelinePalette.black(0.5))
            ctx.addPath(tri)
            ctx.fillPath()
            ctx.setStrokeColor(TimelinePalette.white(0.85))
            ctx.setLineWidth(1.25)
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.strokePath()
        }
        if clip.fadeIn > 0 {
            let w = min(CGFloat(clip.fadeIn) * pps, rect.width)
            ramp(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX + w, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY))
        }
        if clip.fadeOut > 0 {
            let w = min(CGFloat(clip.fadeOut) * pps, rect.width)
            ramp(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - w, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        }
    }

    private func drawFadeHandle(_ c: CGPoint, active: Bool, in ctx: CGContext) {
        let r: CGFloat = 4.5
        let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(active ? TimelinePalette.white(1) : TimelinePalette.white(0.8))
        ctx.setShadow(offset: .zero, blur: 2, color: TimelinePalette.black(0.8))
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(TimelinePalette.black(0.5))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawLockStripes(_ shape: CGRect, in ctx: CGContext) {
        ctx.setStrokeColor(TimelinePalette.black(0.3))
        ctx.setLineWidth(2)
        var x = shape.minX - shape.minX.truncatingRemainder(dividingBy: 10) - shape.height
        while x < shape.maxX {
            ctx.move(to: CGPoint(x: x, y: shape.maxY))
            ctx.addLine(to: CGPoint(x: x + shape.height, y: shape.minY))
            x += 10
        }
        ctx.strokePath()
    }

    // MARK: - Filmstrip & waveform

    /// Tiles thumbnails across the clip, anchored at the clip start, each showing the source
    /// frame at its position (images repeat their poster). Only visible tiles are drawn.
    private func drawFilmstrip(media: MediaItem, clip: Clip, clipRect rect: CGRect, area: CGRect, in ctx: CGContext) {
        guard area.height > 4, area.width > 0 else { return }
        let aspect = media.pixelHeight > 0 ? CGFloat(media.pixelWidth) / CGFloat(media.pixelHeight) : 16 / 9
        let tileWidth = max(16, area.height * min(max(aspect, 0.45), 2.6))
        let first = max(0, Int(((area.minX - rect.minX) / tileWidth).rounded(.down)))
        let last = Int(((min(area.maxX, rect.maxX) - rect.minX) / tileWidth).rounded(.up))
        guard last > first else { return }
        let lastSourceTime = max(clip.sourceIn, clip.sourceOut - store.frameDuration)
        ctx.interpolationQuality = .medium
        for i in first..<last {
            let offset = CGFloat(i) * tileWidth
            let tile = CGRect(x: rect.minX + offset, y: area.minY, width: tileWidth, height: area.height)
            let t = media.kind == .image ? 0 : min(clip.sourceIn + Seconds((offset + tileWidth / 2) / pps) * clip.speed, lastSourceTime)
            if let image = thumbnails.frame(for: media, at: t) {
                drawImage(image, aspectFill: tile.insetBy(dx: 0.5, dy: 0), in: ctx)
            } else {
                ctx.setFillColor(TimelinePalette.white(0.04))
                ctx.fill(tile.insetBy(dx: 0.5, dy: 0))
            }
        }
    }

    private func drawImage(_ image: CGImage, aspectFill rect: CGRect, in ctx: CGContext) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, rect.width > 0 else { return }
        let s = max(rect.width / iw, rect.height / ih)
        let target = CGRect(x: rect.midX - iw * s / 2, y: rect.midY - ih * s / 2, width: iw * s, height: ih * s)
        ctx.saveGState()
        ctx.clip(to: rect)
        // The view is flipped; flip the image back upright around its own centre.
        ctx.translateBy(x: 0, y: target.minY + target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: target)
        ctx.restoreGState()
    }

    /// Mirrored peak envelope over the clip's source range, scaled by volume and fades.
    private func drawWaveform(media: MediaItem, clip: Clip, clipRect rect: CGRect, area: CGRect, color: CGColor, in ctx: CGContext) {
        guard area.height > 2 else { return }
        let x0 = max(area.minX, rect.minX).rounded(.down), x1 = min(area.maxX, rect.maxX)
        guard x1 > x0 else { return }
        let mid = area.midY, half = area.height / 2
        guard let peaks = waveforms.peaks(for: media), !peaks.isEmpty else {
            ctx.setFillColor(TimelinePalette.white(0.18))
            ctx.fill(CGRect(x: x0, y: mid - 0.5, width: x1 - x0, height: 1))
            return
        }
        let rate = WaveformCache.peaksPerSecond
        let gain = min(max(clip.volume, 0), 1.5)
        let step: CGFloat = 1
        let secondsPerStep = Seconds(step / pps) * clip.speed
        var amps: [CGFloat] = []
        amps.reserveCapacity(Int((x1 - x0) / step) + 2)
        var x = x0
        while x <= x1 {
            let offset = Seconds((x - rect.minX) / pps)
            let s0 = clip.sourceIn + offset * clip.speed
            var i0 = Int(s0 * rate)
            var i1 = Int(((s0 + secondsPerStep) * rate).rounded(.up))
            i0 = min(max(i0, 0), peaks.count - 1)
            i1 = min(max(i1, i0 + 1), peaks.count)
            var peak: Float = 0
            for i in i0..<i1 where peaks[i] > peak { peak = peaks[i] }
            let fade = clip.fadeFactor(at: min(clip.start + offset, clip.end - 1e-6))
            amps.append(max(0.5, min(1, CGFloat(Double(peak) * gain * fade)) * (half - 0.5)))
            x += step
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: mid - amps[0]))
        for (i, a) in amps.enumerated().dropFirst() { path.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: mid - a)) }
        for (i, a) in amps.enumerated().reversed() { path.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: mid + a)) }
        path.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // MARK: - Drop preview

    private func drawDropPreview(_ preview: TimelineDropPreview, in ctx: CGContext) {
        let height = preview.trackKind == .video ? Theme.videoTrackHeight : Theme.audioTrackHeight
        var top: CGFloat
        var caption: String?
        if let id = preview.trackID, let row = rows.row(for: id) {
            top = viewY(row.y)
        } else if preview.trackKind == .video {
            top = viewY(TimelineMetrics.topPadding)
            caption = "New Video Track"
        } else {
            top = viewY(rows.tracksHeight + 4)
            caption = "New Audio Track"
        }
        if caption != nil {
            let lineY = preview.trackKind == .video ? top - 2 : top - 3
            ctx.setFillColor(TimelinePalette.accent)
            ctx.fill(CGRect(x: 0, y: lineY, width: bounds.width, height: 2))
        }
        top += TimelineMetrics.clipInset
        let h = height - 2 * TimelineMetrics.clipInset
        var t = preview.start
        for segment in preview.segments {
            let x0 = x(for: t), x1 = x(for: t + segment.duration)
            let r = CGRect(x: x0, y: top, width: max(4, x1 - x0), height: h)
            let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Theme.cornerRadius, cornerHeight: Theme.cornerRadius, transform: nil)
            ctx.setFillColor(TimelinePalette.accentFill)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(TimelinePalette.accent)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            (segment.title as NSString).draw(in: CGRect(x: r.minX + 7, y: r.minY + 3, width: max(0, r.width - 12), height: 15),
                                             withAttributes: TimelinePalette.clipLabel)
            t += segment.duration
        }
        if let caption {
            let x0 = x(for: preview.start)
            (caption as NSString).draw(at: CGPoint(x: x0 + 7, y: top + h - 16), withAttributes: TimelinePalette.clipDetail)
        }
        ctx.setFillColor(TimelinePalette.accent)
        ctx.fill(CGRect(x: x(for: preview.start).rounded() - 0.5, y: rulerHeight, width: 1.5, height: bounds.height - rulerHeight))
    }
}

extension CanvasHover {
    /// Clip the mouse is over, if any.
    var clipID: UUID? {
        switch self {
        case .clip(let id), .trim(let id, _), .fade(let id, _): id
        case .none, .scroller: nil
        }
    }
}
