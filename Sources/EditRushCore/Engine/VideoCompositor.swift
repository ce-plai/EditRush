import AVFoundation
import CoreImage
import Metal

/// One visual layer of a render snapshot.
struct CompositorLayer: @unchecked Sendable {
    enum Content {
        /// A frame from a composition video track; `orientation` makes the decoded frame upright.
        case video(trackID: CMPersistentTrackID, orientation: CGAffineTransform)
        /// A still image or rendered text.
        case image(CIImage)
    }
    let content: Content
    /// Base content size passed to `ClipGeometry.rect` (media display size / text image size).
    let contentSize: CGSize
    let isText: Bool
    let clip: Clip

    /// Opacity × fade at composition time `t`; the instruction guarantees the clip is active.
    func alpha(at t: Seconds) -> Double {
        let opacity = max(0, min(1, clip.transform.opacity))
        guard clip.fadeIn > 0 || clip.fadeOut > 0 else { return opacity }
        let inside = min(max(t, clip.start), clip.end.nextDown)
        return opacity * clip.fadeFactor(at: inside)
    }
}

/// Immutable description of what to draw during one instruction's time range.
struct RenderSnapshot: @unchecked Sendable {
    let canvasSize: CGSize
    let background: CIColor
    /// Bottom → top.
    let layers: [CompositorLayer]
}

/// Custom instruction carrying a render snapshot for a contiguous time range.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let snapshot: RenderSnapshot

    init(timeRange: CMTimeRange, snapshot: RenderSnapshot, requiredTrackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.snapshot = snapshot
        self.requiredSourceTrackIDs = requiredTrackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}

/// Renders `CompositorInstruction`s with Core Image on Metal.
final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = VideoCompositor.pixelBufferAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = VideoCompositor.pixelBufferAttributes

    private let renderQueue = DispatchQueue(label: "EditRush.VideoCompositor.render", qos: .userInteractive)
    private let stateLock = NSLock()
    private var cancelGeneration = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Output size is read from each request's render context; nothing is cached per context.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let generation = stateLock.withLock { cancelGeneration }
        renderQueue.async { [self] in
            if stateLock.withLock({ cancelGeneration }) != generation {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                if let buffer = FrameCompositor.render(request) {
                    request.finish(withComposedVideoFrame: buffer)
                } else {
                    request.finish(with: EngineError.exportFailed("Could not compose frame at \(request.compositionTime.seconds)s"))
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.withLock { cancelGeneration += 1 }
    }
}

/// The per-frame drawing code, shared by the compositor.
enum FrameCompositor {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// One Metal-backed context for every compositor instance (thread-safe).
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false,
            .name: "EditRush.Compositor",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Creates the shared context and its Metal pipeline ahead of the first real frame.
    static func prewarm() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            pixelBufferAttributesForPrewarm as CFDictionary, &buffer)
        guard let buffer else { return }
        let image = CIImage(color: .red).cropped(to: rect).applyingFilter("CIColorMatrix")
            .composited(over: CIImage(color: .black).cropped(to: rect))
        context.render(image, to: buffer, bounds: rect, colorSpace: colorSpace)
    }

    private static let pixelBufferAttributesForPrewarm: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    static func render(_ request: AVAsynchronousVideoCompositionRequest) -> CVPixelBuffer? {
        guard let output = request.renderContext.newPixelBuffer() else { return nil }
        let renderSize = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        let renderRect = CGRect(origin: .zero, size: renderSize)
        guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
            context.render(CIImage(color: .black).cropped(to: renderRect), to: output, bounds: renderRect, colorSpace: colorSpace)
            return output
        }
        let image = compose(instruction.snapshot, at: request.compositionTime.seconds, renderSize: renderSize) { id in
            request.sourceFrame(byTrackID: id)
        }
        context.render(image, to: output, bounds: renderRect, colorSpace: colorSpace)
        return output
    }

    /// Builds the frame image for `snapshot` at time `t`.
    static func compose(_ snapshot: RenderSnapshot, at t: Seconds, renderSize: CGSize,
                        frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let scale = renderSize.width / max(1, snapshot.canvasSize.width)
        var result = CIImage(color: snapshot.background).cropped(to: renderRect)
        for layer in snapshot.layers {
            let alpha = layer.alpha(at: t)
            guard alpha > 0.001 else { continue }
            var image: CIImage
            switch layer.content {
            case .video(let trackID, let orientation):
                guard let buffer = frame(trackID) else { continue }
                image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
                if !orientation.isIdentity { image = image.transformed(by: orientation) }
            case .image(let still):
                image = still
            }
            let clip = layer.clip
            image = FilterRenderer.apply(color: clip.color, filter: clip.filter, intensity: clip.filterIntensity, to: image)
            guard let placed = place(image, layer: layer, canvas: snapshot.canvasSize, scale: scale) else { continue }
            image = placed
            if alpha < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            }
            result = image.composited(over: result)
        }
        return result.cropped(to: renderRect)
    }

    /// Positions `image` per `ClipGeometry.rect` (+ flips and clockwise rotation) in the y-up
    /// render space scaled by `scale`.
    static func place(_ image: CIImage, layer: CompositorLayer, canvas: CGSize, scale: CGFloat) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let xf = layer.clip.transform
        let rect = ClipGeometry.rect(content: layer.contentSize, canvas: canvas, transform: xf, isText: layer.isText)
        guard rect.width > 0.01, rect.height > 0.01 else { return nil }

        let radians = xf.rotation * .pi / 180
        var m = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
        m = m.concatenating(CGAffineTransform(scaleX: (xf.flipHorizontal ? -1 : 1) * rect.width / extent.width,
                                              y: (xf.flipVertical ? -1 : 1) * rect.height / extent.height))
        // Clockwise on screen is a negative angle in y-up space.
        if radians != 0 { m = m.concatenating(CGAffineTransform(rotationAngle: -radians)) }
        m = m.concatenating(CGAffineTransform(translationX: rect.midX, y: canvas.height - rect.midY))
        m = m.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let quarterTurns = xf.rotation / 90
        let axisAligned = abs(quarterTurns - quarterTurns.rounded()) < 1e-6
        let downscale = min(rect.width / extent.width, rect.height / extent.height) * scale
        if axisAligned {
            // Clamp then crop so edges stay crisp instead of fading into transparency.
            let target = extent.applying(m).standardized
            return image.clampedToExtent()
                .transformed(by: m, highQualityDownsample: downscale < 0.5)
                .cropped(to: target)
        }
        return image.transformed(by: m, highQualityDownsample: downscale < 0.5)
    }
}
