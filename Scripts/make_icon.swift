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

/// Draws the icon in a 1024-unit coordinate space (origin bottom-left): the "cut" logo from
/// Resources/Logo.svg on a squircle tile. `detail` drops the rim light at tiny sizes.
func drawIcon(_ ctx: CGContext, detail: Bool) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: tile)
    // Logo.svg's 100-unit, y-down space mapped onto the tile.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * tile.width / 100, y: tile.maxY - y * tile.height / 100)
    }
    func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    // Drop shadow + black body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Yellow motion trails off the cut's top and bottom ends, fading out.
    let trails: [(points: [CGPoint], from: CGPoint, to: CGPoint)] = [
        ([p(39.748, 2.42), p(47.871, 2.42), p(42, 25), p(26.015, 28.285)], p(42, 25), p(37.334, 22.293)),
        ([p(42.252, 97.58), p(34.129, 97.58), p(40, 75), p(55.985, 71.715)], p(40, 75), p(44.666, 77.707)),
    ]
    for trail in trails {
        ctx.saveGState()
        ctx.addPath(polygon(trail.points))
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFC900), rgb(0xFBB03B, 0)], [0, 1]),
                               start: trail.from, end: trail.to, options: extend)
        ctx.restoreGState()
    }

    // The two halves of the cut frame.
    ctx.addPath(polygon([p(17, 25), p(42, 25), p(29, 75), p(17, 75)]))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.addPath(polygon([p(53, 25), p(83, 25), p(83, 75), p(40, 75)]))
    ctx.setFillColor(rgb(0xFF6633))
    ctx.fillPath()

    // Hairline rim light so the black tile reads on a dark Dock.
    if detail {
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
        ctx.setLineWidth(6)
        ctx.strokePath()
    }
    ctx.restoreGState()
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
