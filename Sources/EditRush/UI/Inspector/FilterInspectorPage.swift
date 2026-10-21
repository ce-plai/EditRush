import SwiftUI
import CoreImage
import EditRushCore

/// Filter preset grid with live thumbnails of the clip's media, plus the mix intensity.
struct FilterInspectorPage: View {
    let clip: Clip
    let media: MediaItem?
    @Environment(EditorStore.self) private var store
    @Environment(ThumbnailCache.self) private var thumbnails
    private let previews = InspectorFilterThumbnails.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let poster = media.flatMap { thumbnails.poster(for: $0) }
        let source = poster != nil ? (media?.id.uuidString ?? InspectorFilterThumbnails.sampleSource)
                                   : InspectorFilterThumbnails.sampleSource

        VStack(spacing: 0) {
            InspectorSection("Intensity") {
                InspectorSliderRow(
                    title: clip.filter == .none ? "No filter" : clip.filter.displayName,
                    value: edit.binding("Filter Intensity", field: "filter-intensity", get: { clip.filterIntensity * 100 },
                                        set: { $0.filterIntensity = ($1 / 100).inspectorClamped(to: 0...1) }),
                    range: 0...100, defaultValue: 100, unit: "%", onEditingChanged: edit.editingChanged)
                    .disabled(clip.filter == .none)
            }
            InspectorSection("Presets") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(FilterPreset.allCases) { preset in
                        InspectorFilterTile(preset: preset,
                                            image: previews.image(source: source, preset: preset),
                                            isSelected: clip.filter == preset) {
                            edit(preset == .none ? "Remove Filter" : "Apply \(preset.displayName)") {
                                $0.filter = preset
                                if preset != .none, $0.filterIntensity <= 0 { $0.filterIntensity = 1 }
                            }
                        }
                    }
                }
            }
        }
        .task(id: source) { previews.prepare(source: source, poster: poster) }
    }
}

/// One preset thumbnail with its name.
struct InspectorFilterTile: View {
    let preset: FilterPreset
    let image: CGImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Rectangle()
                    .fill(Theme.raised)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 2)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(3)
                    }
                }
                Text(preset.displayName)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .help(preset.displayName)
    }
}

/// Memory cache of small filter-preview images per (media, preset), rendered off the main thread
/// through `FilterRenderer` so the tiles match the compositor exactly.
@MainActor
@Observable
final class InspectorFilterThumbnails {
    static let shared = InspectorFilterThumbnails()
    /// Source key used when no poster is available yet (a built-in sample picture).
    static let sampleSource = "sample"
    private static let maxSources = 24

    private var images: [String: CGImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var sources: [String] = []

    func image(source: String, preset: FilterPreset) -> CGImage? {
        images[Self.key(source, preset)]
    }

    /// Starts rendering every preset for `source` unless it is cached or already rendering.
    func prepare(source: String, poster: CGImage?) {
        guard !inFlight.contains(source), !sources.contains(source) else { return }
        inFlight.insert(source)
        Task.detached(priority: .userInitiated) {
            let rendered = InspectorFilterRendering.renderAll(poster: poster)
            await MainActor.run { self.store(rendered, for: source) }
        }
    }

    private func store(_ rendered: [FilterPreset: CGImage], for source: String) {
        inFlight.remove(source)
        sources.append(source)
        if sources.count > Self.maxSources {
            let evicted = sources.removeFirst()
            for preset in FilterPreset.allCases { images[Self.key(evicted, preset)] = nil }
        }
        for (preset, image) in rendered { images[Self.key(source, preset)] = image }
    }

    private static func key(_ source: String, _ preset: FilterPreset) -> String { source + "|" + preset.rawValue }
}

/// Thread-safe rendering helpers for filter previews.
enum InspectorFilterRendering {
    /// Thumbnail height in pixels (tiles are ~50 pt tall on 2x displays).
    static let height: CGFloat = 100
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func renderAll(poster: CGImage?) -> [FilterPreset: CGImage] {
        guard let base = baseImage(poster: poster) else { return [:] }
        var out: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            let filtered = FilterRenderer.apply(color: .identity, filter: preset, intensity: 1, to: base)
            if let cg = context.createCGImage(filtered, from: base.extent) { out[preset] = cg }
        }
        return out
    }

    /// The poster scaled to thumbnail height, or a generated landscape when there is no poster.
    private static func baseImage(poster: CGImage?) -> CIImage? {
        guard let poster else { return sampleImage().map(CIImage.init(cgImage:)) }
        let image = CIImage(cgImage: poster)
        let scale = height / max(1, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral
        return scaled.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// A small colourful landscape so presets show their character before a poster exists.
    private static func sampleImage() -> CGImage? {
        let w = Int(height * 16 / 9), h = Int(height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.36, green: 0.55, blue: 0.92, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(h) * 0.35), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.45, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.62, y: CGFloat(h) * 0.48, width: CGFloat(h) * 0.3, height: CGFloat(h) * 0.3))
        func hill(_ color: CGColor, base: CGFloat, peak: CGFloat, peakX: CGFloat) {
            ctx.setFillColor(color)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: 0, y: CGFloat(h) * base))
            ctx.addQuadCurve(to: CGPoint(x: CGFloat(w), y: CGFloat(h) * base),
                             control: CGPoint(x: CGFloat(w) * peakX, y: CGFloat(h) * peak))
            ctx.addLine(to: CGPoint(x: CGFloat(w), y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        hill(CGColor(srgbRed: 0.22, green: 0.52, blue: 0.36, alpha: 1), base: 0.42, peak: 0.85, peakX: 0.3)
        hill(CGColor(srgbRed: 0.14, green: 0.36, blue: 0.24, alpha: 1), base: 0.22, peak: 0.55, peakX: 0.75)
        return ctx.makeImage()
    }
}
