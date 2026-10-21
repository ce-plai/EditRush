import AVFoundation
import CoreImage

/// Caches AVURLAssets (and their loaded tracks / preferred transforms) and decoded still images
/// per media id, so rebuilding a composition after every edit is cheap. Thread-safe. (STUB)
public final class AssetCache: @unchecked Sendable {
    public static let shared = AssetCache()
    public init() {}

    public func asset(for media: MediaItem) -> AVURLAsset { AVURLAsset(url: media.url) }
    /// Decoded, orientation-corrected still image (images only).
    public func image(for media: MediaItem) -> CIImage? { nil }
    public func purge(mediaID: UUID) {}
}
