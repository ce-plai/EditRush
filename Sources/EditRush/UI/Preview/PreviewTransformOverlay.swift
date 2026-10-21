import SwiftUI
import AppKit
import EditRushCore

/// Rush-style direct manipulation on the canvas: click to select the topmost visual clip,
/// drag to move, corner handles to scale uniformly, top handle to rotate (⇧ snaps to 15°),
/// with snapping guides to the canvas centre lines and edges (hold ⌘ to bypass snapping).
///
/// The body only derives two small frames from the store, so playhead ticks during playback
/// are cheap; drawing lives in an equatable child that redraws only when geometry changes.
struct PreviewTransformOverlay: View {
    @Environment(EditorStore.self) private var store
    let mapping: PreviewCanvasMapping

    @State private var tracker = PreviewDragTracker()
    @State private var guides = PreviewSnapGuides()
    @State private var readout: PreviewReadout?
    @State private var hoverClipID: UUID?
    @State private var pointerKind = PreviewPointer.arrow

    var body: some View {
        let t = store.playhead
        let selected = PreviewLayout.editableSelection(store: store, at: t)
        let selectionFrame = selected.flatMap { PreviewLayout.frame(of: $0.clip, in: store.project, mapping: mapping) }
        ZStack {
            PreviewTransformGraphic(
                mapping: mapping,
                selection: selectionFrame,
                selectionLocked: selected?.track.isLocked ?? false,
                hover: hoverFrame(excluding: selected?.clip.id, at: t),
                guides: guides,
                readout: readout
            )
            .equatable()
            .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onContinuousHover(coordinateSpace: .local, perform: hover)
                .pointerStyle(pointerKind.style)
        }
    }

    private func hoverFrame(excluding selectedID: UUID?, at t: Seconds) -> PreviewClipFrame? {
        guard let id = hoverClipID, id != selectedID,
              let loc = store.project.locate(clip: id) else { return nil }
        let track = store.project.tracks[loc.track]
        let clip = track.clips[loc.clip]
        guard !track.isHidden, clip.contains(t) else { return nil }
        return PreviewLayout.frame(of: clip, in: store.project, mapping: mapping)
    }

    // MARK: Hit testing

    private enum Region: Equatable {
        case rotate, corner(Int), body
    }

    private static let handleHitRadius: CGFloat = 9
    private static let rotateHitRadius: CGFloat = 11
    private static let snapThreshold: CGFloat = 6

    /// The selected clip's frame (if editable at the playhead) and which part of it is under `p`.
    private func selectionRegion(at p: CGPoint) -> (clip: Clip, track: Track, frame: PreviewClipFrame, region: Region)? {
        guard let sel = PreviewLayout.editableSelection(store: store, at: store.playhead),
              let frame = PreviewLayout.frame(of: sel.clip, in: store.project, mapping: mapping) else { return nil }
        if !sel.track.isLocked {
            if p.distance(to: frame.rotationHandle(distance: PreviewTransformGraphic.rotateHandleDistance)) <= Self.rotateHitRadius {
                return (sel.clip, sel.track, frame, .rotate)
            }
            let small = min(frame.size.width, frame.size.height) < Self.handleHitRadius * 3
            if !(small && frame.contains(p)) {
                for (i, c) in frame.corners.enumerated() where p.distance(to: c) <= Self.handleHitRadius {
                    return (sel.clip, sel.track, frame, .corner(i))
                }
            }
        }
        return frame.contains(p) ? (sel.clip, sel.track, frame, .body) : nil
    }

    /// Topmost visual clip active at the playhead under `p` (inside the canvas only).
    private func topmostClip(at p: CGPoint, preferText: Bool) -> (clip: Clip, track: Track, frame: PreviewClipFrame)? {
        guard mapping.viewRect.contains(p) else { return nil }
        var hits: [(clip: Clip, track: Track, frame: PreviewClipFrame)] = []
        for (clip, track) in PreviewLayout.activeVisualClips(in: store.project, at: store.playhead) {
            guard let f = PreviewLayout.frame(of: clip, in: store.project, mapping: mapping), f.contains(p) else { continue }
            if !preferText { return (clip, track, f) }
            hits.append((clip, track, f))
        }
        return hits.first { $0.clip.isText } ?? hits.first
    }

