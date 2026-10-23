import Foundation
import CoreGraphics

// MARK: - Conventions (shared contract — read before touching engine/UI code)
//
// * All times in the model are `Seconds` (Double). Convert to CMTime only inside the engine
//   (`CMTime(seconds:preferredTimescale: 600)`). Edit operations quantize to canvas frames.
// * Canvas space: pixels of the project canvas (e.g. 1920x1080), origin TOP-LEFT, +y DOWN.
//   Core Image is bottom-left/+y up — the engine converts; the model and UI never do.
// * Video track render order: video tracks are composited in the order they appear in
//   `Project.tracks` (first video track = bottom layer, "V1"). The timeline UI shows video
//   tracks in reverse order (top row = top layer) above the audio tracks.
// * Video tracks hold video, image and text clips. Audio tracks hold audio clips only.
//   A video clip's embedded audio plays from the video clip itself (controlled by
//   `volume` / `audioMuted`) until it is detached onto an audio track. `audioMuted` silences
//   a clip's audio on any track.
// * Clips on one track never overlap and `Track.clips` is kept sorted by `start`.
// * Fades: a clip's opacity (video) and volume (audio) are multiplied by
//   `Clip.fadeFactor(at:)`. On the bottom layer over the black background that is
//   "fade from/to black"; on upper layers it reveals the layers below (a dissolve).

public typealias Seconds = Double

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video, audio, image
}

public struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var name: String
    public var kind: MediaKind
    /// Source duration in seconds. Images: 0 (unbounded — clips may be any length).
    public var duration: Seconds
    /// Display size in pixels AFTER applying the track's preferredTransform / EXIF orientation.
    /// Zero for audio-only media.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Nominal video frame rate (0 for audio/images).
    public var frameRate: Double
    /// True when a video file also carries an audio track (always true for audio media).
    public var hasAudio: Bool

    public init(id: UUID = UUID(), url: URL, name: String, kind: MediaKind, duration: Seconds,
                pixelWidth: Int = 0, pixelHeight: Int = 0, frameRate: Double = 0, hasAudio: Bool = false) {
        self.id = id; self.url = url; self.name = name; self.kind = kind; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.frameRate = frameRate; self.hasAudio = hasAudio
    }

    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    public var hasVisual: Bool { kind != .audio }
}

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public enum FitMode: String, Codable, Sendable, CaseIterable {
    /// Aspect-fit inside the canvas (letterbox). Default.
    case fit
    /// Aspect-fill the canvas (crop).
    case fill
}

public struct ClipTransform: Codable, Hashable, Sendable {
    /// Uniform scale applied after the content is fit/filled to the canvas. 1 = fitted size.
    /// For text clips the base size is the rendered text size (see `ClipGeometry`).
    public var scale: Double = 1
    /// Offset of the clip centre from the canvas centre, as a fraction of canvas width / height.
    /// +x = right, +y = DOWN. (0.5, 0) puts the centre on the right canvas edge.
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// Rotation in degrees, clockwise as seen on screen, about the clip centre.
    public var rotation: Double = 0
    /// 0...1
    public var opacity: Double = 1
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false
    public var fitMode: FitMode = .fit

    public init() {}
    public static let identity = ClipTransform()
    public var isIdentity: Bool { self == .identity }
}

public struct ColorAdjustments: Codable, Hashable, Sendable {
    /// Exposure in EV stops, -2...2 (CIExposureAdjust).
    public var exposure: Double = 0
    /// -1...1, 0 = unchanged (CIColorControls inputBrightness; UI should limit to about -0.5...0.5).
    public var brightness: Double = 0
    /// 0.25...2, 1 = unchanged (CIColorControls inputContrast).
    public var contrast: Double = 1
    /// 0...2, 1 = unchanged (CIColorControls inputSaturation).
    public var saturation: Double = 1
    /// -1 (cooler/blue) ... 1 (warmer/orange), 0 = unchanged (CITemperatureAndTint).
    public var temperature: Double = 0
    /// 0...1 vignette strength, 0 = none (CIVignette).
    public var vignette: Double = 0

    public init() {}
    public static let identity = ColorAdjustments()
    public var isIdentity: Bool { self == .identity }
}

