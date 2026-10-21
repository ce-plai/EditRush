import AVFoundation
import CoreImage

/// Everything AVFoundation needs to play or export a project.
public struct BuiltComposition {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let duration: Seconds
}

/// Turns a `Project` into AVFoundation objects (STUB — implemented by the engine module).
///
/// Design:
/// * One video composition track per timeline video track (for video-file clips), one audio
///   composition track per timeline track that carries sound (audio tracks + video clips' audio).
/// * A blank "base" video track spanning [0, duration] so the custom compositor is invoked for
///   every frame even when only images/text are present (see `BlankVideo`).
/// * A single or segmented `CompositorInstruction` (custom `AVVideoCompositionInstructionProtocol`)
///   carrying a render snapshot: canvas, background, and ordered layers (video track id /
///   CIImage for images / text style) with timing, transform, color, filter and fades.
/// * `VideoCompositor` (AVVideoCompositing) renders those layers with Core Image on Metal.
/// * AVMutableAudioMix with per-clip volume and fade ramps.
public enum CompositionBuilder {
    /// - Parameter renderScale: multiplier on canvas size for the render size (preview may use < 1).
    public static func build(project: Project, assets: AssetCache, renderScale: Double = 1) async throws -> BuiltComposition {
        throw EngineError.notImplemented
    }
}

public enum EngineError: LocalizedError {
    case notImplemented
    case missingMedia(String)
    case exportFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented"
        case .missingMedia(let n): "Missing media: \(n)"
        case .exportFailed(let m): "Export failed: \(m)"
        }
    }
}
