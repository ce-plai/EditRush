import AppKit
import EditRushCore

/// In-progress mouse gesture on the timeline canvas.
enum CanvasDrag {
    case none
    case scrub
    case move(TimelineMoveDrag)
    case trim(TimelineTrimDrag)
    case fade(TimelineFadeDrag)
    case marquee(TimelineMarquee)
    case scroller(TimelineScrollerDrag)

    var isActive: Bool { if case .none = self { false } else { true } }
    var isScrubbing: Bool { if case .scrub = self { true } else { false } }
}

struct TimelineMoveDrag {
    struct Item {
        let id: UUID
        let trackID: UUID
        let start: Seconds
        let duration: Seconds
        let kind: MediaKind?
    }
    let anchor: Item
    /// All clips being moved (includes the anchor).
    let items: [Item]
    let downPoint: CGPoint
    let downTime: Seconds
    let coalesceKey: String
    /// Mouse-down on an already-selected clip of a multi-selection: a plain click (no drag)
    /// collapses the selection to that clip on mouse-up.
    let collapseOnClick: Bool
    var started = false
    var applied: (delta: Seconds, trackID: UUID)?
}

struct TimelineTrimDrag {
    let clipID: UUID
    let edge: TrimEdge
    let originalEdge: Seconds
    let downTime: Seconds
    let coalesceKey: String
    var lastApplied: Seconds?
}

struct TimelineFadeDrag {
    let clipID: UUID
    let isFadeIn: Bool
    let coalesceKey: String
}

struct TimelineMarquee {
    /// Anchor and current corners in (time, content y) so autoscroll keeps them stable.
    var origin: (time: Seconds, y: CGFloat)
    var current: (time: Seconds, y: CGFloat)
    let base: Set<UUID>
}

struct TimelineScrollerDrag {
    let horizontal: Bool
    /// Offset of the mouse inside the knob at mouse-down.
    let grabOffset: CGFloat
}

/// What the mouse is over (drives cursors, hover highlight and fade handles).
enum CanvasHover: Equatable {
    case none
    case clip(UUID)
    case trim(UUID, TrimEdge)
    case fade(UUID, isFadeIn: Bool)
    case scroller
}

/// A clip under the mouse.
struct TimelineClipHit {
    let clip: Clip
    let track: Track
    let row: TimelineRow
    let rect: CGRect
    let edge: TrimEdge?
    /// Non-nil when the point is on a fade handle (true = fade in).
    let fadeHandle: Bool?
}

extension TimelineCanvasView {
    // MARK: - Hit testing

    func hitClip(at p: CGPoint, includeFadeHandles: Bool = true) -> TimelineClipHit? {
        guard let row = row(atViewY: p.y), let track = track(row.trackID) else { return nil }
        let t = rawTime(atX: p.x)
        let slop = Seconds(2 / pps)
        // Prefer the clip under the pointer; the slop only helps grab edges from just outside.
        guard let clip = track.clips.first(where: { $0.contains(t) })
                ?? track.clips.first(where: { t >= $0.start - slop && t < $0.end + slop }) else { return nil }
        let rect = clipRect(clip, in: row)
        guard rect.insetBy(dx: -2, dy: 0).contains(p) else { return nil }
        if includeFadeHandles, showsFadeHandles(for: clip, rect: rect) {
            for isIn in [true, false] where fadeHandleCenter(for: clip, rect: rect, fadeIn: isIn).distance(to: p) <= 7 {
                return TimelineClipHit(clip: clip, track: track, row: row, rect: rect, edge: nil, fadeHandle: isIn)
            }
        }
        let handle = min(TimelineMetrics.trimHandleWidth, rect.width / 3)
        var edge: TrimEdge?
        if p.x - rect.minX <= handle { edge = .leading } else if rect.maxX - p.x <= handle { edge = .trailing }
        return TimelineClipHit(clip: clip, track: track, row: row, rect: rect, edge: edge, fadeHandle: nil)
    }

