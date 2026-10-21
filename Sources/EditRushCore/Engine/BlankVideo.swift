import AVFoundation

/// A tiny black H.264 movie inserted as the composition's base video track, so the custom
/// compositor is invoked for every frame even when only images / text are on screen.
/// Written once to `~/Library/Caches/EditRush/` and reused.
enum BlankVideo {
    static let size = 64
    static let frameRate: Int32 = 30
    static let frameCount = 30

    struct Source: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let timeRange: CMTimeRange
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loadTask: Task<Source, Error>?

    /// The loaded blank track (created on first use; concurrent callers share one load).
    static func source() async throws -> Source {
        let task: Task<Source, Error> = lock.withLock {
            if let loadTask { return loadTask }
            let t = Task<Source, Error> { try await load() }
            loadTask = t
            return t
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { loadTask = nil }
            throw error
        }
    }

    static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("EditRush", isDirectory: true).appendingPathComponent("blank-v1.mov")
    }

    private static func load() async throws -> Source {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path), let source = try? await open(url) {
            return source
        }
        try await write(to: url)
        return try await open(url)
    }

    private static func open(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EngineError.exportFailed("Blank video track missing")
        }
        let range = try await track.load(.timeRange)
        guard range.duration.seconds > 0 else { throw EngineError.exportFailed("Blank video is empty") }
        return Source(asset: asset, track: track, timeRange: range)
    }

    private static func write(to url: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent("blank-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: temp) }

        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EngineError.exportFailed("Blank video writer failed") }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw EngineError.exportFailed("Could not allocate blank frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: CMTimeValue(i), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? EngineError.exportFailed("Blank video append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: frameRate))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EngineError.exportFailed("Blank video writing failed")
        }
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        do {
            try fm.moveItem(at: temp, to: url)
        } catch {
            // Another process may have just written it.
            guard fm.fileExists(atPath: url.path) else { throw error }
        }
    }
}