    private func pointer(for region: Region, frame: PreviewClipFrame, locked: Bool) -> PreviewPointer {
        if locked { return .arrow }
        switch region {
        case .rotate: return .rotate
        case .corner(let i): return .resize(PreviewPointer.resizeSector(angle: [-135, -45, 45, 135][i] + frame.rotation))
        case .body: return .grab
        }
    }

    // MARK: Hover

    private func hover(_ phase: HoverPhase) {
        guard tracker.session == nil else { return }
        switch phase {
        case .active(let p):
            if let hit = selectionRegion(at: p) {
                setPointer(pointer(for: hit.region, frame: hit.frame, locked: hit.track.isLocked))
                setHover(nil)
            } else {
                setPointer(.arrow)
                setHover(topmostClip(at: p, preferText: false)?.clip.id)
            }
        case .ended:
            setPointer(.arrow)
            setHover(nil)
        }
    }

    private func setPointer(_ p: PreviewPointer) {
        if pointerKind != p { pointerKind = p }
    }

    private func setHover(_ id: UUID?) {
        if hoverClipID != id { hoverClipID = id }
    }

    // MARK: Dragging

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if tracker.session?.startLocation != value.startLocation { begin(at: value.startLocation) }
                update(to: value.location)
            }
            .onEnded { value in
                finish(at: value.location)
            }
    }

    private func begin(at p: CGPoint) {
        if tracker.session?.didEdit == true { store.endCoalescing() }
        setHover(nil)
        let selectionHit = selectionRegion(at: p)

        // Double-click picks the topmost text clip under the cursor (the inspector edits it).
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2,
           let text = topmostClip(at: p, preferText: true), text.clip.isText, text.clip.id != selectionHit?.clip.id {
            startMove(text.clip, track: text.track, frame: text.frame, at: p, select: true)
            return
        }
        if let hit = selectionHit {
            let mode: PreviewDragSession.Mode
            switch hit.region {
            case .rotate: mode = .rotate
            case .corner: mode = .scale
            case .body: mode = .move
            }
            tracker.session = PreviewDragSession(mode: hit.track.isLocked ? .idle : mode, clipID: hit.clip.id, startLocation: p,
                                                 startTransform: hit.clip.transform, startFrame: hit.frame)
            if mode == .move, !hit.track.isLocked { setPointer(.grabbing) }
            return
        }
        if let hit = topmostClip(at: p, preferText: false) {
            startMove(hit.clip, track: hit.track, frame: hit.frame, at: p, select: true)
        } else {
            if !store.selection.isEmpty { store.selection = [] }
            tracker.session = PreviewDragSession(mode: .idle, clipID: nil, startLocation: p, startTransform: .identity, startFrame: nil)
        }
    }

    private func startMove(_ clip: Clip, track: Track, frame: PreviewClipFrame, at p: CGPoint, select: Bool) {
        if select, store.selection != [clip.id] { store.selection = [clip.id] }
        tracker.session = PreviewDragSession(mode: track.isLocked ? .idle : .move, clipID: clip.id, startLocation: p,
                                             startTransform: clip.transform, startFrame: frame)
        if !track.isLocked { setPointer(.grabbing) }
    }

    private func update(to p: CGPoint) {
        guard var session = tracker.session, let id = session.clipID, let startFrame = session.startFrame else { return }
        if !session.hasMoved {
            guard p.distance(to: session.startLocation) >= 2 else { return }
            session.hasMoved = true
        }
        let flags = NSEvent.modifierFlags
        let snapping = store.snappingEnabled && !flags.contains(.command)
        let start = session.startTransform
        let coalesceKey = "preview-transform-\(id.uuidString)"

        switch session.mode {
        case .idle:
            break

        case .move:
            var dx = p.x - session.startLocation.x, dy = p.y - session.startLocation.y
            var lockX = false, lockY = false
            if flags.contains(.shift) {
                if abs(dx) >= abs(dy) { dy = 0; lockY = true } else { dx = 0; lockX = true }
            }
            var newGuides = PreviewSnapGuides()
            if snapping {
                let b = startFrame.bounds.offsetBy(dx: dx, dy: dy)
                let vr = mapping.viewRect
                if !lockX, let s = Self.snap([b.minX, b.midX, b.maxX], to: [vr.minX, vr.midX, vr.maxX]) {
                    dx += s.adjust; newGuides.x = s.target
                }
                if !lockY, let s = Self.snap([b.minY, b.midY, b.maxY], to: [vr.minY, vr.midY, vr.maxY]) {
                    dy += s.adjust; newGuides.y = s.target
                }
            }
            let ox = start.offsetX + dx / mapping.viewRect.width
            let oy = start.offsetY + dy / mapping.viewRect.height
            if guides != newGuides { guides = newGuides }
            if readout != nil { readout = nil }
            store.updateClip(id, "Transform", coalesce: coalesceKey) { clip in
                clip.transform.offsetX = ox
                clip.transform.offsetY = oy
            }
            session.didEdit = true

        case .scale:
            let c = startFrame.center
            let d0 = session.startLocation.distance(to: c), d1 = p.distance(to: c)
            guard d0 > 1 else { break }
            var s = min(20, max(0.02, start.scale * d1 / d0))
            if snapping, start.scale > 0 {
                let unitHalfDiagonal = hypot(startFrame.size.width, startFrame.size.height) / 2 / start.scale
                if abs(s - 1) * unitHalfDiagonal < Self.snapThreshold { s = 1 }
            }
            readout = PreviewReadout(text: "\(Int((s * 100).rounded()))%", at: p)
            store.updateClip(id, "Transform", coalesce: coalesceKey) { $0.transform.scale = s }
            session.didEdit = true

        case .rotate:
            let c = startFrame.center
            let a0 = atan2(session.startLocation.y - c.y, session.startLocation.x - c.x)
            let a1 = atan2(p.y - c.y, p.x - c.x)
            var r = start.rotation + Double(a1 - a0) * 180 / .pi
            if flags.contains(.shift) {
                r = (r / 15).rounded() * 15
            } else if snapping {
                let right = (r / 90).rounded() * 90
                if abs(r - right) < 3 { r = right }
            }
            r = Self.normalizedDegrees(r)
            readout = PreviewReadout(text: "\(Int(r.rounded()))°", at: p)
            store.updateClip(id, "Transform", coalesce: coalesceKey) { $0.transform.rotation = r }
            session.didEdit = true
        }
        tracker.session = session
    }

    private func finish(at p: CGPoint) {
        if tracker.session?.didEdit == true { store.endCoalescing() }
        tracker.session = nil
        if guides != PreviewSnapGuides() { guides = PreviewSnapGuides() }
        if readout != nil { readout = nil }
        hover(.active(p))
    }

    /// Finds the candidate closest to a target within the snap threshold.
    private static func snap(_ candidates: [CGFloat], to targets: [CGFloat]) -> (adjust: CGFloat, target: CGFloat)? {
        var best: (adjust: CGFloat, target: CGFloat)?
        for target in targets {
            for c in candidates {
                let d = target - c
                if abs(d) <= snapThreshold, abs(d) < abs(best?.adjust ?? .infinity) { best = (d, target) }
            }
        }
        return best
    }

    private static func normalizedDegrees(_ r: Double) -> Double {
        var v = r.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v <= -180 { v += 360 }
        return v == 0 ? 0 : v
    }
}

