import AVFoundation
import CoreGraphics
import Observation

/// Asynchronously generated, memory-cached thumbnails (STUB — media module).
/// Lookups never block: they return the best cached image (or nil) and schedule generation;
/// `version` increments whenever new images land so SwiftUI views re-render.
@MainActor
@Observable
public final class ThumbnailCache {
    public static let shared = ThumbnailCache()
    public private(set) var version = 0
    public init() {}

    /// Poster frame for the media bin (video: frame at 10% / 1 s, image: the image itself), ~240 px tall.
    public func poster(for media: MediaItem) -> CGImage? { nil }
    /// Filmstrip frame nearest to source time `t` (video: ~1 thumb per second of source, ~90 px tall;
    /// image: the poster).
    public func frame(for media: MediaItem, at t: Seconds) -> CGImage? { nil }
}

/// Audio peak envelopes for timeline waveforms (STUB — media module).
@MainActor
@Observable
public final class WaveformCache {
    public static let shared = WaveformCache()
    public private(set) var version = 0
    /// Envelope resolution.
    public static let peaksPerSecond = 100.0
    public init() {}

    /// Normalized (0...1) peak values at `peaksPerSecond` over the whole media, or nil while computing.
    public func peaks(for media: MediaItem) -> [Float]? { nil }
}
