import AVFoundation
import Accelerate
import CryptoKit
import Observation

/// Audio peak envelopes for timeline waveforms.
///
/// Peaks are computed off the main actor from a mono 8 kHz mixdown of every audio track and
/// persisted to `Caches/EditRush/Waveforms`, so reopening a project shows waveforms instantly.
/// Values are NOT normalised per file (quiet recordings look quiet); each value is
/// `sqrt(absolute sample peak)`, a mild curve that keeps quiet passages visible.
/// Media whose analysis fails (e.g. a missing file) is not retried until `retryFailures(for:)`.
@MainActor
@Observable
public final class WaveformCache {
    public static let shared = WaveformCache()
    public private(set) var version = 0
    /// Envelope resolution.
    public nonisolated static let peaksPerSecond = 100.0
    nonisolated static let analysisSampleRate = 8000.0
    static let maxConcurrentJobs = 2

    /// Where computed envelopes are persisted; nil disables the disk cache.
    @ObservationIgnored public let diskCacheDirectory: URL?
    @ObservationIgnored private var peaksByURL: [URL: [Float]] = [:]
    @ObservationIgnored private var requested: Set<URL> = []
    @ObservationIgnored private var failed: Set<URL> = []
    @ObservationIgnored private var queue: [MediaItem] = []
    @ObservationIgnored private var runningJobs = 0
    @ObservationIgnored private lazy var changeThrottle = MediaChangeThrottle { [weak self] in self?.version += 1 }

    public convenience init() {
        self.init(diskCacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EditRush/Waveforms", isDirectory: true))
    }

    public init(diskCacheDirectory: URL?) {
        self.diskCacheDirectory = diskCacheDirectory
    }

    /// Peak values (0...1, see type docs) at `peaksPerSecond` over the whole media, or nil while
    /// computing. Media without audio always returns nil.
    public func peaks(for media: MediaItem) -> [Float]? {
        _ = version
        guard media.hasAudio, media.kind != .image else { return nil }
        if let peaks = peaksByURL[media.url] { return peaks }
        if requested.insert(media.url).inserted {
            queue.append(media)
            pump()
        }
        return nil
    }

    /// Forgets failed analyses for `urls` (e.g. their files came back) so the next lookup
    /// computes them again.
    public func retryFailures(for urls: some Sequence<URL>) {
        var retried = false
        for url in urls where failed.remove(url) != nil {
            requested.remove(url)
            retried = true
        }
        if retried { changeThrottle.signal() }
    }

    /// True when analysing `url` failed and has not been retried.
    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    private func pump() {
        while runningJobs < Self.maxConcurrentJobs, !queue.isEmpty {
            let media = queue.removeFirst()
            runningJobs += 1
            let directory = diskCacheDirectory
            Task { [weak self] in
                let peaks = await Task.detached(priority: .utility) {
                    await WaveformAnalyzer.loadOrCompute(url: media.url, cacheDirectory: directory)
                }.value
                guard let self else { return }
                self.runningJobs -= 1
                // Failures stay requested (no retry on every redraw) until retryFailures(for:).
                if let peaks {
                    self.peaksByURL[media.url] = peaks
                    self.changeThrottle.signal()
                } else {
                    self.failed.insert(media.url)
                }
                self.pump()
            }
        }
    }
}

/// Off-main-actor peak extraction and disk persistence.
enum WaveformAnalyzer {
    private static let magic: UInt32 = 0x4552_5746 // "ERWF"
    private static let formatVersion: UInt32 = 1

    static func loadOrCompute(url: URL, cacheDirectory: URL?) async -> [Float]? {
        let cacheFile = cacheDirectory.flatMap { dir in cacheKey(for: url).map { dir.appendingPathComponent("\($0).bin") } }
        if let cacheFile, let cached = read(cacheFile) { return cached }
        guard let peaks = await compute(url: url) else { return nil }
        if let cacheFile { write(peaks, to: cacheFile) }
        return peaks
    }

    /// Absolute peaks per 1/`peaksPerSecond` s of a mono mixdown, mapped through `sqrt`.
    static func compute(url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return tracks.isEmpty ? [] : nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: WaveformCache.analysisSampleRate,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let samplesPerPeak = Int((WaveformCache.analysisSampleRate / WaveformCache.peaksPerSecond).rounded())
        var peaks: [Float] = []
        var currentPeak: Float = 0
        var filled = 0
        var samples: [Float] = []

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            samples.withUnsafeBufferPointer { ptr in
                var i = 0
                while i < count {
                    let n = min(samplesPerPeak - filled, count - i)
                    var chunkMax: Float = 0
                    vDSP_maxmgv(ptr.baseAddress! + i, 1, &chunkMax, vDSP_Length(n))
                    currentPeak = max(currentPeak, chunkMax)
                    filled += n
                    i += n
                    if filled == samplesPerPeak {
                        peaks.append(currentPeak)
                        currentPeak = 0
                        filled = 0
                    }
                }
            }
        }
        guard reader.status == .completed else { return nil }
        if filled > 0 { peaks.append(currentPeak) }
        return peaks.map { $0.isFinite ? min(1, $0).squareRoot() : 0 }
    }

    /// Stable file identity: path, size and modification date.
    static func cacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let identity = "\(url.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ file: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count >= 12 else { return nil }
        return data.withUnsafeBytes { raw -> [Float]? in
            let header = (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                          raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                          Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            guard header.0 == magic, header.1 == formatVersion, data.count == 12 + header.2 * 4 else { return nil }
            var peaks = [Float](repeating: 0, count: header.2)
            peaks.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[12...])) }
            return peaks
        }
    }

    private static func write(_ peaks: [Float], to file: URL) {
        var data = Data(capacity: 12 + peaks.count * 4)
        withUnsafeBytes(of: magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: formatVersion) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(peaks.count)) { data.append(contentsOf: $0) }
        peaks.withUnsafeBytes { data.append(contentsOf: $0) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
