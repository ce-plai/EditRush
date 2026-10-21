import AVFoundation
import CoreGraphics
import ImageIO
import Observation

/// Asynchronously generated, memory-cached thumbnails for the media bin and timeline filmstrips.
///
/// Lookups never block: they return the best cached image (or nil) and schedule generation once.
/// Decoding happens off the main actor with at most `maxConcurrentJobs` media generating at once
/// (posters before filmstrips). `version` increments (throttled to ~10 Hz) whenever new images
/// land; lookups read it, so SwiftUI views that call them re-render automatically.
@MainActor
@Observable
public final class ThumbnailCache {
    public static let shared = ThumbnailCache()
    public private(set) var version = 0

    /// Maximum poster height in pixels.
    public nonisolated static let posterHeight = 480.0
    /// Maximum filmstrip frame height in pixels.
    public nonisolated static let filmstripHeight = 180.0
    /// Filmstrips hold one frame per this many seconds of source, up to `maxFilmstripFrames`.
    public nonisolated static let filmstripInterval: Seconds = 1
    public nonisolated static let maxFilmstripFrames = 200
    static let maxConcurrentJobs = 2
    /// Least-recently used filmstrips are dropped beyond this many bytes (posters are kept).
    static let filmstripByteBudget = 320 * 1024 * 1024

    private struct Filmstrip {
        /// Requested source times, ascending; `frames[i]` is nil until generated.
        var times: [Seconds]
        var frames: [CGImage?]
        var bytes = 0
        var lastUse = 0
        var isComplete = false
    }

    private enum Job: Equatable {
        case poster(MediaItem)
        case filmstrip(MediaItem)
    }

    @ObservationIgnored private var posters: [URL: CGImage] = [:]
    @ObservationIgnored private var posterRequested: Set<URL> = []
    @ObservationIgnored private var filmstrips: [URL: Filmstrip] = [:]
    @ObservationIgnored private var filmstripRequested: Set<URL> = []
    @ObservationIgnored private var posterQueue: [MediaItem] = []
    @ObservationIgnored private var filmstripQueue: [MediaItem] = []
    @ObservationIgnored private var runningJobs = 0
    @ObservationIgnored private var useCounter = 0
    @ObservationIgnored private lazy var changeThrottle = MediaChangeThrottle { [weak self] in self?.version += 1 }

    public init() {}

    /// Poster frame for the media bin (video: frame at min(1 s, 10% of duration); image: the image
    /// itself), at most ~480 px tall. Audio: nil.
    public func poster(for media: MediaItem) -> CGImage? {
        _ = version
        guard media.hasVisual else { return nil }
        if let image = posters[media.url] { return image }
        requestPoster(media)
        return nil
    }

    /// Filmstrip frame nearest to source time `t` (video: one frame per second of source, at most
    /// 200 per media, ~180 px tall). Returns the poster while the filmstrip is generating, and the
    /// poster for images. Audio: nil.
    public func frame(for media: MediaItem, at t: Seconds) -> CGImage? {
        _ = version
        switch media.kind {
        case .audio: return nil
        case .image: return poster(for: media)
        case .video: break
        }
        if var strip = filmstrips[media.url] {
            useCounter += 1
            strip.lastUse = useCounter
            filmstrips[media.url] = strip
            if let image = Self.nearestFrame(in: strip, to: t) { return image }
        } else {
            requestFilmstrip(media)
        }
        return poster(for: media)
    }

    // MARK: - Test / diagnostics hooks

    /// True once every filmstrip frame for `media` has been generated (or failed).
    func isFilmstripComplete(for media: MediaItem) -> Bool { filmstrips[media.url]?.isComplete ?? false }
    /// Number of generated filmstrip frames for `media`.
    func filmstripFrameCount(for media: MediaItem) -> Int { filmstrips[media.url]?.frames.lazy.compactMap { $0 }.count ?? 0 }

    // MARK: - Scheduling

    private func requestPoster(_ media: MediaItem) {
        guard posterRequested.insert(media.url).inserted else { return }
        posterQueue.append(media)
        pump()
    }

    private func requestFilmstrip(_ media: MediaItem) {
        guard filmstripRequested.insert(media.url).inserted else { return }
        filmstripQueue.append(media)
        pump()
    }

    private func pump() {
        while runningJobs < Self.maxConcurrentJobs {
            let job: Job
            if !posterQueue.isEmpty {
                job = .poster(posterQueue.removeFirst())
            } else if !filmstripQueue.isEmpty {
                job = .filmstrip(filmstripQueue.removeFirst())
            } else {
                return
            }
            runningJobs += 1
            Task { [weak self] in
                await self?.run(job)
                guard let self else { return }
                self.runningJobs -= 1
                self.pump()
            }
        }
    }

    private func run(_ job: Job) async {
        switch job {
        case .poster(let media):
            let image = await Task.detached(priority: .userInitiated) {
                media.kind == .image ? ThumbnailGenerator.imageThumbnail(media, maxHeight: Self.posterHeight)
                                     : await ThumbnailGenerator.videoPoster(media, maxHeight: Self.posterHeight)
            }.value
            if let image {
                posters[media.url] = image
                changeThrottle.signal()
            }
        case .filmstrip(let media):
            let times = Self.filmstripTimes(duration: media.duration)
            guard !times.isEmpty else { return }
            useCounter += 1
            filmstrips[media.url] = Filmstrip(times: times, frames: Array(repeating: nil, count: times.count),
                                              lastUse: useCounter)
            let url = media.url
            await Task.detached(priority: .utility) {
                await ThumbnailGenerator.filmstrip(media, times: times, maxHeight: Self.filmstripHeight) { batch in
                    await self.receive(batch, for: url)
                }
            }.value
            filmstrips[url]?.isComplete = true
            changeThrottle.signal()
            evictFilmstripsIfNeeded(keeping: url)
        }
    }

