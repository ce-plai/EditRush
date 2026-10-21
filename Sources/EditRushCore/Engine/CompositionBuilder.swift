import AVFoundation
import CoreImage

/// Everything AVFoundation needs to play or export a project.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let duration: Seconds
    /// Names of media that could not be loaded; their clips are left out of the composition.
    public let missingMedia: [String]
    /// Render size multiplier the video composition was built with.
    public let renderScale: Double
    /// Track layout the composition was built from (equal plans ⇒ the composition is reusable).
    let plan: CompositionPlan

    /// True when this result reuses `other`'s AVComposition (only the video composition and
    /// audio mix differ), i.e. a player item for `other` can be updated in place.
    public func sharesComposition(with other: BuiltComposition) -> Bool {
        composition === other.composition
    }
}

/// Turns a `Project` into AVFoundation objects.
///
/// Design:
/// * One video composition track per timeline video track (for video-file clips), one audio
///   composition track per timeline track that carries sound (audio tracks + video clips' audio),
///   plus a "boost" audio track duplicating clips whose volume exceeds 1 (AVAudioMix clamps
///   volume to 1, so gain above unity comes from summing a second copy at `volume − 1`).
/// * A blank "base" video track spanning [0, duration] so the custom compositor is invoked for
///   every frame even when only images/text are present (see `BlankVideo`).
/// * Segmented `CompositorInstruction`s (split at every clip boundary) carrying a render snapshot:
///   canvas, background, and the ordered active layers with timing, transform, color, filter, fades.
/// * `VideoCompositor` (AVVideoCompositing) renders those layers with Core Image on Metal.
/// * AVMutableAudioMix with per-clip volume and fade ramps.
public enum CompositionBuilder {
    /// CMTime timescale used for every edit.
    public static let timescale: CMTimeScale = 600
    static let baseTrackID: CMPersistentTrackID = 1

    /// - Parameter renderScale: multiplier on canvas size for the render size (preview may use < 1).
    public static func build(project: Project, assets: AssetCache, renderScale: Double = 1) async throws -> BuiltComposition {
        try await build(project: project, assets: assets, renderScale: renderScale, reusing: nil)
    }