    /// Fade handles are shown on hovered or selected clips that are wide enough.
    func showsFadeHandles(for clip: Clip, rect: CGRect) -> Bool {
        guard rect.width >= 56 else { return false }
        switch hover {
        case .clip(let id), .trim(let id, _), .fade(let id, _): if id == clip.id { return true }
        default: break
        }
        if case .fade(let f) = drag, f.clipID == clip.id { return true }
        return store.selection.contains(clip.id)
    }

    func fadeHandleCenter(for clip: Clip, rect: CGRect, fadeIn: Bool) -> CGPoint {
        let inset: CGFloat = 11
        let y = rect.minY + 6
        if fadeIn {
            return CGPoint(x: min(rect.maxX - inset, max(rect.minX + inset, x(for: clip.start + clip.fadeIn))), y: y)
        }
        return CGPoint(x: max(rect.minX + inset, min(rect.maxX - inset, x(for: clip.end - clip.fadeOut))), y: y)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        endTextEditing()
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        snapGuide = nil

        if let scrollerDrag = beginScrollerDrag(at: p) {
            drag = .scroller(scrollerDrag)
            return
        }
        if p.y < rulerHeight {
            drag = .scrub
            scrub(toX: p.x, precise: false)
            return
        }

        let mods = event.modifierFlags
        let toggle = mods.contains(.shift) || mods.contains(.command)
        guard let hit = hitClip(at: p) else {
            let origin = (time: rawTime(atX: p.x), y: contentY(p.y))
            let base = toggle ? store.selection : []
            if !toggle, !store.selection.isEmpty { store.selection = [] }
            drag = .marquee(TimelineMarquee(origin: origin, current: origin, base: base))
            return
        }

        let id = hit.clip.id
        if event.clickCount == 2 {
            let t = min(max(rawTime(atX: p.x), hit.clip.start), max(hit.clip.start, hit.clip.end - store.frameDuration))
            playback.seek(to: t, precise: true)
            drag = .none
            return
        }
        let locked = hit.track.isLocked
        if let isFadeIn = hit.fadeHandle, !locked {
            if !store.selection.contains(id) { store.selection = [id] }
            drag = .fade(TimelineFadeDrag(clipID: id, isFadeIn: isFadeIn, coalesceKey: "timeline-fade-\(UUID())"))
            store.endCoalescing()
            return
        }
        if let edge = hit.edge, !locked, !toggle {
            if !store.selection.contains(id) { store.selection = [id] }
            let original = edge == .leading ? hit.clip.start : hit.clip.end
            drag = .trim(TimelineTrimDrag(clipID: id, edge: edge, originalEdge: original, downTime: rawTime(atX: p.x),
                                          coalesceKey: "timeline-trim-\(UUID())"))
            store.endCoalescing()
            return
        }

        var collapse = false
        if toggle {
            if store.selection.contains(id) {
                store.selection.remove(id)
                drag = .none
                return
            }
            store.selection.insert(id)
        } else if !store.selection.contains(id) {
            store.selection = [id]
        } else {
            collapse = store.selection.count > 1
        }
        guard !locked else { drag = .none; return }
        drag = .move(makeMoveDrag(anchor: hit, at: p, collapseOnClick: collapse))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        continueDrag(at: p)
        updateAutoscroll(for: p)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        stopAutoscroll()
        switch drag {
        case .scrub:
            scrub(toX: p.x, precise: true)
        case .move(let m):
            if m.started { store.endCoalescing() } else if m.collapseOnClick { store.selection = [m.anchor.id] }
        case .trim, .fade:
            store.endCoalescing()
        case .marquee, .scroller, .none:
            break
        }
        drag = .none
        lastDragPoint = nil
        snapGuide = nil
        needsDisplay = true
        updateHover(at: p)
    }

    /// Re-applies the current gesture for mouse location `p` (also used by autoscroll).
    func continueDrag(at p: CGPoint) {
        switch drag {
        case .none:
            break
        case .scrub:
            scrub(toX: p.x, precise: false)
        case .move(var m):
            if !m.started {
                guard hypot(p.x - m.downPoint.x, p.y - m.downPoint.y) >= 3 else { return }
                m.started = true
            }
            updateMove(&m, at: p)
            drag = .move(m)
        case .trim(var t):
            updateTrim(&t, at: p)
            drag = .trim(t)
        case .fade(let f):
            updateFade(f, at: p)
        case .marquee(var mq):
            mq.current = (time: rawTime(atX: p.x), y: contentY(p.y))
            drag = .marquee(mq)
            applyMarquee(mq)
            needsDisplay = true
        case .scroller(let s):
            dragScroller(s, to: p)
        }
    }

