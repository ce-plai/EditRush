#!/usr/bin/env swift
// Renders the EditRush app icon with CoreGraphics and packs it into an .icns.
// Usage: swift Scripts/make_icon.swift [output.icns] [preview.png]
// Default output: Resources/AppIcon.icns (run from the repository root).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outputURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.icns")
let previewURL = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// macOS-style squircle (superellipse, n = 5) inscribed in `rect`.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, steps = 720
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        let p = CGPoint(x: rect.midX + x, y: rect.midY + y)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Draws the icon in a 1024-unit coordinate space (origin bottom-left). `detail` drops fine
/// elements (sprocket holes, highlights) at tiny sizes where they would turn into noise.
func drawIcon(_ ctx: CGContext, detail: Bool) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: tile)

    // Drop shadow + body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x15171E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2C3242), rgb(0x1A1D27), rgb(0x0F1117)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft blue bloom behind the play mark.
    ctx.drawRadialGradient(gradient([rgb(0x4D8FFF, 0.32), rgb(0x4D8FFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 560, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 560, y: 512), endRadius: 380, options: [])

    // Film-strip perforations along the top and bottom edges.
    if detail {
        for row in [CGFloat(812), 176] {
            ctx.setFillColor(rgb(0xFFFFFF, 0.11))
            let holes = 8, width: CGFloat = 52, gap: CGFloat = 30
            var x = 512 - (CGFloat(holes) * width + CGFloat(holes - 1) * gap) / 2
            for _ in 0..<holes {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: row, width: width, height: 36),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
                x += width + gap
            }
            ctx.fillPath()
        }
        ctx.setFillColor(rgb(0xFFFFFF, 0.06))
        ctx.fill(CGRect(x: 100, y: 784, width: 824, height: 4))
        ctx.fill(CGRect(x: 100, y: 236, width: 824, height: 4))
    }
    ctx.restoreGState()

    // Speed streaks (orange), tapering in from the left.
    let streaks: [(y: CGFloat, start: CGFloat, height: CGFloat)] = [(606, 228, 38), (512, 168, 46), (418, 248, 38)]
    for streak in streaks {
        let end: CGFloat = 400
        let rect = CGRect(x: streak.start, y: streak.y - streak.height / 2, width: end - streak.start, height: streak.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: streak.height / 2, cornerHeight: streak.height / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFF8A2A, 0), rgb(0xFF8A2A, 0.85), rgb(0xFFB054)], [0, 0.55, 1]),
                               start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        ctx.restoreGState()
    }

    // Rounded play triangle with a blue gradient and glow.
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 452, y: 304))
    triangle.addLine(to: CGPoint(x: 452, y: 720))
    triangle.addLine(to: CGPoint(x: 800, y: 512))
    triangle.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 36, color: rgb(0x3D7BFF, 0.6))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(triangle)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(64)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(gradient([rgb(0x8CB6FF), rgb(0x4D8FFF), rgb(0x2D63E0)], [0, 0.5, 1]),
                           start: CGPoint(x: 470, y: 760), end: CGPoint(x: 700, y: 270), options: extend)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Glossy highlight on the triangle's upper half.
    if detail {
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(triangle)
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.setStrokeColor(rgb(0xFFFFFF))
        ctx.setLineWidth(64)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.setBlendMode(.sourceIn)
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)], [0, 1]),
                               start: CGPoint(x: 0, y: 752), end: CGPoint(x: 0, y: 540), options: extend)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Hairline rim light on the tile.
    if detail {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
        ctx.setLineWidth(6)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, detail: pixels >= 64)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewURL { writePNG(render(pixels: 1024), to: previewURL) }

try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outputURL.path)")
