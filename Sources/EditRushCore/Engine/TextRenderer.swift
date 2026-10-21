import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Renders `TextStyle` into an image at canvas pixel scale.
/// The rendered image size is the text clip's base `content` size for `ClipGeometry.rect`.
public enum TextRenderer {
    /// Size in canvas pixels of the rendered text (including background box padding / shadow margin).
    public static func size(for style: TextStyle, canvas: CGSize) -> CGSize {
        cache.layout(for: style, canvas: canvas).size
    }

    /// Premultiplied RGBA image of the text, `size(for:canvas:)` pixels. Cached by style+canvas.
    public static func image(for style: TextStyle, canvas: CGSize) -> CGImage? {
        cache.image(for: style, canvas: canvas)
    }

    // MARK: - Layout

    /// Everything needed to draw a style; computing it is cheap relative to rasterizing.
    struct Layout {
        let size: CGSize
        /// Fill pass and optional stroke-only pass (framesetters are created per render, as they
        /// are not safe to share between threads).
        let fill: NSAttributedString
        let stroke: NSAttributedString?
        /// Rect (y-up, image pixels) the text frame is laid out in.
        let textRect: CGRect
        /// Background box (y-up) or nil.
        let boxRect: CGRect?
        let boxRadius: CGFloat
        let fontPixelSize: CGFloat
    }

    static func makeLayout(style: TextStyle, canvas: CGSize) -> Layout {
        let px = max(4, CGFloat(style.fontSize) * canvas.height)
        let font = makeFont(family: style.fontFamily, bold: style.isBold, italic: style.isItalic, size: px)
        let text = style.text.isEmpty ? " " : style.text

        var alignment: CTTextAlignment
        switch style.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph = withUnsafeBytes(of: &alignment) { buf -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: buf.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let fill = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        // A little slack so the last line always fits in the frame path.
        let textSize = CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 2)

        let outline = max(0, CGFloat(style.outlineWidth)) * px
        var stroke: NSAttributedString?
        if outline > 0 {
            // Stroke-only pass with double width; the fill pass covers the inner half.
            stroke = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): style.outlineColor.cgColor,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): (2 * outline / px) * 100,
            ])
        }

        let hasBox = style.backgroundColor.a > 0.001
        let padX = hasBox ? (px * 0.35).rounded(.up) : 0
        let padY = hasBox ? (px * 0.18).rounded(.up) : 0
        let shadowMargin = style.shadow ? (px * 0.16).rounded(.up) : 0
        let margin = max(shadowMargin, ceil(outline) + 2)

        let boxSize = CGSize(width: textSize.width + 2 * padX, height: textSize.height + 2 * padY)
        let size = CGSize(width: boxSize.width + 2 * margin, height: boxSize.height + 2 * margin)
        let boxRect = CGRect(x: margin, y: margin, width: boxSize.width, height: boxSize.height)
        let textRect = CGRect(x: margin + padX, y: margin + padY, width: textSize.width, height: textSize.height)
        return Layout(size: size, fill: fill, stroke: stroke,
                      textRect: textRect, boxRect: hasBox ? boxRect : nil, boxRadius: px * 0.22, fontPixelSize: px)
    }

    static func render(_ layout: Layout, style: TextStyle) -> CGImage? {
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = .high

        if let box = layout.boxRect {
            ctx.setFillColor(style.backgroundColor.cgColor)
            let radius = min(layout.boxRadius, box.height / 2)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        let path = CGPath(rect: layout.textRect, transform: nil)
        if style.shadow {
            let px = layout.fontPixelSize
            ctx.setShadow(offset: CGSize(width: 0, height: -px * 0.03), blur: px * 0.1,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineJoin(.round)
        for string in [layout.stroke, layout.fill].compactMap({ $0 }) {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    /// Font for a family with bold/italic traits, falling back to the system font.
    static func makeFont(family: String, bold: Bool, italic: Bool, size: CGFloat) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]

        let familyDescriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let regular = CTFontCreateWithFontDescriptor(familyDescriptor, size, nil)
        let familyFound = (CTFontCopyFamilyName(regular) as String).caseInsensitiveCompare(family) == .orderedSame
        let base: CTFont = familyFound ? regular : CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard !traits.isEmpty else { return base }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, mask) { return styled }
        // Family lacks the combination: keep what it can do (e.g. bold without italic).
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, mask) { return b }
        if italic, let i = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, mask) { return i }
        return base
    }

    // MARK: - Cache

    private static let cache = TextRenderCache()
}

/// Thread-safe cache of text layouts and rasterized images keyed by (style, canvas).
private final class TextRenderCache: @unchecked Sendable {
    private struct Key: Hashable {
        let style: TextStyle
        let width: Double
        let height: Double
    }
    private final class Entry {
        let layout: TextRenderer.Layout
        var image: CGImage?
        var lastUse: UInt64
        init(layout: TextRenderer.Layout, lastUse: UInt64) { self.layout = layout; self.lastUse = lastUse }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let limit = 96

    func layout(for style: TextStyle, canvas: CGSize) -> TextRenderer.Layout {
        entry(for: style, canvas: canvas).layout
    }

    func image(for style: TextStyle, canvas: CGSize) -> CGImage? {
        let e = entry(for: style, canvas: canvas)
        if let img = lock.withLock({ e.image }) { return img }
        let img = TextRenderer.render(e.layout, style: style)
        lock.withLock { if e.image == nil { e.image = img } }
        return img
    }

    private func entry(for style: TextStyle, canvas: CGSize) -> Entry {
        let key = Key(style: style, width: Double(canvas.width), height: Double(canvas.height))
        if let e = lock.withLock({ () -> Entry? in
            clock += 1
            entries[key]?.lastUse = clock
            return entries[key]
        }) { return e }
        let layout = TextRenderer.makeLayout(style: style, canvas: canvas)
        return lock.withLock {
            if let existing = entries[key] { return existing }
            clock += 1
            let e = Entry(layout: layout, lastUse: clock)
            entries[key] = e
            if entries.count > limit {
                // Evict the least recently used half (typing produces many short-lived styles).
                let sorted = entries.sorted { $0.value.lastUse < $1.value.lastUse }
                for (k, _) in sorted.prefix(entries.count - limit / 2) { entries[k] = nil }
            }
            return e
        }
    }
}