    // MARK: - Scrubbing

    private func scrub(toX x: CGFloat, precise: Bool) {
        var t = time(atX: x)
        var guide: Seconds?
        if store.snappingEnabled {
            let current = store.playhead
            let threshold = Seconds(TimelineMetrics.snapDistance / pps)
            if let nearest = store.snapTargets().filter({ abs($0 - current) > 1e-9 }).min(by: { abs($0 - t) < abs($1 - t) }),
               abs(nearest - t) <= threshold {
                t = nearest
                guide = nearest
            }
        }
        setSnapGuide(precise ? nil : guide)
        playback.seek(to: t, precise: precise)
    }

    private func setSnapGuide(_ t: Seconds?) {
        guard snapGuide != t else { return }
        snapGuide = t
        needsDisplay = true
    }

    // MARK: - Move

    private func makeMoveDrag(anchor hit: TimelineClipHit, at p: CGPoint, collapseOnClick: Bool) -> TimelineMoveDrag {
        let project = store.project
        var items: [TimelineMoveDrag.Item] = []
        for track in project.tracks where !track.isLocked {
            for clip in track.clips where store.selection.contains(clip.id) {
                items.append(.init(id: clip.id, trackID: track.id, start: clip.start, duration: clip.duration, kind: contentKind(of: clip)))
            }
        }
        let anchor = TimelineMoveDrag.Item(id: hit.clip.id, trackID: hit.track.id, start: hit.clip.start,
                                           duration: hit.clip.duration, kind: contentKind(of: hit.clip))
        if !items.contains(where: { $0.id == anchor.id }) { items.append(anchor) }
        return TimelineMoveDrag(anchor: anchor, items: items, downPoint: p, downTime: rawTime(atX: p.x),
                                coalesceKey: "timeline-move-\(UUID())", collapseOnClick: collapseOnClick)
    }

    private func updateMove(_ m: inout TimelineMoveDrag, at p: CGPoint) {
        let minStart = m.items.map(\.start).min() ?? 0
        var delta = max(rawTime(atX: p.x) - m.downTime, -minStart)
        let moving = Set(m.items.map(\.id))
        let threshold = Seconds(TimelineMetrics.snapDistance / pps)
        let aStart = m.anchor.start + delta, aEnd = aStart + m.anchor.duration
        let d1 = store.snap(aStart, excluding: moving, thresholdSeconds: threshold) - aStart
        let d2 = store.snap(aEnd, excluding: moving, thresholdSeconds: threshold) - aEnd
        var guide: Seconds?
        if d1 != 0, d2 == 0 || abs(d1) <= abs(d2) {
            delta += d1; guide = aStart + d1
        } else if d2 != 0 {
            delta += d2; guide = aEnd + d2
        } else {
            delta = store.project.canvas.quantize(delta)
        }
        delta = max(delta, -minStart)

        var targetTrack = m.applied?.trackID ?? m.anchor.trackID
        if m.items.count == 1,
           let row = row(atViewY: min(max(p.y, rulerHeight), bounds.height - 1)),
           let track = track(row.trackID), !track.isLocked, track.accepts(m.anchor.kind) {
            targetTrack = row.trackID
        }
        setSnapGuide(guide)
        if let applied = m.applied, applied.delta == delta, applied.trackID == targetTrack { return }

        // Move the leading clips first so selected clips never collide with each other.
        let movingRight = delta >= (m.applied?.delta ?? 0)
        let ordered = m.items.sorted { movingRight ? $0.start > $1.start : $0.start < $1.start }
        for item in ordered {
            let trackID = m.items.count == 1 ? targetTrack : item.trackID
            store.moveClip(item.id, toTrack: trackID, start: item.start + delta, coalesce: m.coalesceKey)
        }
        m.applied = (delta, targetTrack)
    }