public enum FilterPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, vivid, warm, cool, mono, noir, sepia, chrome, fade, instant, process, tonal, transfer, blur, sharpen, comic
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .mono: "Mono"
        case .noir: "Noir"
        case .sepia: "Sepia"
        case .chrome: "Chrome"
        case .fade: "Faded"
        case .instant: "Instant"
        case .process: "Process"
        case .tonal: "Tonal"
        case .transfer: "Transfer"
        case .blur: "Soft Blur"
        case .sharpen: "Sharpen"
        case .comic: "Comic"
        }
    }
}

public enum TextAlignmentOption: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var text: String = "Title"
    /// Font family name, e.g. "Helvetica Neue", "Avenir Next", "Georgia".
    public var fontFamily: String = "Helvetica Neue"
    public var isBold: Bool = true
    public var isItalic: Bool = false
    /// Font size as a fraction of canvas HEIGHT (0.1 on a 1080p canvas = 108 px).
    public var fontSize: Double = 0.1
    public var color: RGBA = .white
    /// Box behind the text; alpha 0 = no box.
    public var backgroundColor: RGBA = .clear
    public var alignment: TextAlignmentOption = .center
    public var shadow: Bool = true
    /// Outline stroke width as a fraction of font size; 0 = none.
    public var outlineWidth: Double = 0
    public var outlineColor: RGBA = .black

    public init(text: String = "Title") { self.text = text }
}

public struct Clip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    /// Media this clip plays. nil for text clips.
    public var mediaID: UUID?
    /// Non-nil for text (title) clips.
    public var text: TextStyle?
    /// Timeline position of the clip's first frame.
    public var start: Seconds
    /// Timeline length.
    public var duration: Seconds
    /// Offset into the source media where playback starts (0 for images/text).
    public var sourceIn: Seconds = 0
    /// Playback rate of the source (video/audio only): 2 = twice as fast, 0.5 = half speed.
    /// The clip plays `duration * speed` seconds of source; audio keeps its pitch.
    public var speed: Double = 1

    public var transform = ClipTransform()
    public var color = ColorAdjustments()
    public var filter: FilterPreset = .none
    /// 0...1 mix between the unfiltered and filtered image.
    public var filterIntensity: Double = 1

    /// Seconds of fade-in from transparent/silent at the clip start (0 = none).
    public var fadeIn: Seconds = 0
    /// Seconds of fade-out to transparent/silent at the clip end (0 = none).
    public var fadeOut: Seconds = 0

    /// Linear gain 0...2 for the clip's audio (audio clips and video clips with sound).
    public var volume: Double = 1
    /// Silences the clip's audio on any track: an audio clip, detached audio, or a video clip's
    /// embedded audio (set on the video clip when its audio is detached).
    public var audioMuted: Bool = false

    /// Optional user label shown on the timeline instead of the media name.
    public var label: String?

    public init(mediaID: UUID?, start: Seconds, duration: Seconds, sourceIn: Seconds = 0, text: TextStyle? = nil) {
        self.mediaID = mediaID; self.start = start; self.duration = duration; self.sourceIn = sourceIn; self.text = text
    }

    /// Slowest and fastest `speed` (10 % … 1000 %).
    public static let speedRange: ClosedRange<Double> = 0.1...10

    public var end: Seconds { start + duration }
    public var sourceOut: Seconds { sourceIn + duration * speed }
    public var isText: Bool { text != nil }
    public func contains(_ t: Seconds) -> Bool { t >= start && t < end }

    /// Opacity / volume multiplier from fades at timeline time `t` (0...1).
    public func fadeFactor(at t: Seconds) -> Double {
        guard contains(t) else { return 0 }
        var f = 1.0
        if fadeIn > 0 { f = min(f, (t - start) / fadeIn) }
        if fadeOut > 0 { f = min(f, (end - t) / fadeOut) }
        return max(0, min(1, f))
    }
}

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var kind: TrackKind
    /// Sorted by `start`, non-overlapping.
    public var clips: [Clip] = []
    public var isMuted: Bool = false
    /// Hidden video tracks are not rendered.
    public var isHidden: Bool = false
    /// Locked tracks reject edits.
    public var isLocked: Bool = false

    public init(kind: TrackKind) { self.kind = kind }

    public var end: Seconds { clips.map(\.end).max() ?? 0 }
    public func accepts(_ kind: MediaKind?) -> Bool {
        switch self.kind {
        case .video: return kind != .audio      // nil = text clip
        case .audio: return kind == .audio
        }
    }
}

public enum TrackKind: String, Codable, Sendable { case video, audio }

