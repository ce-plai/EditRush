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
        let (loaded, missing) = await loadMedia(for: project, assets: assets)
        let plan = makePlan(project: project, loaded: loaded, missing: missing)
        let composition: AVComposition
        if let previous, previous.plan == plan {
            composition = previous.composition
        } else {
            composition = try await makeComposition(plan: plan, loaded: loaded)
        }
        let videoComposition = makeVideoComposition(project: project, plan: plan, loaded: loaded,
                                                    assets: assets, renderScale: renderScale)
        let audioMix = makeAudioMix(project: project, plan: plan)
        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                                duration: Double(plan.total) / Double(timescale), missingMedia: missing,
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

    private static func loadMedia(for project: Project, assets: AssetCache) async -> ([UUID: LoadedAsset], [String]) {
        var needed: [UUID: MediaItem] = [:]
        for track in project.tracks {
            for clip in track.clips {
                guard let media = project.media(clip.mediaID), media.kind != .image else { continue }
                needed[media.id] = media
            }
        }
        var loaded: [UUID: LoadedAsset] = [:]
        var missing: [String] = []
        var pending: [MediaItem] = []
        for media in needed.values {
            if let done = assets.cachedLoaded(for: media) { loaded[media.id] = done } else { pending.append(media) }
        }
        if !pending.isEmpty {
            await withTaskGroup(of: (MediaItem, LoadedAsset?).self) { group in
                for media in pending {
                    group.addTask { (media, try? await assets.loaded(for: media)) }
                }
                for await (media, result) in group {
                    if let result { loaded[media.id] = result } else { missing.append(media.name) }
                }
            }
        }
        return (loaded, missing.sorted())
    }

    // MARK: - Plan

    private static func makePlan(project: Project, loaded: [UUID: LoadedAsset], missing: [String]) -> CompositionPlan {
        let frameTicks = max(1, ticks(project.canvas.frameDuration))
        var plan = CompositionPlan(total: max(frameTicks, ticks(project.duration)), tracks: [], missing: missing,
                                   canvas: project.canvas)
        var nextID = baseTrackID + 1

        for track in project.tracks where track.kind == .video && !track.isHidden {
            let segments = track.clips.compactMap { clip -> CompositionPlan.Segment? in
                guard let media = project.media(clip.mediaID), media.kind == .video,
                      let asset = loaded[media.id], asset.videoTrack != nil else { return nil }
                return segment(for: clip, media: media, available: asset.videoTimeRange)
            }
            guard !segments.isEmpty else { continue }
            plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: true, isBoost: false, segments: segments))
            nextID += 1
        }

        for track in project.tracks where !track.isMuted {
            let segments = track.clips.compactMap { clip -> CompositionPlan.Segment? in
                guard let media = project.media(clip.mediaID), media.kind != .image,
                      let asset = loaded[media.id], asset.audioTrack != nil else { return nil }
                if track.kind == .video && (clip.audioMuted || media.kind != .video) { return nil }
                return segment(for: clip, media: media, available: asset.audioTimeRange)
            }
            guard !segments.isEmpty else { continue }
            plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: false, isBoost: false, segments: segments))
            nextID += 1
            let boosted = segments.filter { s in (track.clips.first { $0.id == s.clipID }?.volume ?? 1) > 1.001 }
            if !boosted.isEmpty {
                plan.tracks.append(.init(id: nextID, timelineTrack: track.id, isVideo: false, isBoost: true, segments: boosted))
                nextID += 1
            }
        }
        return plan
    }

    /// The clip's source range clamped to what the media actually provides.
    private static func segment(for clip: Clip, media: MediaItem, available: CMTimeRange) -> CompositionPlan.Segment? {
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
        return .init(clipID: clip.id, mediaID: media.id, url: media.url, source: source, at: at, length: length)
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
            }
        }
        // Players get an immutable snapshot.
        return composition.copy() as! AVComposition
    }

    // MARK: - Video composition

    private static func makeVideoComposition(project: Project, plan: CompositionPlan, loaded: [UUID: LoadedAsset],
                                             assets: AssetCache, renderScale: Double) -> AVVideoComposition {
        let canvas = project.canvas
        let canvasSize = canvas.size

        struct TimedLayer { let start: Int64; let end: Int64; let layer: CompositorLayer; let trackID: CMPersistentTrackID? }
        var timed: [TimedLayer] = []
        for track in project.tracks where track.kind == .video && !track.isHidden {
            let compTrack = plan.tracks.first { $0.isVideo && $0.timelineTrack == track.id }
            for clip in track.clips {
                let start = ticks(clip.start), end = min(ticks(clip.end), plan.total)
                guard end > start else { continue }
                if let style = clip.text {
                    guard let cg = TextRenderer.image(for: style, canvas: canvasSize) else { continue }
                    let layer = CompositorLayer(content: .image(CIImage(cgImage: cg)),
                                                contentSize: TextRenderer.size(for: style, canvas: canvasSize),
                                                isText: true, clip: clip)
                    timed.append(TimedLayer(start: start, end: end, layer: layer, trackID: nil))
                    continue
                }
                guard let media = project.media(clip.mediaID) else { continue }
                switch media.kind {
                case .image:
                    guard let image = assets.image(for: media) else { continue }
                    let size = media.pixelWidth > 0 && media.pixelHeight > 0 ? media.pixelSize : image.extent.size
                    let layer = CompositorLayer(content: .image(image), contentSize: size, isText: false, clip: clip)
                    timed.append(TimedLayer(start: start, end: end, layer: layer, trackID: nil))
                case .video:
                    guard let compTrack, compTrack.segments.contains(where: { $0.clipID == clip.id }),
                          let asset = loaded[media.id] else { continue }
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
        var instructions: [CompositorInstruction] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            let active = timed.filter { $0.start <= a && $0.end >= b }
            var trackIDs: [CMPersistentTrackID] = []
            for case let id? in active.map(\.trackID) where !trackIDs.contains(id) { trackIDs.append(id) }
            let snapshot = RenderSnapshot(canvasSize: canvasSize, background: background, layers: active.map(\.layer))
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

        var inputs: [AVMutableAudioMixInputParameters] = []
        for trackPlan in plan.tracks where !trackPlan.isVideo {
            let params = AVMutableAudioMixInputParameters()
            params.trackID = trackPlan.id
            params.setVolume(0, at: .zero)
            for s in trackPlan.segments {
                guard let clip = clips[s.clipID] else { continue }
                let volume = max(0, min(2, clip.volume))
                let gain = Float(trackPlan.isBoost ? max(0, volume - 1) : min(1, volume))
                let start = ticks(clip.start), end = ticks(clip.end)
                let length = end - start
                guard length > 0 else { continue }
                let fadeIn = max(0, min(ticks(clip.fadeIn), length))
                let fadeOut = max(0, min(ticks(clip.fadeOut), length - fadeIn))
                if fadeIn > 0 {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                                         timeRange: CMTimeRange(start: time(start), duration: time(fadeIn)))
                } else {
                    params.setVolume(gain, at: time(start))
                }
                if fadeOut > 0 {
                    params.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: time(end - fadeOut), duration: time(fadeOut)))
                }
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