    // MARK: - Trim & fades

    private func updateTrim(_ t: inout TimelineTrimDrag, at p: CGPoint) {
        let raw = max(0, t.originalEdge + rawTime(atX: p.x) - t.downTime)
        let threshold = Seconds(TimelineMetrics.snapDistance / pps)
        let snapped = store.snap(raw, excluding: [t.clipID], thresholdSeconds: threshold)
        setSnapGuide(snapped != raw ? snapped : nil)
        let target = snapped != raw ? snapped : store.project.canvas.quantize(raw)
        guard t.lastApplied != target else { return }
        t.lastApplied = target
        store.trimClip(t.clipID, edge: t.edge, to: target, coalesce: t.coalesceKey)
    }

    private func updateFade(_ f: TimelineFadeDrag, at p: CGPoint) {
        guard let clip = store.clip(f.clipID) else { return }
        let t = rawTime(atX: p.x)
        let canvas = store.project.canvas
        if f.isFadeIn {
            let value = canvas.quantize(min(max(0, t - clip.start), clip.duration - clip.fadeOut))
            guard value != clip.fadeIn else { return }
            store.updateClip(f.clipID, "Fade In", coalesce: f.coalesceKey) { $0.fadeIn = max(0, value) }
        } else {
            let value = canvas.quantize(min(max(0, clip.end - t), clip.duration - clip.fadeIn))
            guard value != clip.fadeOut else { return }
            store.updateClip(f.clipID, "Fade Out", coalesce: f.coalesceKey) { $0.fadeOut = max(0, value) }
        }
        needsDisplay = true
    }

    // MARK: - Marquee

    private func applyMarquee(_ mq: TimelineMarquee) {
        let t0 = min(mq.origin.time, mq.current.time), t1 = max(mq.origin.time, mq.current.time)
        let y0 = min(mq.origin.y, mq.current.y), y1 = max(mq.origin.y, mq.current.y)
        var selection = mq.base
        if t1 - t0 > 0 || y1 - y0 > 0 {
            for row in rows.rows where row.maxY - TimelineMetrics.clipInset > y0 && row.y + TimelineMetrics.clipInset < y1 {
                guard let track = track(row.trackID) else { continue }
                for clip in track.clips where clip.end > t0 && clip.start < t1 { selection.insert(clip.id) }
            }
        }
        if selection != store.selection { store.selection = selection }
    }

