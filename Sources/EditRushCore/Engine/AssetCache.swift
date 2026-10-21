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
    /// Duration of one source frame (the track's minimum frame duration; 1/30 s when unknown).
    public let videoFrameDuration: CMTime
    public let preferredTransform: CGAffineTransform
    /// Encoded (pre-transform) frame size.
    public let naturalSize: CGSize
    /// First audio track (nil when the file has no sound).
    public let audioTrack: AVAssetTrack?
    public let audioTimeRange: CMTimeRange

    init(asset: AVURLAsset, duration: CMTime, videoTrack: AVAssetTrack?, videoTimeRange: CMTimeRange,
         videoFrameDuration: CMTime = CMTime(value: 1, timescale: 30),
         preferredTransform: CGAffineTransform, naturalSize: CGSize, audioTrack: AVAssetTrack?, audioTimeRange: CMTimeRange) {
        self.asset = asset; self.duration = duration
        self.videoTrack = videoTrack; self.videoTimeRange = videoTimeRange; self.videoFrameDuration = videoFrameDuration
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

/// Caches AVURLAssets (and their loaded tracks / preferred transforms) per media id, and decoded
/// still images per media id and decode size, so rebuilding a composition after every edit is
/// cheap. Stills live in a least-recently-used cache bounded by `imageByteBudget`. Thread-safe.
public final class AssetCache: @unchecked Sendable {
    public static let shared = AssetCache()
    /// Long-side limit for decoded still images.
    public static let maxImageDimension = 4096
    /// Decode sizes (long side) stills are rounded up to, so small scale changes reuse a decode.
    static let stillDecodeSteps = [256, 512, 768, 1024, 1536, 2048, 3072, 4096]

    /// One still to fetch: the media and the long side (output pixels) it is displayed at.
    public struct StillRequest: Sendable {
        public var media: MediaItem
        public var displayLongSide: Double
        public init(media: MediaItem, displayLongSide: Double) {
            self.media = media; self.displayLongSide = displayLongSide
        }
    }

    private final class StillEntry {
        let url: URL
        /// The decode size this entry was made for; it serves every request up to this size.
        let covers: Int
        let image: CIImage
        let bytes: Int
        var lastUse: UInt64
        init(url: URL, covers: Int, image: CIImage, bytes: Int, lastUse: UInt64) {
            self.url = url; self.covers = covers; self.image = image; self.bytes = bytes; self.lastUse = lastUse
        }
    }

    private let lock = NSLock()
    private var assets: [UUID: AVURLAsset] = [:]
    private var loads: [UUID: (url: URL, task: Task<LoadedAsset, Error>)] = [:]
    private var completed: [UUID: (url: URL, loaded: LoadedAsset)] = [:]
    private var stills: [UUID: [StillEntry]] = [:]
    private var stillBytes = 0
    private var clock: UInt64 = 0
    private var budget: Int

    public init() {
        budget = Int(min(1 << 30, ProcessInfo.processInfo.physicalMemory / 8))
    }

    /// Bytes of decoded stills kept for reuse. Stills requested by the current `images(for:)` call
    /// are never evicted by it, so one composition's stills may exceed the budget.
    public var imageByteBudget: Int {
        get { lock.withLock { budget } }
        set { lock.withLock { budget = max(0, newValue); evictStillsLocked(keeping: []) } }
    }

    /// Bytes of decoded stills currently cached.
    public var cachedImageBytes: Int { lock.withLock { stillBytes } }

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

    // MARK: - Stills

    /// Decoded, orientation-corrected still image (images only), long side ≤ `maxImageDimension`.
    /// Decodes synchronously on first use — call off the main thread.
    public func image(for media: MediaItem) -> CIImage? {
        image(for: media, displayLongSide: Double(Self.maxImageDimension))
    }

    /// Decoded, orientation-corrected still sharp enough to show with its long side at
    /// `displayLongSide` pixels (see `stillDecodeSize`). Decodes synchronously on a cache miss —
    /// call off the main thread.
    public func image(for media: MediaItem, displayLongSide: Double) -> CIImage? {
        let size = Self.stillDecodeSize(displayLongSide: displayLongSide, media: media)
        if let hit = lock.withLock({ cachedStillLocked(media, size: size) }) { return hit }
        guard let decoded = Self.decodeImage(at: media.url, maxPixelSize: size) else { return nil }
        return lock.withLock { insertStillLocked(media, size: size, decoded: decoded, keeping: []) }
    }

    /// Fetches many stills, decoding cache misses concurrently. Requests for the same media are
    /// merged (largest size wins). Media that cannot be decoded are absent from the result.
    public func images(for requests: [StillRequest]) async -> [UUID: CIImage] {
        var wanted: [UUID: (media: MediaItem, size: Int)] = [:]
        for r in requests {
            let size = Self.stillDecodeSize(displayLongSide: r.displayLongSide, media: r.media)
            if let w = wanted[r.media.id], w.size >= size { continue }
            wanted[r.media.id] = (r.media, size)
        }
        let keep = Set(wanted.keys)
        var result: [UUID: CIImage] = [:]
        var misses: [(media: MediaItem, size: Int)] = []
        lock.withLock {
            for w in wanted.values {
                if let hit = cachedStillLocked(w.media, size: w.size) { result[w.media.id] = hit } else { misses.append(w) }
            }
            // Stills a previous batch kept over budget are released once no longer needed.
            evictStillsLocked(keeping: keep)
        }
        guard !misses.isEmpty else { return result }

        var decoded: [(media: MediaItem, size: Int, image: CGImage)] = []
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: (MediaItem, Int, CGImage?).self) { group in
            var next = 0
            func addNext() {
                guard next < misses.count else { return }
                let m = misses[next]
                next += 1
                group.addTask { (m.media, m.size, Self.decodeImage(at: m.media.url, maxPixelSize: m.size)) }
            }
            for _ in 0..<min(width, misses.count) { addNext() }
            while let (media, size, image) = await group.next() {
                if let image { decoded.append((media, size, image)) }
                addNext()
            }
        }
        lock.withLock {
            for d in decoded {
                result[d.media.id] = insertStillLocked(d.media, size: d.size, decoded: d.image, keeping: keep)
            }
        }
        return result
    }

    /// Decode size (long side, pixels) for a still shown at `displayLongSide`: rounded up to a
    /// decode step and capped at the source size and `maxImageDimension`.
    public static func stillDecodeSize(displayLongSide: Double, media: MediaItem) -> Int {
        let source = max(media.pixelWidth, media.pixelHeight)
        let cap = source > 0 ? min(source, maxImageDimension) : maxImageDimension
        let needed = displayLongSide.isFinite
            ? Int(min(Double(maxImageDimension), max(1, displayLongSide)).rounded(.up))
            : maxImageDimension
        let step = stillDecodeSteps.first { $0 >= needed } ?? maxImageDimension
        return max(1, min(step, cap))
    }

    // MARK: - Purging

    public func purge(mediaID: UUID) {
        lock.withLock {
            assets[mediaID] = nil
            loads[mediaID] = nil
            completed[mediaID] = nil
            if let removed = stills.removeValue(forKey: mediaID) { stillBytes -= removed.reduce(0) { $0 + $1.bytes } }
        }
    }

    /// Drops everything (e.g. on memory pressure).
    public func purgeAll() {
        lock.withLock {
            assets.removeAll(); loads.removeAll(); completed.removeAll()
            stills.removeAll(); stillBytes = 0
        }
    }

    // MARK: - Private

    private func assetLocked(for media: MediaItem) -> AVURLAsset {
        if let a = assets[media.id], a.url == media.url { return a }
        let a = AVURLAsset(url: media.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[media.id] = a
        return a
    }

    /// Smallest cached decode of `media` that serves `size`; marks it used.
    private func cachedStillLocked(_ media: MediaItem, size: Int) -> CIImage? {
        var best: StillEntry?
        for e in stills[media.id] ?? [] where e.url == media.url && e.covers >= size {
            if best == nil || e.covers < best!.covers { best = e }
        }
        guard let best else { return nil }
        clock += 1
        best.lastUse = clock
        return best.image
    }

    private func insertStillLocked(_ media: MediaItem, size: Int, decoded: CGImage, keeping: Set<UUID>) -> CIImage {
        if let existing = cachedStillLocked(media, size: size) { return existing }
        var entries = stills[media.id] ?? []
        // Decodes of a previous file (relinked media) are dead.
        for stale in entries where stale.url != media.url { stillBytes -= stale.bytes }
        entries.removeAll { $0.url != media.url }
        clock += 1
        let entry = StillEntry(url: media.url, covers: size, image: CIImage(cgImage: decoded),
                               bytes: decoded.bytesPerRow * decoded.height, lastUse: clock)
        entries.append(entry)
        stills[media.id] = entries
        stillBytes += entry.bytes
        evictStillsLocked(keeping: keeping.union([media.id]))
        return entry.image
    }

    /// Evicts the least recently used stills (except those of `keeping`) until under budget.
    private func evictStillsLocked(keeping: Set<UUID>) {
        guard stillBytes > budget else { return }
        var candidates: [(id: UUID, entry: StillEntry)] = []
        for (id, entries) in stills where !keeping.contains(id) {
            for e in entries { candidates.append((id, e)) }
        }
        candidates.sort { $0.entry.lastUse < $1.entry.lastUse }
        for c in candidates {
            guard stillBytes > budget else { break }
            stills[c.id]?.removeAll { $0 === c.entry }
            if stills[c.id]?.isEmpty == true { stills[c.id] = nil }
            stillBytes -= c.entry.bytes
        }
    }

    private static func load(_ asset: AVURLAsset, url: URL, name: String) async throws -> LoadedAsset {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError.missingMedia(name) }
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var natural = CGSize.zero, transform = CGAffineTransform.identity, videoRange = CMTimeRange.zero
        var frameDuration = CMTime(value: 1, timescale: 30)
        if let video {
            let minFrame: CMTime
            (natural, transform, videoRange, minFrame) = try await video.load(.naturalSize, .preferredTransform,
                                                                                .timeRange, .minFrameDuration)
            if minFrame.isNumeric, minFrame.seconds > 0, minFrame.seconds < 1 { frameDuration = minFrame }
        }
        var audioRange = CMTimeRange.zero
        if let audio { audioRange = try await audio.load(.timeRange) }
        return LoadedAsset(asset: asset, duration: duration, videoTrack: video, videoTimeRange: videoRange,
                           videoFrameDuration: frameDuration, preferredTransform: transform, naturalSize: natural,
                           audioTrack: audio, audioTimeRange: audioRange)
    }

    /// Decodes an image with ImageIO thumbnailing (subsampled decode, EXIF orientation applied),
    /// long side ≤ `maxPixelSize`.
    static func decodeImage(at url: URL, maxPixelSize: Int = maxImageDimension) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longSide = max(w, h)
        guard longSide > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(longSide, maxPixelSize, maxImageDimension)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