public struct CanvasSettings: Codable, Hashable, Sendable {
    public var width: Int = 1920
    public var height: Int = 1080
    public var frameRate: Double = 30
    public var backgroundColor: RGBA = .black

    public init(width: Int = 1920, height: Int = 1080, frameRate: Double = 30) {
        self.width = width; self.height = height; self.frameRate = frameRate
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    public var aspect: Double { Double(width) / Double(max(1, height)) }
    public var frameDuration: Seconds { 1.0 / max(1, frameRate) }
    /// Rounds `t` to the nearest frame boundary.
    public func quantize(_ t: Seconds) -> Seconds { (t * frameRate).rounded() / frameRate }

    public static let presets: [(name: String, settings: CanvasSettings)] = [
        ("Landscape 16:9 (1080p)", CanvasSettings(width: 1920, height: 1080)),
        ("Landscape 16:9 (4K)", CanvasSettings(width: 3840, height: 2160)),
        ("Portrait 9:16", CanvasSettings(width: 1080, height: 1920)),
        ("Square 1:1", CanvasSettings(width: 1080, height: 1080)),
        ("Social 4:5", CanvasSettings(width: 1080, height: 1350)),
    ]
}

public struct Project: Codable, Hashable, Sendable {
    public static let fileExtension = "editrush"
    public static let currentVersion = 1

    public var version: Int = Project.currentVersion
    public var name: String = "Untitled"
    public var canvas = CanvasSettings()
    public var media: [MediaItem] = []
    /// Mixed video + audio tracks. Video tracks render in array order (first = bottom).
    public var tracks: [Track] = []

    public init() {}

    /// A fresh project with two video tracks and two audio tracks.
    public static func empty() -> Project {
        var p = Project()
        p.tracks = [Track(kind: .video), Track(kind: .video), Track(kind: .audio), Track(kind: .audio)]
        return p
    }

    public var duration: Seconds { tracks.map(\.end).max() ?? 0 }
    public var videoTracks: [Track] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }

    public func media(_ id: UUID?) -> MediaItem? {
        guard let id else { return nil }
        return media.first { $0.id == id }
    }
    public func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }
    /// (track index, clip index) of a clip.
    public func locate(clip id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }
    public func clip(_ id: UUID) -> Clip? {
        guard let l = locate(clip: id) else { return nil }
        return tracks[l.track].clips[l.clip]
    }
    public func track(containing clipID: UUID) -> Track? {
        guard let l = locate(clip: clipID) else { return nil }
        return tracks[l.track]
    }
    /// 1-based display name, e.g. "V1", "V2", "A1".
    public func displayName(of trackID: UUID) -> String {
        guard let t = tracks.first(where: { $0.id == trackID }) else { return "?" }
        let same = tracks.filter { $0.kind == t.kind }
        let n = (same.firstIndex { $0.id == trackID } ?? 0) + 1
        return (t.kind == .video ? "V" : "A") + String(n)
    }
}

// MARK: - Geometry shared by the compositor and the preview overlay

public enum ClipGeometry {
    /// Content size in canvas pixels before the user's `scale`, i.e. the content fit/filled to the canvas.
    public static func baseSize(content: CGSize, canvas: CGSize, fit: FitMode) -> CGSize {
        guard content.width > 0, content.height > 0 else { return canvas }
        let sx = canvas.width / content.width, sy = canvas.height / content.height
        let s = fit == .fit ? min(sx, sy) : max(sx, sy)
        return CGSize(width: content.width * s, height: content.height * s)
    }

