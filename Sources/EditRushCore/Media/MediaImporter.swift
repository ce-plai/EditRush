import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let n): "Unsupported file type: \(n)"
        case .unreadable(let n): "Could not read \(n)"
        }
    }
}

public enum MediaImporter {
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let audioExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"]
    public static var supportedExtensions: Set<String> { videoExtensions.union(audioExtensions).union(imageExtensions) }
    public static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Probes many files concurrently. Folders are expanded (non-recursive is fine). Unsupported
    /// files are reported in `failures` rather than throwing.
    public static func importFiles(_ urls: [URL]) async -> (items: [MediaItem], failures: [(url: URL, reason: String)]) {
        var items: [MediaItem] = []
        var failures: [(URL, String)] = []
        for url in urls {
            do { items.append(try await probe(url)) } catch { failures.append((url, error.localizedDescription)) }
        }
        return (items, failures)
    }

    /// Reads kind, duration, display size, frame rate and audio presence.
    public static func probe(_ url: URL) async throws -> MediaItem {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        guard supportedExtensions.contains(ext) else { throw MediaError.unsupported(url.lastPathComponent) }

        if imageExtensions.contains(ext) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                throw MediaError.unreadable(url.lastPathComponent)
            }
            var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) { swap(&w, &h) }
            return MediaItem(url: url, name: name, kind: .image, duration: 0, pixelWidth: w, pixelHeight: h)
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let vt = videoTracks.first {
            let (natural, xf, fps) = try await vt.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let r = CGRect(origin: .zero, size: natural).applying(xf)
            return MediaItem(url: url, name: name, kind: .video, duration: duration,
                             pixelWidth: Int(abs(r.width).rounded()), pixelHeight: Int(abs(r.height).rounded()),
                             frameRate: Double(fps), hasAudio: !audioTracks.isEmpty)
        }
        guard !audioTracks.isEmpty else { throw MediaError.unreadable(url.lastPathComponent) }
        return MediaItem(url: url, name: name, kind: .audio, duration: duration, hasAudio: true)
    }
}
