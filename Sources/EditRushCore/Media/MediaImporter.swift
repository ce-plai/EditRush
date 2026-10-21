import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Why a file could not be imported. `reason` is a short, user-facing phrase without the file
/// name (e.g. "unsupported file type"); `errorDescription` includes the name.
public enum MediaError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String)
    case missing(String)
    case noTracks(String)
    case unplayable(String)
    case zeroDuration(String)
    case unreadableImage(String)

    public var fileName: String {
        switch self {
        case .unsupported(let n), .unreadable(let n), .missing(let n), .noTracks(let n),
             .unplayable(let n), .zeroDuration(let n), .unreadableImage(let n): n
        }
    }

    public var reason: String {
        switch self {
        case .unsupported: "unsupported file type"
        case .unreadable: "the file couldn't be read"
        case .missing: "the file doesn't exist"
        case .noTracks: "no video or audio found in the file"
        case .unplayable: "the file's format or codec isn't supported"
        case .zeroDuration: "the file has no playable length"
        case .unreadableImage: "the image couldn't be read"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported(let n): "Unsupported file type: \(n)"
        case .unreadable(let n): "Could not read \(n)"
        default: "Could not import \(fileName): \(reason)"
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

    /// Maximum number of files probed at the same time.
    static let maxConcurrentProbes = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// True if `url`'s extension is one EditRush can import.
    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Replaces folders in `urls` with their supported, non-hidden files (one level deep, sorted by
    /// name). Plain files are passed through unchanged, so unsupported ones are still reported.
    public static func expandFolders(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  !isPackage(url) else {
                files.append(url)
                continue
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            files += children
                .filter { isSupported($0) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        return files
    }

    /// Probes many files concurrently. Folders are expanded one level. Items are returned in
    /// input order; files that cannot be imported are reported in `failures` with a short,
    /// user-facing reason instead of throwing.
    public static func importFiles(_ urls: [URL]) async -> (items: [MediaItem], failures: [(url: URL, reason: String)]) {
        let files = expandFolders(urls)
        var results = [Result<MediaItem, MediaError>?](repeating: nil, count: files.count)

        await withTaskGroup(of: (Int, Result<MediaItem, MediaError>).self) { group in
            var next = 0
            func addNext() {
                guard next < files.count else { return }
                let index = next, url = files[index]
                next += 1
                group.addTask { (index, await probeResult(url)) }
            }
            for _ in 0..<min(maxConcurrentProbes, files.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
        }

        var items: [MediaItem] = []
        var failures: [(url: URL, reason: String)] = []
        for (url, result) in zip(files, results) {
            switch result {
            case .success(let item)?: items.append(item)
            case .failure(let error)?: failures.append((url, error.reason))
            case nil: failures.append((url, MediaError.unreadable(url.lastPathComponent).reason))
            }
        }
        return (items, failures)
    }

    /// Reads kind, duration, display size (after preferredTransform / EXIF orientation), frame
    /// rate and audio presence. Throws `MediaError` for files that cannot be used.
    public static func probe(_ url: URL) async throws -> MediaItem {
        try await probeResult(url).get()
    }

    private static func probeResult(_ url: URL) async -> Result<MediaItem, MediaError> {
        let file = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return .failure(.unsupported(file)) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing(file)) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .failure(.unreadable(file)) }
        if imageExtensions.contains(ext) { return probeImage(url) }
        do {
            return try await probeAV(url)
        } catch let error as MediaError {
            return .failure(error)
        } catch {
            return .failure(.unplayable(file))
        }
    }

    private static func displayName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    private static func probeImage(_ url: URL) -> Result<MediaItem, MediaError> {
        let file = url.lastPathComponent
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(src) > 0,
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any] else {
            return .failure(.unreadableImage(file))
        }
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { return .failure(.unreadableImage(file)) }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
        return .success(MediaItem(url: url, name: displayName(url), kind: .image, duration: 0,
                                  pixelWidth: w, pixelHeight: h))
    }

    private static func probeAV(_ url: URL) async throws -> Result<MediaItem, MediaError> {
        let file = url.lastPathComponent
        // MP3 has no reliable duration header; ask for an exact one so trims never run past the end.
        let precise = url.pathExtension.lowercased() == "mp3"
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: precise])
        let (duration, playable, tracks) = try await asset.load(.duration, .isPlayable, .tracks)

        var videoTracks: [AVAssetTrack] = []
        var audioTracks: [AVAssetTrack] = []
        for track in tracks {
            guard try await track.load(.isPlayable) else { continue }
            let type = track.mediaType
            if type == .video { videoTracks.append(track) } else if type == .audio { audioTracks.append(track) }
        }
        guard !tracks.isEmpty else { return .failure(.noTracks(file)) }
        guard playable, !(videoTracks.isEmpty && audioTracks.isEmpty) else { return .failure(.unplayable(file)) }

        var seconds = duration.isNumeric ? duration.seconds : 0
        guard seconds.isFinite, seconds > 0.001 else { return .failure(.zeroDuration(file)) }

        if let vt = videoTracks.first {
            let (natural, xf, fps, minFrame, range) = try await vt.load(.naturalSize, .preferredTransform,
                                                                         .nominalFrameRate, .minFrameDuration, .timeRange)
            let r = CGRect(origin: .zero, size: natural).applying(xf)
            let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
            guard w > 0, h > 0 else { return .failure(.unplayable(file)) }
            var rate = Double(fps)
            if !(rate > 0), minFrame.isNumeric, minFrame.seconds > 0 { rate = 1 / minFrame.seconds }
            // Clips are bounded by the picture: audio that runs past the last frame is dropped.
            let videoEnd = range.end.isNumeric ? range.end.seconds : 0
            if videoEnd.isFinite, videoEnd > 0.001 { seconds = min(seconds, videoEnd) }
            return .success(MediaItem(url: url, name: displayName(url), kind: .video, duration: seconds,
                                      pixelWidth: w, pixelHeight: h, frameRate: rate.isFinite ? rate : 0,
                                      hasAudio: !audioTracks.isEmpty))
        }
        return .success(MediaItem(url: url, name: displayName(url), kind: .audio, duration: seconds, hasAudio: true))
    }

    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }
}
