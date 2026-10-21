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
}

/// Exports a project to a movie file (STUB — engine module).
@MainActor
@Observable
public final class Exporter {
    public enum State: Equatable { case idle, exporting, finished(URL), failed(String), cancelled }
    public private(set) var state: State = .idle
    /// 0...1
    public private(set) var progress: Double = 0

    public init() {}
    public func export(project: Project, to url: URL, settings: ExportSettings) async {}
    public func cancel() {}
}

/// Renders single frames of a project (for tests, poster frames and snapshot tooling). (STUB)
public enum FrameRenderer {
    public static func image(of project: Project, at t: Seconds, maxSize: CGSize? = nil, assets: AssetCache = .shared) async throws -> CGImage {
        throw EngineError.notImplemented
    }
}