    private func receive(_ batch: [(index: Int, image: CGImage)], for url: URL) {
        guard var strip = filmstrips[url] else { return }
        for (index, image) in batch where strip.frames.indices.contains(index) {
            strip.frames[index] = image
            strip.bytes += image.bytesPerRow * image.height
        }
        filmstrips[url] = strip
        changeThrottle.signal()
    }

    private func evictFilmstripsIfNeeded(keeping url: URL) {
        var total = filmstrips.values.reduce(0) { $0 + $1.bytes }
        guard total > Self.filmstripByteBudget else { return }
        let candidates = filmstrips.filter { $0.key != url && $0.value.isComplete }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, strip) in candidates where total > Self.filmstripByteBudget {
            filmstrips[key] = nil
            filmstripRequested.remove(key)
            total -= strip.bytes
        }
    }

    // MARK: - Helpers

    nonisolated static func filmstripTimes(duration: Seconds) -> [Seconds] {
        guard duration.isFinite, duration > 0 else { return [] }
        let interval = max(filmstripInterval, duration / Double(maxFilmstripFrames))
        let count = min(maxFilmstripFrames, max(1, Int((duration / interval).rounded(.up))))
        let last = max(0, duration - 0.05)
        return (0..<count).map { min(Double($0) * interval, last) }
    }

    private static func nearestFrame(in strip: Filmstrip, to t: Seconds) -> CGImage? {
        guard !strip.times.isEmpty else { return nil }
        // Binary search for the first time >= t, then spiral outwards to the closest generated frame.
        var lo = 0, hi = strip.times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if strip.times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var left = lo - 1, right = lo
        while left >= 0 || right < strip.times.count {
            let leftDistance = left >= 0 ? t - strip.times[left] : .infinity
            let rightDistance = right < strip.times.count ? strip.times[right] - t : .infinity
            if leftDistance <= rightDistance {
                if let image = strip.frames[left] { return image }
                left -= 1
            } else {
                if let image = strip.frames[right] { return image }
                right += 1
            }
        }
        return nil
    }
}

/// Coalesces change notifications so observers re-render at most every `interval` seconds.
@MainActor
final class MediaChangeThrottle {
    private let interval: TimeInterval
    private let fire: @MainActor () -> Void
    private var lastFire = Date.distantPast
    private var pending = false

    init(interval: TimeInterval = 0.1, fire: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.fire = fire
    }

    func signal() {
        guard !pending else { return }
        let wait = interval - Date().timeIntervalSince(lastFire)
        if wait <= 0 {
            lastFire = Date()
            fire()
            return
        }
        pending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.pending = false
            self.lastFire = Date()
            self.fire()
        }
    }
}

/// Off-main-actor thumbnail decoding.
enum ThumbnailGenerator {
    /// Downsampled, orientation-corrected image thumbnail, decoded immediately.
    static func imageThumbnail(_ media: MediaItem, maxHeight: Double) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(media.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let w = Double(max(1, media.pixelWidth)), h = Double(max(1, media.pixelHeight))
        let height = min(maxHeight, h)
        let longSide = min(max(height * w / h, height), maxHeight * 4)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longSide.rounded(.up)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    static func videoPoster(_ media: MediaItem, maxHeight: Double) async -> CGImage? {
        let generator = makeGenerator(media, maxHeight: maxHeight, tolerance: 0.25)
        let t = max(0, min(1, media.duration * 0.1))
        if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { return image }
        return try? await generator.image(at: .zero).image
    }

    /// Generates frames at `times` in one batch, delivering them in small groups via `deliver`.
    static func filmstrip(_ media: MediaItem, times: [Seconds], maxHeight: Double,
                          deliver: @escaping @Sendable ([(index: Int, image: CGImage)]) async -> Void) async {
        let interval = times.count > 1 ? times[1] - times[0] : 1
        let generator = makeGenerator(media, maxHeight: maxHeight, tolerance: max(0.5, interval / 2))
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let indexByTime = Dictionary(cmTimes.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var batch: [(index: Int, image: CGImage)] = []
        var lastDelivery = Date()
        for await result in generator.images(for: cmTimes) {
            if Task.isCancelled { break }
            guard let image = try? result.image, let index = indexByTime[result.requestedTime] else { continue }
            batch.append((index, image))
            if Date().timeIntervalSince(lastDelivery) > 0.1 {
                await deliver(batch)
                batch.removeAll(keepingCapacity: true)
                lastDelivery = Date()
            }
        }
        if !batch.isEmpty { await deliver(batch) }
    }

    private static func makeGenerator(_ media: MediaItem, maxHeight: Double, tolerance: Seconds) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        generator.appliesPreferredTrackTransform = true
        let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        // maximumSize is applied as a bounding box, so a square box keeps the long side in check for
        // both landscape and portrait sources regardless of whether it is applied pre- or post-rotation.
        let w = Double(max(1, media.pixelWidth)), h = Double(max(1, media.pixelHeight))
        let height = min(maxHeight, h)
        let side = min(max(height * w / h, height), maxHeight * 4).rounded(.up)
        generator.maximumSize = CGSize(width: side, height: side)
        return generator
    }
}