    /// Marquee rectangle in view coordinates.
    func marqueeRect(_ mq: TimelineMarquee) -> CGRect {
        let a = CGPoint(x: x(for: mq.origin.time), y: viewY(mq.origin.y))
        let b = CGPoint(x: x(for: mq.current.time), y: viewY(mq.current.y))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Scrollers

    /// Horizontal scroller track and knob rects (nil when nothing to scroll).
    func horizontalScroller() -> (track: CGRect, knob: CGRect)? {
        guard maxScrollX > 0.5 else { return nil }
        let thickness = TimelineMetrics.scrollerThickness
        let trailing = hasVerticalOverflow ? thickness + 2 : 0
        let track = CGRect(x: 4, y: bounds.height - thickness - 2, width: bounds.width - 8 - trailing, height: thickness)
        let knobW = max(36, track.width * bounds.width / contentWidth)
        let knobX = track.minX + (track.width - knobW) * scrollX / maxScrollX
        return (track, CGRect(x: knobX, y: track.minY, width: knobW, height: thickness))
    }

    /// Vertical scroller track and knob rects (nil when nothing to scroll).
    func verticalScroller() -> (track: CGRect, knob: CGRect)? {
        guard hasVerticalOverflow else { return nil }
        let thickness = TimelineMetrics.scrollerThickness
        let bottom = maxScrollX > 0.5 ? thickness + 4 : 2
        let track = CGRect(x: bounds.width - thickness - 2, y: rulerHeight + 2, width: thickness,
                           height: max(0, bounds.height - rulerHeight - 2 - bottom))
        let knobH = max(24, track.height * trackViewportHeight / rows.contentHeight)
        let knobY = track.minY + (track.height - knobH) * shared.offsetY / maxScrollY
        return (track, CGRect(x: track.minX, y: knobY, width: thickness, height: knobH))
    }

    private func beginScrollerDrag(at p: CGPoint) -> TimelineScrollerDrag? {
        if let h = horizontalScroller(), h.track.insetBy(dx: 0, dy: -2).contains(p) {
            if !h.knob.contains(p) {
                // Jump so the knob centres on the click, then drag from its middle.
                scroll(byX: (p.x - h.knob.midX) * contentWidth / h.track.width, y: 0)
                return TimelineScrollerDrag(horizontal: true, grabOffset: (horizontalScroller()?.knob.width ?? 0) / 2)
            }
            return TimelineScrollerDrag(horizontal: true, grabOffset: p.x - h.knob.minX)
        }
        if let v = verticalScroller(), v.track.insetBy(dx: -2, dy: 0).contains(p) {
            if !v.knob.contains(p) {
                scroll(byX: 0, y: (p.y - v.knob.midY) * rows.contentHeight / v.track.height)
                return TimelineScrollerDrag(horizontal: false, grabOffset: (verticalScroller()?.knob.height ?? 0) / 2)
            }
            return TimelineScrollerDrag(horizontal: false, grabOffset: p.y - v.knob.minY)
        }
        return nil
    }

    private func dragScroller(_ s: TimelineScrollerDrag, to p: CGPoint) {
        if s.horizontal, let h = horizontalScroller() {
            let span = h.track.width - h.knob.width
            guard span > 0 else { return }
            let fraction = (p.x - s.grabOffset - h.track.minX) / span
            scroll(byX: fraction * maxScrollX - scrollX, y: 0)
        } else if !s.horizontal, let v = verticalScroller() {
            let span = v.track.height - v.knob.height
            guard span > 0 else { return }
            let fraction = (p.y - s.grabOffset - v.track.minY) / span
            scroll(byX: 0, y: fraction * maxScrollY - shared.offsetY)
        }
    }

    // MARK: - Autoscroll while dragging near the edges

    private func autoscrollVelocity(for p: CGPoint) -> CGVector {
        let edge: CGFloat = 24
        var v = CGVector.zero
        switch drag {
        case .scrub, .move, .trim, .fade, .marquee: break
        default: return v
        }
        if p.x < edge { v.dx = -(edge - p.x) } else if p.x > bounds.width - edge { v.dx = p.x - (bounds.width - edge) }
        if !drag.isScrubbing {
            if p.y < rulerHeight + 8 && p.y > 0 { v.dy = -(rulerHeight + 8 - p.y) / 2 } else if p.y > bounds.height - 12 { v.dy = (p.y - bounds.height + 12) / 2 }
        }
        return CGVector(dx: max(-60, min(60, v.dx * 0.6)), dy: max(-20, min(20, v.dy)))
    }

    private func updateAutoscroll(for p: CGPoint) {
        let v = autoscrollVelocity(for: p)
        if v == .zero { stopAutoscroll(); return }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let last = self.lastDragPoint else { return }
                let v = self.autoscrollVelocity(for: last)
                guard v != .zero else { self.stopAutoscroll(); return }
                self.scroll(byX: v.dx, y: v.dy)
                self.continueDrag(at: last)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: - Hover & cursor

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard !drag.isActive else { return }
        if hover != .none { hover = .none; needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(for: hover).set()
    }

    func updateHover(at p: CGPoint) {
        guard !drag.isActive else { return }
        var h = CanvasHover.none
        if horizontalScroller()?.track.contains(p) == true || verticalScroller()?.track.contains(p) == true {
            h = .scroller
        } else if let hit = hitClip(at: p) {
            if let isIn = hit.fadeHandle {
                h = .fade(hit.clip.id, isFadeIn: isIn)
            } else if let edge = hit.edge, !hit.track.isLocked {
                h = .trim(hit.clip.id, edge)
            } else {
                h = .clip(hit.clip.id)
            }
        }
        if h != hover {
            hover = h
            needsDisplay = true
        }
        cursor(for: h).set()
    }

    private func cursor(for hover: CanvasHover) -> NSCursor {
        switch hover {
        case .trim(_, .leading): NSCursor.frameResize(position: .left, directions: .all)
        case .trim(_, .trailing): NSCursor.frameResize(position: .right, directions: .all)
        case .fade: NSCursor.pointingHand
        default: NSCursor.arrow
        }
    }

    // MARK: - Context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y >= rulerHeight else { return nil }
        if let hit = hitClip(at: p, includeFadeHandles: false) {
            if !store.selection.contains(hit.clip.id) { store.selection = [hit.clip.id] }
            return clipMenu()
        }
        return emptyAreaMenu(time: time(atX: p.x), row: row(atViewY: p.y))
    }

    private func clipMenu() -> NSMenu {
        let store = self.store
        let menu = TimelineMenu()
        let selected = store.selectedClips
        let playhead = store.playhead
        let canSplit = selected.contains { playhead > $0.start + store.frameDuration / 2 && playhead < $0.end - store.frameDuration / 2 }
        menu.add("Split at Playhead", key: "b", enabled: canSplit) { store.splitAtPlayhead() }
        menu.addSeparator()
        menu.add("Duplicate", key: "d") { store.duplicateSelection() }
        menu.add("Join Clips", key: "j", enabled: store.canJoinSelection) { store.joinSelection() }
        let detachable = selected.filter(canDetachAudio)
        if !detachable.isEmpty {
            menu.add(detachable.count > 1 ? "Detach Audio (\(detachable.count) clips)" : "Detach Audio") {
                for clip in detachable { store.detachAudio(clip.id) }
            }
        }
        menu.addSeparator()
        menu.add("Fade In 0.5s") { store.setFades(in: 0.5, out: nil) }
        menu.add("Fade In 1s") { store.setFades(in: 1, out: nil) }
        menu.add("Fade Out 0.5s") { store.setFades(in: nil, out: 0.5) }
        menu.add("Fade Out 1s") { store.setFades(in: nil, out: 1) }
        let hasFades = selected.contains { $0.fadeIn > 0 || $0.fadeOut > 0 }
        menu.add("Remove Fades", enabled: hasFades) { store.setFades(in: 0, out: 0) }
        menu.addSeparator()
        menu.add("Delete", key: "\u{8}", modifiers: []) { store.deleteSelection(ripple: false) }
        menu.add("Ripple Delete", key: "\u{8}", modifiers: [.shift]) { store.deleteSelection(ripple: true) }
        return menu
    }

    private func emptyAreaMenu(time: Seconds, row: TimelineRow?) -> NSMenu {
        let store = self.store
        let menu = TimelineMenu()
        let titleTrack = row.flatMap { $0.kind == .video && !$0.isLocked ? $0.trackID : nil }
        menu.add("Add Title Here", key: "t") { store.addTextClip(at: store.project.canvas.quantize(time), trackID: titleTrack) }
        menu.add("Paste at Playhead", key: "v", enabled: store.canPaste) { store.pasteAtPlayhead() }
        menu.add("Close Gaps") { store.closeGaps() }
        menu.add("Select All", key: "a") { store.selectAll() }
        menu.addSeparator()
        menu.add("Add Video Track") { store.addTrack(.video) }
        menu.add("Add Audio Track") { store.addTrack(.audio) }
        if let row {
            menu.addSeparator()
            menu.add("Remove Track \(row.name)") { store.removeTrack(row.trackID) }
        }
        return menu
    }

    /// True for a video clip whose embedded audio is still attached.
    func canDetachAudio(_ clip: Clip) -> Bool {
        guard !clip.audioMuted, let media = mediaIndex[clip.mediaID ?? UUID()] else { return false }
        return media.kind == .video && media.hasAudio
    }

    private func endTextEditing() {
        if let window, window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
    }
}

/// Context menu whose items run closures.
final class TimelineMenu: NSMenu {
    init() {
        super.init(title: "")
        autoenablesItems = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true,
             action: @escaping @MainActor () -> Void) {
        let item = TimelineMenuItem(title: title, handler: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.isEnabled = enabled
        addItem(item)
    }

    func addSeparator() { addItem(.separator()) }
}

private final class TimelineMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