    /// The clip's displayed rectangle BEFORE rotation, in canvas space (top-left origin, +y down).
    /// Rotation (`transform.rotation`, clockwise degrees) is applied about this rect's centre.
    /// - Parameter content: media pixel size, or for text clips the rendered text image size
    ///   (text is not fit to the canvas; its base size is its rendered size).
    public static func rect(content: CGSize, canvas: CGSize, transform: ClipTransform, isText: Bool) -> CGRect {
        let base = isText ? content : baseSize(content: content, canvas: canvas, fit: transform.fitMode)
        let w = base.width * transform.scale, h = base.height * transform.scale
        let cx = canvas.width / 2 + transform.offsetX * canvas.width
        let cy = canvas.height / 2 + transform.offsetY * canvas.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Decoding
//
// Project files may be written by hand or by tools, so any field with a default can be left out.
// Required: Project `tracks`, MediaItem `id` / `url` / `kind`, Clip `start` / `duration`, Track `kind`,
// RGBA `r` / `g` / `b`.
// A media `url` may also be a plain path; relative paths resolve against the project file's folder
// (`CodingUserInfoKey.projectDirectory`).

extension CodingUserInfoKey {
    /// Folder of the project file being decoded (a `URL`), for relative media paths.
    static let projectDirectory = CodingUserInfoKey(rawValue: "EditRush.projectDirectory")!
}

extension KeyedDecodingContainer {
    /// Decodes `key` into `value` when present, otherwise leaves the default.
    func fill<T: Decodable>(_ value: inout T, _ key: Key) throws {
        if let v = try decodeIfPresent(T.self, forKey: key) { value = v }
    }
}

extension MediaItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .url)
        let url: URL
        if raw.contains("://"), let u = URL(string: raw) {
            url = u
        } else {
            let base = decoder.userInfo[.projectDirectory] as? URL
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, relativeTo: base).absoluteURL.standardizedFileURL
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), url: url,
                  name: url.deletingPathExtension().lastPathComponent,
                  kind: try c.decode(MediaKind.self, forKey: .kind), duration: 0)
        try c.fill(&name, .name)
        try c.fill(&duration, .duration)
        try c.fill(&pixelWidth, .pixelWidth)
        try c.fill(&pixelHeight, .pixelHeight)
        try c.fill(&frameRate, .frameRate)
        try c.fill(&hasAudio, .hasAudio)
    }
}

extension RGBA {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Double.self, forKey: .r), try c.decode(Double.self, forKey: .g),
                  try c.decode(Double.self, forKey: .b), try c.decodeIfPresent(Double.self, forKey: .a) ?? 1)
    }
}

extension ClipTransform {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&scale, .scale)
        try c.fill(&offsetX, .offsetX)
        try c.fill(&offsetY, .offsetY)
        try c.fill(&rotation, .rotation)
        try c.fill(&opacity, .opacity)
        try c.fill(&flipHorizontal, .flipHorizontal)
        try c.fill(&flipVertical, .flipVertical)
        try c.fill(&fitMode, .fitMode)
    }
}

extension ColorAdjustments {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&exposure, .exposure)
        try c.fill(&brightness, .brightness)
        try c.fill(&contrast, .contrast)
        try c.fill(&saturation, .saturation)
        try c.fill(&temperature, .temperature)
        try c.fill(&vignette, .vignette)
    }
}

extension TextStyle {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&text, .text)
        try c.fill(&fontFamily, .fontFamily)
        try c.fill(&isBold, .isBold)
        try c.fill(&isItalic, .isItalic)
        try c.fill(&fontSize, .fontSize)
        try c.fill(&color, .color)
        try c.fill(&backgroundColor, .backgroundColor)
        try c.fill(&alignment, .alignment)
        try c.fill(&shadow, .shadow)
        try c.fill(&outlineWidth, .outlineWidth)
        try c.fill(&outlineColor, .outlineColor)
    }
}

extension Clip {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mediaID: try c.decodeIfPresent(UUID.self, forKey: .mediaID),
                  start: try c.decode(Seconds.self, forKey: .start),
                  duration: try c.decode(Seconds.self, forKey: .duration),
                  text: try c.decodeIfPresent(TextStyle.self, forKey: .text))
        try c.fill(&id, .id)
        try c.fill(&sourceIn, .sourceIn)
        try c.fill(&speed, .speed)
        try c.fill(&transform, .transform)
        try c.fill(&color, .color)
        try c.fill(&filter, .filter)
        try c.fill(&filterIntensity, .filterIntensity)
        try c.fill(&fadeIn, .fadeIn)
        try c.fill(&fadeOut, .fadeOut)
        try c.fill(&volume, .volume)
        try c.fill(&audioMuted, .audioMuted)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

extension Track {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(TrackKind.self, forKey: .kind))
        try c.fill(&id, .id)
        try c.fill(&clips, .clips)
        try c.fill(&isMuted, .isMuted)
        try c.fill(&isHidden, .isHidden)
        try c.fill(&isLocked, .isLocked)
    }
}

extension CanvasSettings {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&width, .width)
        try c.fill(&height, .height)
        try c.fill(&frameRate, .frameRate)
        try c.fill(&backgroundColor, .backgroundColor)
    }
}

extension Project {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&version, .version)
        try c.fill(&name, .name)
        try c.fill(&canvas, .canvas)
        try c.fill(&media, .media)
        tracks = try c.decode([Track].self, forKey: .tracks)
    }
}
