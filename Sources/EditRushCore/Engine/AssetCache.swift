import AVFoundation
import CoreImage
import ImageIO

/// An asset with the track properties the engine needs, loaded once.
public final class LoadedAsset: @unchecked Sendable {
    public let asset: AVURLAsset
    public let duration: CMTime
    /// First video track and its properties (nil for audio-only media).
    public let videoTrack: AVAssetTrack?
    public let videoTimeRange: CMTimeRange
    public let preferredTransform: CGAffineTransform
    /// Encoded (pre-transform) frame size.
    public let naturalSize: CGSize
    /// First audio track (nil when the file has no sound).
    public let audioTrack: AVAssetTrack?
    public let audioTimeRange: CMTimeRange

    init(asset: AVURLAsset, duration: CMTime, videoTrack: AVAssetTrack?, videoTimeRange: CMTimeRange,
         preferredTransform: CGAffineTransform, naturalSize: CGSize, audioTrack: AVAssetTrack?, audioTimeRange: CMTimeRange) {
        self.asset = asset; self.duration = duration
        self.videoTrack = videoTrack; self.videoTimeRange = videoTimeRange
        self.preferredTransform = preferredTransform; self.naturalSize = naturalSize
        self.audioTrack = audioTrack; self.audioTimeRange = audioTimeRange
    }

    /// Display size after applying `preferredTransform`.
    public var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
    }

    /// Core Image (y-up) transform that turns a decoded frame (extent at the origin, `naturalSize`)
    /// into the upright display image with its extent at the origin.
    public var orientationTransform: CGAffineTransform {
        let t = preferredTransform
        if t.isIdentity { return .identity }
        let display = displaySize
        let flipNatural = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: naturalSize.height)
        let flipDisplay = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height)
        var m = flipNatural.concatenating(t).concatenating(flipDisplay)
        let r = CGRect(origin: .zero, size: naturalSize).applying(m)
        m = m.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
        return m
    }
}

/// Caches AVURLAssets (and their loaded tracks / preferred transforms) and decoded still images
/// per media id, so rebuilding a composition after every edit is cheap. Thread-safe.
public final class AssetCache: @unchecked Sendable {
    public static let shared = AssetCache()
    /// Long-side limit for decoded still images.
    public static let maxImageDimension = 4096

    private let lock = NSLock()
    private var assets: [UUID: AVURLAsset] = [:]
    private var loads: [UUID: (url: URL, task: Task<LoadedAsset, Error>)] = [:]
    private var completed: [UUID: (url: URL, loaded: LoadedAsset)] = [:]
    private var images: [UUID: (url: URL, image: CIImage)] = [:]

    public init() {}

    public func asset(for media: MediaItem) -> AVURLAsset {
        lock.withLock { assetLocked(for: media) }
    }

    /// Loads (once) the asset's duration and first video / audio tracks.
    public func loaded(for media: MediaItem) async throws -> LoadedAsset {
        if let done = cachedLoaded(for: media) { return done }
        let task: Task<LoadedAsset, Error> = lock.withLock {
            if let l = loads[media.id], l.url == media.url { return l.task }
            let url = media.url, name = media.name
            let asset = assetLocked(for: media)
            let t = Task<LoadedAsset, Error> { try await Self.load(asset, url: url, name: name) }
            loads[media.id] = (url, t)
            return t
        }
        do {
            let loaded = try await task.value
            lock.withLock { completed[media.id] = (media.url, loaded) }
            return loaded
        } catch {
            // Don't cache failures: the file may be restored or relinked.
            lock.withLock {
                if let l = loads[media.id], l.url == media.url { loads[media.id] = nil; assets[media.id] = nil }
            }
            throw error
        }
    }

    /// The loaded asset if `loaded(for:)` already completed for this media; never blocks on I/O.
    public func cachedLoaded(for media: MediaItem) -> LoadedAsset? {
        lock.withLock { completed[media.id].flatMap { $0.url == media.url ? $0.loaded : nil } }
    }

    /// Decoded, orientation-corrected still image (images only), long side ≤ `maxImageDimension`.
    /// Decodes synchronously on first use — call off the main thread.
    public func image(for media: MediaItem) -> CIImage? {
        if let cached = lock.withLock({ images[media.id] }), cached.url == media.url { return cached.image }
        guard let image = Self.decodeImage(at: media.url) else { return nil }
        lock.withLock { images[media.id] = (media.url, image) }
        return image
    }

    public func purge(mediaID: UUID) {
        lock.withLock {
            assets[mediaID] = nil
            loads[mediaID] = nil
            completed[mediaID] = nil
            images[mediaID] = nil
        }
    }

    /// Drops everything (e.g. on memory pressure).
    public func purgeAll() {
        lock.withLock {
            assets.removeAll(); loads.removeAll(); completed.removeAll(); images.removeAll()
        }
    }

    // MARK: - Private

    private func assetLocked(for media: MediaItem) -> AVURLAsset {
        if let a = assets[media.id], a.url == media.url { return a }
        let a = AVURLAsset(url: media.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[media.id] = a
        return a
    }

    private static func load(_ asset: AVURLAsset, url: URL, name: String) async throws -> LoadedAsset {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError.missingMedia(name) }
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var natural = CGSize.zero, transform = CGAffineTransform.identity, videoRange = CMTimeRange.zero
        if let video {
            (natural, transform, videoRange) = try await video.load(.naturalSize, .preferredTransform, .timeRange)
        }
        var audioRange = CMTimeRange.zero
        if let audio { audioRange = try await audio.load(.timeRange) }
        return LoadedAsset(asset: asset, duration: duration, videoTrack: video, videoTimeRange: videoRange,
                           preferredTransform: transform, naturalSize: natural,
                           audioTrack: audio, audioTimeRange: audioRange)
    }

    static func decodeImage(at url: URL) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longSide = max(w, h)
        guard longSide > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longSide, maxImageDimension),
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let s = min(1, Double(maxImageDimension) / Double(max(ci.extent.width, ci.extent.height)))
        guard s < 1 else { return ci }
        return ci.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
    }
}
