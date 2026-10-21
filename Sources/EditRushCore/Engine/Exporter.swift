import AVFoundation
import Observation

public struct ExportSettings: Hashable, Sendable {
    public enum Resolution: String, CaseIterable, Sendable { case p720 = "720p", p1080 = "1080p", p2160 = "4K", canvas = "Project Size" }
    public enum Codec: String, CaseIterable, Sendable { case h264 = "H.264", hevc = "HEVC (H.265)" }
    public enum Container: String, CaseIterable, Sendable { case mp4 = "MP4", mov = "MOV" }
    public var resolution: Resolution = .p1080
    public var codec: Codec = .h264
    public var container: Container = .mp4
    public init() {}
    /// Output pixel size for a canvas (scaled so the SHORT side matches the resolution, aspect kept, even dimensions).
    public func outputSize(for canvas: CanvasSettings) -> CGSize {
        let short: Double
        switch resolution {
        case .p720: short = 720
        case .p1080: short = 1080
        case .p2160: short = 2160
        case .canvas: return canvas.size
        }
        let s = short / Double(min(canvas.width, canvas.height))
        func even(_ v: Double) -> Double { (v / 2).rounded() * 2 }
        return CGSize(width: even(Double(canvas.width) * s), height: even(Double(canvas.height) * s))
    }

    /// AVAssetExportSession preset for the codec.
    public var presetName: String {
        switch codec {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }

    public var fileType: AVFileType { container == .mp4 ? .mp4 : .mov }
    public var fileExtension: String { container == .mp4 ? "mp4" : "mov" }
}

/// Exports a project to a movie file.
///
/// State goes idle → exporting → finished / failed / cancelled; `progress` updates ~10×/s on
/// the main actor. Only one export runs at a time.
@MainActor
@Observable
public final class Exporter {
    public enum State: Equatable { case idle, exporting, finished(URL), failed(String), cancelled }
    public private(set) var state: State = .idle
    /// 0...1
    public private(set) var progress: Double = 0

    @ObservationIgnored private var task: Task<Void, Error>?
    @ObservationIgnored private let assets: AssetCache

    public init() {
        self.assets = .shared
    }

    public init(assets: AssetCache) {
        self.assets = assets
    }

    public var isExporting: Bool { state == .exporting }

    public func export(project: Project, to url: URL, settings: ExportSettings) async {
        guard state != .exporting else { return }
        state = .exporting
        progress = 0
        let task = Task { @MainActor [assets] in
            try await self.run(project: project, to: url, settings: settings, assets: assets)
        }
        self.task = task
        do {
            try await task.value
            progress = 1
            state = .finished(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if task.isCancelled || error is CancellationError {
                state = .cancelled
            } else {
                state = .failed(error.localizedDescription)
            }
        }
        self.task = nil
    }

    public func cancel() {
        task?.cancel()
    }

    /// Returns to `.idle` after a finished / failed / cancelled export.
    public func reset() {
        guard state != .exporting else { return }
        state = .idle
        progress = 0
    }

    private func run(project: Project, to url: URL, settings: ExportSettings, assets: AssetCache) async throws {
        let size = settings.outputSize(for: project.canvas)
        let scale = Double(size.width) / Double(max(1, project.canvas.width))
        let built = try await CompositionBuilder.build(project: project, assets: assets, renderScale: scale)
        try Task.checkCancellation()
        if !built.missingMedia.isEmpty {
            throw EngineError.missingMedia(built.missingMedia.joined(separator: ", "))
        }
        guard let session = AVAssetExportSession(asset: built.composition, presetName: settings.presetName) else {
            throw EngineError.exportFailed("This preset is not available on this Mac")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = settings.container == .mp4

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let monitor = Task { @MainActor [weak self] in
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { self?.progress = p.fractionCompleted }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: settings.fileType)
    }
}

/// Renders single frames of a project (for tests, poster frames and snapshot tooling).
public enum FrameRenderer {
    public static func image(of project: Project, at t: Seconds, maxSize: CGSize? = nil, assets: AssetCache = .shared) async throws -> CGImage {
        var scale = 1.0
        if let maxSize, maxSize.width > 0, maxSize.height > 0 {
            scale = min(1, Double(maxSize.width) / Double(max(1, project.canvas.width)),
                        Double(maxSize.height) / Double(max(1, project.canvas.height)))
        }
        let built = try await CompositionBuilder.build(project: project, assets: assets, renderScale: scale)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        if let maxSize { generator.maximumSize = maxSize }
        // The last frame starts one frame before the end.
        let lastFrame = max(0, built.duration - project.canvas.frameDuration)
        let time = CMTime(seconds: max(0, min(t, lastFrame)), preferredTimescale: 6000)
        return try await generator.image(at: time).image
    }
}