    /// Like `build(project:assets:renderScale:)`, but reuses `previous.composition` when the
    /// project's track structure (media, clip timing, track layout) is unchanged, so only the
    /// video composition and audio mix are rebuilt.
    public static func build(project: Project, assets: AssetCache, renderScale: Double,
                             reusing previous: BuiltComposition?) async throws -> BuiltComposition {
        let media = await loadMedia(for: project, assets: assets, renderScale: renderScale)
        let plan = makePlan(project: project, media: media)
        let composition: AVComposition
        if let previous, previous.plan == plan {
            composition = previous.composition
        } else {
            composition = try await makeComposition(plan: plan, loaded: media.loaded)
        }
        let videoComposition = makeVideoComposition(project: project, plan: plan, media: media, renderScale: renderScale)
        let audioMix = makeAudioMix(project: project, plan: plan)
        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                                duration: Double(plan.total) / Double(timescale), missingMedia: media.missing,
                                renderScale: renderScale, plan: plan)
    }

    // MARK: - Time helpers

    static func ticks(_ s: Seconds) -> Int64 { Int64((s * Double(timescale)).rounded()) }
    static func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: timescale) }

    /// Exact frame duration for common rates (integer and NTSC 1000/1001 rates).
    public static func frameDuration(for fps: Double) -> CMTime {
        let rate = max(1, fps)
        let rounded = rate.rounded()
        if abs(rate - rounded) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(rounded)) }
        let ntsc = (rate * 1001 / 1000).rounded()
        if abs(rate - ntsc * 1000 / 1001) < 0.001 { return CMTime(value: 1001, timescale: CMTimeScale(ntsc * 1000)) }
        return CMTime(seconds: 1 / rate, preferredTimescale: 90000)
    }

    /// Canvas size × scale rounded to even integers (≥ 2).
    public static func renderSize(for canvas: CanvasSettings, scale: Double) -> CGSize {
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(Double(canvas.width) * scale), height: even(Double(canvas.height) * scale))
    }

    // MARK: - Media

    private struct LoadedMedia {
        /// The project's media by id.
        var items: [UUID: MediaItem] = [:]
        var loaded: [UUID: LoadedAsset] = [:]
        /// Decoded stills for image clips on visible video tracks.
        var stills: [UUID: CIImage] = [:]
        /// Names of media that could not be loaded or decoded, sorted.
        var missing: [String] = []
    }

    /// Loads every AV asset the timeline uses and decodes its visible stills at the size they
    /// are displayed at, all concurrently.
    private static func loadMedia(for project: Project, assets: AssetCache, renderScale: Double) async -> LoadedMedia {
        let canvas = project.canvas.size
        var result = LoadedMedia()
        result.items = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var needed: [UUID: MediaItem] = [:]
        var stillRequests: [AssetCache.StillRequest] = []
        var hiddenStills: [UUID: MediaItem] = [:]
        for track in project.tracks {
            for clip in track.clips {
                guard let media = clip.mediaID.flatMap({ result.items[$0] }) else { continue }
                guard media.kind == .image else { needed[media.id] = media; continue }
                guard track.kind == .video, clip.text == nil else { continue }
                guard !track.isHidden else { hiddenStills[media.id] = media; continue }
                let base = ClipGeometry.baseSize(content: media.pixelSize, canvas: canvas, fit: clip.transform.fitMode)
                let longSide = max(base.width, base.height) * max(0, clip.transform.scale) * max(0, renderScale)
                stillRequests.append(.init(media: media, displayLongSide: Double(longSide)))
            }
        }
        var pending: [MediaItem] = []
        for media in needed.values {
            if let done = assets.cachedLoaded(for: media) { result.loaded[media.id] = done } else { pending.append(media) }
        }
        let requests = stillRequests
        async let stills = assets.images(for: requests)
        if !pending.isEmpty {
            await withTaskGroup(of: (MediaItem, LoadedAsset?).self) { group in
                for media in pending {
                    group.addTask { (media, try? await assets.loaded(for: media)) }
                }
                for await (media, loaded) in group {
                    if let loaded { result.loaded[media.id] = loaded } else { result.missing.append(media.name) }
                }
            }
        }
        result.stills = await stills
        var missingStills = Set<UUID>()
        for r in requests where result.stills[r.media.id] == nil && missingStills.insert(r.media.id).inserted {
            result.missing.append(r.media.name)
        }
        for media in hiddenStills.values where result.stills[media.id] == nil && !missingStills.contains(media.id) {
            if !FileManager.default.fileExists(atPath: media.url.path) { result.missing.append(media.name) }
        }
        result.missing.sort()
        return result
    }

    // MARK: - Plan

    private static func makePlan(project: Project, media items: LoadedMedia) -> CompositionPlan {
        let loaded = items.loaded
        let frameTicks = max(1, ticks(project.canvas.frameDuration))
        var plan = CompositionPlan(total: max(frameTicks, ticks(project.duration)), tracks: [], missing: items.missing,
                                   canvas: project.canvas)
        var nextID = baseTrackID + 1

        for track in project.tracks where track.kind == .video && !track.isHidden {
            let segments = track.clips.compactMap { clip -> CompositionPlan.Segment? in
                guard let media = clip.mediaID.flatMap({ items.items[$0] }), media.kind == .video,
                      let asset = loaded[media.id], asset.videoTrack != nil else { return nil }
                return segment(for: clip, media: media, available: asset.videoTimeRange, holdLastFrame: true)
            }
            guard !segments.isEmpty else { continue }
            plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: true, isBoost: false, segments: segments))
            nextID += 1
        }

        for track in project.tracks where !track.isMuted {
            let segments = track.clips.compactMap { clip -> CompositionPlan.Segment? in
                guard !clip.audioMuted, let media = clip.mediaID.flatMap({ items.items[$0] }), media.kind != .image,
                      let asset = loaded[media.id], asset.audioTrack != nil else { return nil }
                if track.kind == .video && media.kind != .video { return nil }
                return segment(for: clip, media: media, available: asset.audioTimeRange, holdLastFrame: false)
            }
            guard !segments.isEmpty else { continue }
            plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: false, isBoost: false, segments: segments))
            nextID += 1
            let boostedClips = Set(track.clips.lazy.filter { $0.volume > 1.001 }.map(\.id))
            let boosted = boostedClips.isEmpty ? [] : segments.filter { boostedClips.contains($0.clipID) }
            if !boosted.isEmpty {
                plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: false, isBoost: true, segments: boosted))
                nextID += 1
            }
        }
        return plan
    }

    /// The clip's source range clamped to what the media actually provides. With `holdLastFrame`,
    /// a clip that runs past the end of the source keeps showing its last frame until the clip ends.
    private static func segment(for clip: Clip, media: MediaItem, available: CMTimeRange,
                                holdLastFrame: Bool) -> CompositionPlan.Segment? {
        var at = ticks(clip.start)
        let end = ticks(clip.end)
        var source = ticks(clip.sourceIn)
        let availableStart = Int64((available.start.seconds * Double(timescale)).rounded(.up))
        let availableEnd = Int64((available.end.seconds * Double(timescale)).rounded(.down))
        if source < availableStart {
            at += availableStart - source
            source = availableStart
        }
        let length = min(end - at, availableEnd - source)
        guard length > 0 else { return nil }
        let hold = holdLastFrame ? max(0, end - at - length) : 0
        return .init(clipID: clip.id, mediaID: media.id, url: media.url, source: source, at: at, length: length, hold: hold)
    }

    // MARK: - Composition

    private static func makeComposition(plan: CompositionPlan, loaded: [UUID: LoadedAsset]) async throws -> AVComposition {
        let blank = try await BlankVideo.source()
        let composition = AVMutableComposition()
        guard let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: baseTrackID) else {
            throw EngineError.exportFailed("Could not create base video track")
        }
        let total = time(plan.total)
        let blankDuration = blank.timeRange.duration
        if CMTimeCompare(total, blankDuration) <= 0 {
            try base.insertTimeRange(CMTimeRange(start: blank.timeRange.start, duration: total), of: blank.track, at: .zero)
        } else {
            try base.insertTimeRange(blank.timeRange, of: blank.track, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: blankDuration), toDuration: total)
        }

        for trackPlan in plan.tracks {
            let type: AVMediaType = trackPlan.isVideo ? .video : .audio
            guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: trackPlan.id) else {
                throw EngineError.exportFailed("Could not create composition track")
            }
            for s in trackPlan.segments {
                guard let asset = loaded[s.mediaID],
                      let sourceTrack = trackPlan.isVideo ? asset.videoTrack : asset.audioTrack else { continue }
                try track.insertTimeRange(CMTimeRange(start: time(s.source), duration: time(s.length)),
                                          of: sourceTrack, at: time(s.at))
                if s.hold > 0 {
                    // Stretch the last source frame over the rest of the clip.
                    let sourceEnd = time(s.source + s.length)
                    let frameStart = CMTimeMaximum(time(s.source), CMTimeSubtract(sourceEnd, asset.videoFrameDuration))
                    let frame = CMTimeRange(start: frameStart, end: sourceEnd)
                    let holdAt = time(s.at + s.length)
                    try track.insertTimeRange(frame, of: sourceTrack, at: holdAt)
                    track.scaleTimeRange(CMTimeRange(start: holdAt, duration: frame.duration), toDuration: time(s.hold))
                }
            }
        }
        // Players get an immutable snapshot.
        return composition.copy() as! AVComposition
    }

    // MARK: - Video composition

    private static func makeVideoComposition(project: Project, plan: CompositionPlan, media items: LoadedMedia,
                                             renderScale: Double) -> AVVideoComposition {
        let canvas = project.canvas
        let canvasSize = canvas.size
        let visibleVideo = project.tracks.filter { $0.kind == .video && !$0.isHidden }
        TextRenderer.reserveCapacity(visibleVideo.reduce(0) { n, t in n + t.clips.lazy.filter(\.isText).count })

        struct TimedLayer { let start: Int64; let end: Int64; let layer: CompositorLayer; let trackID: CMPersistentTrackID? }
        var timed: [TimedLayer] = []
        for track in visibleVideo {
            let compTrack = plan.tracks.first { $0.isVideo && $0.timelineTrack == track.id }
            let placedClips = Set(compTrack?.segments.map(\.clipID) ?? [])
            for clip in track.clips {
                let start = ticks(clip.start), end = min(ticks(clip.end), plan.total)
                guard end > start else { continue }
                if let style = clip.text {
                    // Rasterize at the size the title is shown at, so scaled-up titles and exports
                    // above canvas size stay sharp; geometry stays in canvas pixels.
                    let displayScale = renderScale * max(0, clip.transform.scale)
                    guard let cg = TextRenderer.image(for: style, canvas: canvasSize, scale: displayScale) else { continue }
                    let layer = CompositorLayer(content: .image(CIImage(cgImage: cg)),
                                                contentSize: TextRenderer.size(for: style, canvas: canvasSize),
                                                isText: true, clip: clip)
                    timed.append(TimedLayer(start: start, end: end, layer: layer, trackID: nil))
                    continue
                }
                guard let media = clip.mediaID.flatMap({ items.items[$0] }) else { continue }
                switch media.kind {
                case .image:
                    guard let image = items.stills[media.id] else { continue }
                    let size = media.pixelWidth > 0 && media.pixelHeight > 0 ? media.pixelSize : image.extent.size
                    let layer = CompositorLayer(content: .image(image), contentSize: size, isText: false, clip: clip)
                    timed.append(TimedLayer(start: start, end: end, layer: layer, trackID: nil))
                case .video:
                    guard let compTrack, placedClips.contains(clip.id), let asset = items.loaded[media.id] else { continue }
                    let size = media.pixelWidth > 0 && media.pixelHeight > 0 ? media.pixelSize : asset.displaySize
                    let layer = CompositorLayer(content: .video(trackID: compTrack.id, orientation: asset.orientationTransform),
                                                contentSize: size, isText: false, clip: clip)
                    timed.append(TimedLayer(start: start, end: end, layer: layer, trackID: compTrack.id))
                case .audio:
                    continue
                }
            }
        }

        var boundaries = Set<Int64>([0, plan.total])
        for t in timed {
            boundaries.insert(max(0, t.start))
            boundaries.insert(min(plan.total, t.end))
        }
        let cuts = boundaries.filter { $0 >= 0 && $0 <= plan.total }.sorted()
        let background = CIColor(red: canvas.backgroundColor.r, green: canvas.backgroundColor.g,
                                 blue: canvas.backgroundColor.b, alpha: canvas.backgroundColor.a,
                                 colorSpace: FrameCompositor.colorSpace) ?? .black
        // Sweep the cuts with an active set (indices into `timed`, kept in bottom → top order).
        // Every layer end is a cut, so a layer is active over [a, b) iff start <= a < end.
        let byStart = timed.indices.sorted { timed[$0].start < timed[$1].start }
        var nextStart = 0
        var active: [Int] = []
        var instructions: [CompositorInstruction] = []
        instructions.reserveCapacity(cuts.count)
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            active.removeAll { timed[$0].end <= a }
            while nextStart < byStart.count, timed[byStart[nextStart]].start <= a {
                let i = byStart[nextStart]
                nextStart += 1
                guard timed[i].end > a else { continue }
                active.insert(i, at: active.firstIndex { $0 > i } ?? active.count)
            }
            var trackIDs: [CMPersistentTrackID] = []
            for i in active { if let id = timed[i].trackID, !trackIDs.contains(id) { trackIDs.append(id) } }
            let snapshot = RenderSnapshot(canvasSize: canvasSize, background: background, layers: active.map { timed[$0].layer })
            instructions.append(CompositorInstruction(timeRange: CMTimeRange(start: time(a), end: time(b)),
                                                      snapshot: snapshot, requiredTrackIDs: trackIDs))
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = VideoCompositor.self
        vc.frameDuration = frameDuration(for: canvas.frameRate)
        vc.renderSize = renderSize(for: canvas, scale: renderScale)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = instructions
        return vc.copy() as! AVVideoComposition
    }

    // MARK: - Audio mix

    private static func makeAudioMix(project: Project, plan: CompositionPlan) -> AVAudioMix {
        var clips: [UUID: Clip] = [:]
        for track in project.tracks { for clip in track.clips { clips[clip.id] = clip } }

        struct Ramp { let from: Float; let to: Float; let start: Int64; let end: Int64 }
        var inputs: [AVMutableAudioMixInputParameters] = []
        var ramps: [Ramp] = []
        for trackPlan in plan.tracks where !trackPlan.isVideo {
            ramps.removeAll(keepingCapacity: true)
            var cursor = Int64.min
            // Appends a ramp, clipped so ramps never overlap (AVFoundation throws on overlap).
            func add(_ from: Float, _ to: Float, _ start: Int64, _ end: Int64) {
                let start = max(start, cursor)
                guard end > start else { return }
                ramps.append(Ramp(from: from, to: to, start: start, end: end))
                cursor = end
            }
            for s in trackPlan.segments {
                guard let clip = clips[s.clipID] else { continue }
                let volume = max(0, min(2, clip.volume))
                let gain = Float(trackPlan.isBoost ? max(0, volume - 1) : min(1, volume))
                let start = ticks(clip.start), end = ticks(clip.end)
                let length = end - start
                guard length > 0 else { continue }
                let fadeIn = max(0, min(ticks(clip.fadeIn), length))
                let fadeOut = max(0, min(ticks(clip.fadeOut), length - fadeIn))
                // A ramp's end volume holds until the next ramp, and constant stretches are flat
                // ramps: AVFoundation inserts point volumes in quadratic time.
                if fadeIn > 0 { add(0, gain, start, start + fadeIn) }
                add(gain, gain, start + fadeIn, end - fadeOut)
                if fadeOut > 0 { add(gain, 0, end - fadeOut, end) }
            }
            let params = AVMutableAudioMixInputParameters()
            params.trackID = trackPlan.id
            if ramps.first.map({ $0.start > 0 }) ?? true { params.setVolume(0, at: .zero) }
            // Latest first: AVFoundation inserts each ramp with a scan from the front of its list,
            // so chronological insertion would be quadratic in the clip count.
            for r in ramps.reversed() {
                params.setVolumeRamp(fromStartVolume: r.from, toEndVolume: r.to,
                                     timeRange: CMTimeRange(start: time(r.start), end: time(r.end)))
            }
            inputs.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        return mix.copy() as! AVAudioMix
    }
}

/// The structural description of a composition: which media ranges go on which tracks.
struct CompositionPlan: Hashable {
    struct Segment: Hashable {
        let clipID: UUID
        let mediaID: UUID
        let url: URL
        /// Source start, timeline position and inserted length, in `CompositionBuilder.timescale` ticks.
        let source: Int64
        let at: Int64
        let length: Int64
        /// Video only: ticks after `at + length` the last source frame is held for.
        let hold: Int64
    }
    struct TrackPlan: Hashable {
        let id: CMPersistentTrackID
        let timelineTrack: UUID
        let isVideo: Bool
        /// Duplicate audio track carrying gain above unity.
        let isBoost: Bool
        let segments: [Segment]
    }
    var total: Int64
    var tracks: [TrackPlan]
    var missing: [String]
    var canvas: CanvasSettings
}

public enum EngineError: LocalizedError {
    case notImplemented
    case missingMedia(String)
    case exportFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented"
        case .missingMedia(let n): "Missing media: \(n)"
        case .exportFailed(let m): "Export failed: \(m)"
        }
    }
}