// MARK: - Drag state

/// Holds the in-flight gesture outside SwiftUI state so drag events don't invalidate the view.
private final class PreviewDragTracker {
    var session: PreviewDragSession?
}

private struct PreviewDragSession {
    enum Mode: Equatable { case idle, move, scale, rotate }
    var mode: Mode
    var clipID: UUID?
    var startLocation: CGPoint
    var startTransform: ClipTransform
    var startFrame: PreviewClipFrame?
    var hasMoved = false
    var didEdit = false
}

/// Snapped guide positions in viewer points.
struct PreviewSnapGuides: Equatable {
    var x: CGFloat?
    var y: CGFloat?
}

/// Live value shown next to the cursor while scaling / rotating.
struct PreviewReadout: Equatable {
    var text: String
    var at: CGPoint
}

// MARK: - Drawing

/// Draws the hover outline, the selection box with handles, snapping guides and the readout.
struct PreviewTransformGraphic: View, Equatable {
    var mapping: PreviewCanvasMapping
    var selection: PreviewClipFrame?
    var selectionLocked: Bool
    var hover: PreviewClipFrame?
    var guides: PreviewSnapGuides
    var readout: PreviewReadout?

    static let rotateHandleDistance: CGFloat = 22
    private static let guideColor = Color(red: 1.0, green: 0.32, blue: 0.78)

    var body: some View {
        Canvas { ctx, _ in
            let vr = mapping.viewRect
            if let x = guides.x {
                var p = Path()
                p.move(to: CGPoint(x: x, y: vr.minY)); p.addLine(to: CGPoint(x: x, y: vr.maxY))
                ctx.stroke(p, with: .color(Self.guideColor), lineWidth: 1)
            }
            if let y = guides.y {
                var p = Path()
                p.move(to: CGPoint(x: vr.minX, y: y)); p.addLine(to: CGPoint(x: vr.maxX, y: y))
                ctx.stroke(p, with: .color(Self.guideColor), lineWidth: 1)
            }

            if let hover {
                ctx.stroke(hover.path, with: .color(Theme.accent.opacity(0.85)), lineWidth: 1)
            }

            if let frame = selection {
                drawSelection(frame, in: &ctx)
            }

            if let readout {
                let text = ctx.resolve(Text(readout.text).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white))
                let size = text.measure(in: CGSize(width: 200, height: 40))
                let box = CGRect(x: readout.at.x + 14, y: readout.at.y + 16, width: size.width + 14, height: size.height + 6)
                ctx.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Color.black.opacity(0.72)))
                ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }
        }
    }

    private func drawSelection(_ frame: PreviewClipFrame, in ctx: inout GraphicsContext) {
        let outline = frame.path
        ctx.stroke(outline, with: .color(Color.black.opacity(0.35)), lineWidth: 3)
        if selectionLocked {
            ctx.stroke(outline, with: .color(Color.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            var lock = ctx.resolve(Image(systemName: "lock.fill"))
            lock.shading = .color(.white)
            ctx.draw(lock, at: frame.point(local: CGPoint(x: -frame.size.width / 2 + 12, y: -frame.size.height / 2 + 12)), anchor: .center)
            return
        }
        ctx.stroke(outline, with: .color(Theme.accent), lineWidth: 1.5)

        let top = frame.topMid()
        let knob = frame.rotationHandle(distance: Self.rotateHandleDistance)
        var stem = Path()
        stem.move(to: top); stem.addLine(to: knob)
        ctx.stroke(stem, with: .color(Theme.accent), lineWidth: 1.5)
        drawKnob(at: knob, radius: 5.5, in: &ctx)

        for c in frame.corners {
            drawKnob(at: c, radius: 5, in: &ctx)
        }
    }

    private func drawKnob(at p: CGPoint, radius r: CGFloat, in ctx: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1))
        shadowed.fill(circle, with: .color(.white))
        ctx.stroke(circle, with: .color(Theme.accent), lineWidth: 1.5)
    }
}

// MARK: - Cursors

/// Pointer shown over the canvas; Equatable so hover only updates state when it changes.
enum PreviewPointer: Equatable {
    case arrow, grab, grabbing, rotate
    /// One of eight directions, 0 = right, clockwise in 45° steps.
    case resize(Int)

    /// Sector index for a handle whose outward direction is `angle` degrees (0 = right, 90 = down).
    static func resizeSector(angle: Double) -> Int {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45) % 8
    }

    @MainActor var style: PointerStyle? {
        switch self {
        case .arrow: nil
        case .grab: .grabIdle
        case .grabbing: .grabActive
        case .rotate: Self.rotateStyle
        case .resize(let sector):
            .frameResize(position: [.trailing, .bottomTrailing, .bottom, .bottomLeading,
                                    .leading, .topLeading, .top, .topTrailing][sector % 8])
        }
    }

    /// Curved-arrow cursor (white glyph with a dark halo so it reads on any footage).
    @MainActor private static let rotateStyle: PointerStyle = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            guard let halo = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
                    .withSymbolConfiguration(base.applying(.init(paletteColors: [.black]))),
                  let glyph = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
                    .withSymbolConfiguration(base.applying(.init(paletteColors: [.white]))) else { return false }
            let g = glyph.size
            let origin = NSPoint(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2)
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    halo.draw(in: NSRect(origin: NSPoint(x: origin.x + dx, y: origin.y + dy), size: g))
                }
            }
            glyph.draw(in: NSRect(origin: origin, size: g))
            return true
        }
        return .image(Image(nsImage: image), hotSpot: .center)
    }()
}

extension CGPoint {
    fileprivate func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
