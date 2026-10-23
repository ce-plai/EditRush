import XCTest
import AVFoundation
import CoreImage
@testable import EditRushCore

final class EngineTests: XCTestCase {
    // Canvas 1280x720 rendered at half size keeps tests fast.
    let canvas = CanvasSettings(width: 1280, height: 720, frameRate: 30)
    let renderSize = CGSize(width: 640, height: 360)

    // MARK: - Helpers

    struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]
        /// RGB (0...255) at pixel (x, y) with y measured from the TOP.
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let cx = max(0, min(width - 1, x)), cy = max(0, min(height - 1, y))
            let i = (cy * width + cx) * 4
            return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }
        /// Sample at a fraction of the frame (0...1, y from the top).
        func rgb(fx: Double, fy: Double) -> (r: Double, g: Double, b: Double) {
            rgb(Int(fx * Double(width - 1)), Int(fy * Double(height - 1)))
        }
        func brightness(_ x: Int, _ y: Int) -> Double { let p = rgb(x, y); return (p.r + p.g + p.b) / 3 }
    }

    /// Raw pixel values of a frame (drawn in the image's own RGB colour space, so no conversion).
    func pixels(_ image: CGImage) -> Pixels {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, data: data)
    }

    func render(_ project: Project, at t: Seconds) async throws -> Pixels {
        let image = try await FrameRenderer.image(of: project, at: t, maxSize: renderSize)
        XCTAssertEqual(image.width, Int(renderSize.width))
        XCTAssertEqual(image.height, Int(renderSize.height))
        return pixels(image)
    }

    func media(_ name: String) async throws -> MediaItem {
        try await MediaImporter.probe(Fixture.url(name))
    }

    func makeProject(_ media: [MediaItem]) -> Project {
        var p = Project.empty()
        p.canvas = canvas
        p.media = media
        return p
    }

    func assertColor(_ p: (r: Double, g: Double, b: Double), _ r: Double, _ g: Double, _ b: Double,
                     tolerance: Double = 32, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let ok = abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
        XCTAssertTrue(ok, "\(message) expected ≈(\(r), \(g), \(b)) got (\(p.r), \(p.g), \(p.b))", file: file, line: line)
    }

    func isBlack(_ p: (r: Double, g: Double, b: Double)) -> Bool { p.r < 20 && p.g < 20 && p.b < 20 }

    // MARK: - Rendering

    func testSolidRedFullFrame() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 3)]
        let px = try await render(p, at: 1)
        assertColor(px.rgb(fx: 0.5, fy: 0.5), 255, 0, 0, "center")
        assertColor(px.rgb(1, 1), 255, 0, 0, "top-left edge stays crisp")
        assertColor(px.rgb(px.width - 2, px.height - 2), 255, 0, 0, "bottom-right edge")
    }

    func testScaleAndOffset() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        var c = Clip(mediaID: red.id, start: 0, duration: 3)
        c.transform.scale = 0.5
        c.transform.offsetX = 0.25
        c.transform.offsetY = 0.25
        p.tracks[0].clips = [c]
        let px = try await render(p, at: 1)
        // The clip fills the bottom-right quadrant.
        assertColor(px.rgb(fx: 0.75, fy: 0.75), 255, 0, 0, "bottom-right quadrant")
        assertColor(px.rgb(fx: 0.95, fy: 0.95), 255, 0, 0, "near bottom-right corner")
        XCTAssertTrue(isBlack(px.rgb(2, 2)), "top-left corner")
        XCTAssertTrue(isBlack(px.rgb(fx: 0.75, fy: 0.25)), "top-right quadrant")
        XCTAssertTrue(isBlack(px.rgb(fx: 0.25, fy: 0.75)), "bottom-left quadrant")
        XCTAssertTrue(isBlack(px.rgb(px.width - 2, 2)), "top-right corner")
    }

    func testFadeInMidpointIsHalfBrightness() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        var c = Clip(mediaID: red.id, start: 0, duration: 3)
        c.fadeIn = 2
        p.tracks[0].clips = [c]
        let mid = try await render(p, at: 1)
        assertColor(mid.rgb(fx: 0.5, fy: 0.5), 128, 0, 0, tolerance: 25, "fade midpoint")
        let start = try await render(p, at: 0)
        XCTAssertTrue(isBlack(start.rgb(fx: 0.5, fy: 0.5)), "first frame of a fade-in is black")
    }

    func testUpperTrackCompositesOverLower() async throws {
        let red = try await media("solid_red.mp4"), blue = try await media("solid_blue.mov")
        var p = makeProject([red, blue])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 3)]
        var top = Clip(mediaID: blue.id, start: 0, duration: 3)
        top.transform.scale = 0.5
        p.tracks[1].clips = [top]
        let px = try await render(p, at: 1)
        assertColor(px.rgb(fx: 0.5, fy: 0.5), 0, 0, 255, "center is V2")
        assertColor(px.rgb(4, 4), 255, 0, 0, "corner is V1")
    }

    func testHiddenTrackIsNotRendered() async throws {
        let red = try await media("solid_red.mp4"), blue = try await media("solid_blue.mov")
        var p = makeProject([red, blue])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 3)]
        p.tracks[1].clips = [Clip(mediaID: blue.id, start: 0, duration: 3)]
        p.tracks[1].isHidden = true
        let px = try await render(p, at: 1)
        assertColor(px.rgb(fx: 0.5, fy: 0.5), 255, 0, 0)
    }

    func testImageClipOnly() async throws {
        let green = try await media("solid_green.png")
        var p = makeProject([green])
        p.tracks[0].clips = [Clip(mediaID: green.id, start: 0, duration: 2)]
        let px = try await render(p, at: 1)
        assertColor(px.rgb(fx: 0.5, fy: 0.5), 0, 255, 0, "square image centred")
        // 400x400 fit into 1280x720 → 720x720 centred: pillarboxed.
        XCTAssertTrue(isBlack(px.rgb(10, px.height / 2)), "left pillar")
        XCTAssertTrue(isBlack(px.rgb(px.width - 10, px.height / 2)), "right pillar")
        assertColor(px.rgb(px.width / 2 - 170, px.height / 2), 0, 255, 0, "inside the square")
    }

    func testTransparentLogoKeepsLayerBelow() async throws {
        let red = try await media("solid_red.mp4"), logo = try await media("logo.png")
        var p = makeProject([red, logo])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 3)]
        p.tracks[1].clips = [Clip(mediaID: logo.id, start: 0, duration: 3)]
        let px = try await render(p, at: 1)
        assertColor(px.rgb(fx: 0.5, fy: 0.5), 255, 200, 0, "logo disc")
        // The logo square is 360x360 render pixels centred; its corners are transparent.
        assertColor(px.rgb(px.width / 2 - 170, px.height / 2 - 170), 255, 0, 0, "transparent corner of logo")
    }

    func testRotation90ChangesShape() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        var c = Clip(mediaID: red.id, start: 0, duration: 3)
        c.transform.scale = 0.5
        c.transform.rotation = 90
        p.tracks[0].clips = [c]
        let px = try await render(p, at: 1)
        // Unrotated rect: 320x180 at render scale (x 160...480, y 90...270). Rotated: 180x320 (x 230...410, y 20...340).
        assertColor(px.rgb(320, 40), 255, 0, 0, "rotated rect extends vertically")
        assertColor(px.rgb(320, 320), 255, 0, 0, "rotated rect extends vertically (bottom)")
        XCTAssertTrue(isBlack(px.rgb(190, 180)), "unrotated horizontal extent is gone (left)")
        XCTAssertTrue(isBlack(px.rgb(450, 180)), "unrotated horizontal extent is gone (right)")
    }

    func testRotationIsClockwise() async throws {
        let white = try await media("solid_white.jpg")
        var p = makeProject([white])
        var c = Clip(mediaID: white.id, start: 0, duration: 2)
        c.transform.rotation = 30
        p.tracks[0].clips = [c]
        let px = try await render(p, at: 0.5)
        // 800x600 fit → 480x360 render pixels centred. Turning 30° clockwise lifts the top-left
        // corner above the frame and drops the top-right corner, so near the top edge the left
        // side is covered and the right side is uncovered.
        XCTAssertGreaterThan(px.brightness(210, 20), 200, "clockwise rotation raises the left side")
        XCTAssertLessThan(px.brightness(430, 20), 30, "clockwise rotation lowers the right side")
    }

    func testRotatedPortraitIsPillarboxed() async throws {
        let portrait = try await media("rotated_portrait.mov")
        XCTAssertEqual(portrait.pixelWidth, 720)
        XCTAssertEqual(portrait.pixelHeight, 1280)
        var p = makeProject([portrait])
        p.tracks[0].clips = [Clip(mediaID: portrait.id, start: 0, duration: 3)]
        let px = try await render(p, at: 1)
        // 720x1280 fit into 640x360 render → 202.5 wide, x ≈ 219...421.
        for y in stride(from: 10, to: 350, by: 40) {
            XCTAssertTrue(isBlack(px.rgb(5, y)), "left pillar at y=\(y)")
            XCTAssertTrue(isBlack(px.rgb(200, y)), "left of picture at y=\(y)")
            XCTAssertTrue(isBlack(px.rgb(440, y)), "right of picture at y=\(y)")
            XCTAssertTrue(isBlack(px.rgb(634, y)), "right pillar at y=\(y)")
        }
        let column = stride(from: 5, to: 355, by: 5).map { px.brightness(320, $0) }
        XCTAssertGreaterThan(column.max() ?? 0, 60, "picture visible in the centre column")
        let topRow = stride(from: 230, to: 410, by: 5).map { px.brightness($0, 3) }
        XCTAssertGreaterThan(topRow.max() ?? 0, 30, "picture spans the full height")
    }

    func testColorAdjustmentsDirection() async throws {
        let red = try await media("solid_red.mp4"), white = try await media("solid_white.jpg")
        var p = makeProject([red, white])
        var c = Clip(mediaID: red.id, start: 0, duration: 3)
        c.color.saturation = 0
        p.tracks[0].clips = [c]
        let gray = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        XCTAssertLessThan(abs(gray.r - gray.g), 12, "saturation 0 → gray \(gray)")
        XCTAssertLessThan(abs(gray.g - gray.b), 12, "saturation 0 → gray \(gray)")
        XCTAssertGreaterThan(gray.r, 20)

        var w = Clip(mediaID: white.id, start: 0, duration: 3)
        w.color.brightness = -0.3
        p.tracks[0].clips = [w]
        let darker = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        XCTAssertLessThan(darker.r, 215, "negative brightness darkens")

        w.color.brightness = 0
        w.color.exposure = -1
        p.tracks[0].clips = [w]
        let neutral = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        w.color.temperature = 0.7
        p.tracks[0].clips = [w]
        let warm = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        w.color.temperature = -0.7
        p.tracks[0].clips = [w]
        let cool = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        func ratio(_ p: (r: Double, g: Double, b: Double)) -> Double { (p.r + 1) / (p.b + 1) }
        XCTAssertGreaterThan(ratio(warm), ratio(neutral) * 1.1, "warmer: R/B up (neutral \(neutral), warm \(warm))")
        XCTAssertLessThan(ratio(cool), ratio(neutral) / 1.1, "cooler: R/B down (neutral \(neutral), cool \(cool))")
    }

    func testFilterPresetIntensity() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        var c = Clip(mediaID: red.id, start: 0, duration: 3)
        c.filter = .mono
        p.tracks[0].clips = [c]
        let mono = try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5)
        XCTAssertLessThan(abs(mono.r - mono.b), 12, "mono is gray \(mono)")
        c.filterIntensity = 0
        p.tracks[0].clips = [c]
        assertColor(try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5), 255, 0, 0, "intensity 0 = unfiltered")
    }

    func testTextClipRendersAtExpectedLocation() async throws {
        var p = makeProject([])
        var style = TextStyle(text: "HELLO")
        style.fontSize = 0.2
        style.shadow = false
        var c = Clip(mediaID: nil, start: 0, duration: 2, text: style)
        c.transform.offsetY = -0.25
        p.tracks[0].clips = [c]
        let px = try await render(p, at: 1)
        let size = TextRenderer.size(for: style, canvas: canvas.size)
        let rect = ClipGeometry.rect(content: size, canvas: canvas.size, transform: c.transform, isText: true)
        let s = renderSize.width / canvas.size.width
        var inside = 0, outside = 0
        for y in 0..<px.height {
            for x in stride(from: 0, to: px.width, by: 2) where px.brightness(x, y) > 200 {
                let canvasPoint = CGPoint(x: (Double(x) + 0.5) / s, y: (Double(y) + 0.5) / s)
                if rect.insetBy(dx: -4, dy: -4).contains(canvasPoint) { inside += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 200, "text pixels inside its rect")
        XCTAssertEqual(outside, 0, "no text pixels outside its rect")
        XCTAssertLessThan(rect.maxY, canvas.size.height / 2, "text sits in the upper half")
    }

    func testTextImageSizeMatchesSize() throws {
        var style = TextStyle(text: "Two\nLines of text")
        style.backgroundColor = RGBA(0, 0, 0, 0.5)
        style.outlineWidth = 0.05
        style.isItalic = true
        style.fontFamily = "No Such Font Family"
        for canvasSize in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            let size = TextRenderer.size(for: style, canvas: canvasSize)
            let image = try XCTUnwrap(TextRenderer.image(for: style, canvas: canvasSize))
            XCTAssertEqual(CGFloat(image.width), size.width)
            XCTAssertEqual(CGFloat(image.height), size.height)
            XCTAssertTrue(TextRenderer.image(for: style, canvas: canvasSize) === image, "cached")
        }
        let one = TextRenderer.size(for: TextStyle(text: "Line"), canvas: CGSize(width: 1920, height: 1080))
        let two = TextRenderer.size(for: TextStyle(text: "Line\nLine"), canvas: CGSize(width: 1920, height: 1080))
        XCTAssertGreaterThan(two.height, one.height * 1.5, "multi-line text is taller")
    }

    func testEmptyProjectRendersBlack() async throws {
        let p = makeProject([])
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        XCTAssertGreaterThan(built.composition.duration.seconds, 0)
        let px = try await render(p, at: 0)
        XCTAssertTrue(isBlack(px.rgb(fx: 0.5, fy: 0.5)))
        XCTAssertTrue(isBlack(px.rgb(0, 0)))
    }

    // MARK: - Composition structure

    func multiClipProject() async throws -> Project {
        let a = try await media("clip_a.mp4"), b = try await media("clip_b.mov"), green = try await media("solid_green.png")
        let music = try await media("music.mp3"), voice = try await media("voice.ogg")
        var p = makeProject([a, b, green, music, voice])
        var c1 = Clip(mediaID: a.id, start: 0, duration: 3, sourceIn: 1)
        c1.fadeIn = 0.5
        var c2 = Clip(mediaID: b.id, start: 4, duration: 4)
        c2.fadeOut = 1
        c2.volume = 1.5
        p.tracks[0].clips = [c1, c2]
        p.tracks[1].clips = [Clip(mediaID: green.id, start: 1, duration: 4),
                             Clip(mediaID: nil, start: 6, duration: 2.5, text: TextStyle(text: "End"))]
        var m = Clip(mediaID: music.id, start: 0, duration: 8)
        m.fadeIn = 1; m.fadeOut = 2; m.volume = 0.8
        p.tracks[2].clips = [m]
        p.tracks[3].clips = [Clip(mediaID: voice.id, start: 2, duration: 3)]
        return p
    }

    func testVideoCompositionValidatesForMultiClipProject() async throws {
        let p = try await multiClipProject()
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        let comp = built.composition
        XCTAssertEqual(comp.duration.seconds, p.duration, accuracy: 1e-6)
        XCTAssertEqual(built.videoComposition.renderSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(built.videoComposition.frameDuration, CMTime(value: 1, timescale: 30))

        let instructions = built.videoComposition.instructions
        XCTAssertGreaterThan(instructions.count, 4)
        var cursor = CMTime.zero
        for i in instructions {
            XCTAssertEqual(i.timeRange.start, cursor, "contiguous")
            XCTAssertGreaterThan(i.timeRange.duration, .zero)
            cursor = i.timeRange.end
        }
        XCTAssertEqual(cursor, comp.duration, "instructions cover the composition")

        // The gap between the video clips (3...4 s) shows the image only and needs no video decode.
        let gap = try XCTUnwrap(instructions.first { $0.timeRange.containsTime(CMTime(seconds: 3.5, preferredTimescale: 600)) })
        XCTAssertEqual(gap.requiredSourceTrackIDs?.count ?? 0, 0)

        let tracks = try await comp.load(.tracks)
        let issues = ValidationRecorder()
        let valid = built.videoComposition.isValid(for: tracks, assetDuration: comp.duration,
                                                   timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                                                   validationDelegate: issues)
        XCTAssertTrue(valid, "validation issues: \(issues.issues)")
        XCTAssertEqual(issues.issues, [])

        // A frame in the middle of the clip-B fade-out renders.
        let frame = try await FrameRenderer.image(of: p, at: 7.5, maxSize: renderSize)
        XCTAssertEqual(frame.width, 640)
    }

    func testAudioMixWithFadesAndBoost() async throws {
        let p = try await multiClipProject()
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        // V1 embedded audio + its boost track (clip B at 1.5×), A1 music, A2 voice.
        XCTAssertEqual(audioTracks.count, 4)
        let params = built.audioMix.inputParameters
        XCTAssertEqual(params.count, 4)
        XCTAssertEqual(Set(params.map(\.trackID)), Set(audioTracks.map(\.trackID)))

        func ramp(_ param: AVAudioMixInputParameters, at seconds: Double) -> (Float, Float, CMTimeRange)? {
            var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
            guard param.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 600),
                                      startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
            return (start, end, range)
        }
        // Music: fade in 0→0.8 over 0...1, fade out 0.8→0 over 6...8.
        let music = try XCTUnwrap(params.first { p in
            guard let r = ramp(p, at: 0.5) else { return false }
            return abs(r.1 - 0.8) < 0.001
        })
        let fadeIn = try XCTUnwrap(ramp(music, at: 0.5))
        XCTAssertEqual(fadeIn.0, 0); XCTAssertEqual(fadeIn.1, 0.8, accuracy: 0.001)
        XCTAssertEqual(fadeIn.2.duration.seconds, 1, accuracy: 1e-6)
        let fadeOut = try XCTUnwrap(ramp(music, at: 7))
        XCTAssertEqual(fadeOut.0, 0.8, accuracy: 0.001); XCTAssertEqual(fadeOut.1, 0)
        XCTAssertEqual(fadeOut.2.start.seconds, 6, accuracy: 1e-6)

        // Clip B (volume 1.5) fades out over 7...8 on both the main (1→0) and boost (0.5→0) tracks.
        let fadeOutGains = params.compactMap { ramp($0, at: 7.5) }.filter { abs($0.2.start.seconds - 7) < 1e-6 }.map(\.0).sorted()
        XCTAssertEqual(fadeOutGains.count, 2)
        XCTAssertEqual(fadeOutGains.first ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(fadeOutGains.last ?? 0, 1, accuracy: 0.001)
    }

    func testMutedAndDetachedAudioIsLeftOut() async throws {
        var p = try await multiClipProject()
        p.tracks[0].clips[0].audioMuted = true
        p.tracks[0].clips[1].audioMuted = true
        p.tracks[2].isMuted = true
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "only the voice track remains")
    }

    func testPropertyEditReusesComposition() async throws {
        var p = try await multiClipProject()
        let first = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: nil)
        p.tracks[0].clips[0].transform.scale = 0.7
        p.tracks[0].clips[0].color.brightness = 0.2
        p.tracks[1].clips[1].text?.text = "Changed"
        p.tracks[2].clips[0].volume = 0.3
        let start = Date()
        let second = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: first)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "property-only rebuilds are cheap")
        XCTAssertTrue(second.sharesComposition(with: first), "property-only edits keep the composition")
        XCTAssertFalse(second.videoComposition === first.videoComposition)

        p.tracks[0].clips[1].start = 4.5
        let third = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: second)
        XCTAssertFalse(third.sharesComposition(with: second), "timing edits rebuild the composition")
    }

    func testMissingMediaIsSkippedAndReported() async throws {
        let red = try await media("solid_red.mp4")
        var gone = red
        gone.id = UUID()
        gone.name = "gone"
        gone.url = URL(fileURLWithPath: "/nonexistent/gone.mp4")
        var p = makeProject([red, gone])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 2), Clip(mediaID: gone.id, start: 2, duration: 2)]
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        XCTAssertEqual(built.missingMedia, ["gone"])
        XCTAssertEqual(built.duration, 4, accuracy: 1e-6)
    }

    // MARK: - Filters

    func testFilterIdentityIsNoOpAndPresetsKeepExtent() {
        let input = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(FilterRenderer.apply(color: .identity, filter: .none, intensity: 1, to: input) === input)
        XCTAssertTrue(FilterRenderer.apply(color: .identity, filter: .comic, intensity: 0, to: input) === input)
        let ctx = CIContext()
        var color = ColorAdjustments()
        color.vignette = 0.5
        color.temperature = 0.3
        for preset in FilterPreset.allCases {
            let out = FilterRenderer.apply(color: color, filter: preset, intensity: 0.7, to: input)
            XCTAssertEqual(out.extent, input.extent, "\(preset)")
            XCTAssertNotNil(ctx.createCGImage(out, from: out.extent), "\(preset)")
        }
    }

    func testBlurPresetDoesNotDarkenEdges() async throws {
        let white = try await media("solid_white.jpg")
        var p = makeProject([white])
        var c = Clip(mediaID: white.id, start: 0, duration: 2)
        c.filter = .blur
        c.transform.fitMode = .fill
        p.tracks[0].clips = [c]
        let px = try await render(p, at: 0.5)
        XCTAssertGreaterThan(px.brightness(1, 1), 235)
        XCTAssertGreaterThan(px.brightness(px.width / 2, 1), 235)
    }

    // MARK: - Playback

    @MainActor
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @MainActor
    func testPlaybackControllerFastPathAndStructuralRebuild() async throws {
        let p = try await multiClipProject()
        let store = EditorStore(project: p)
        let playback = PlaybackController(store: store)
        let ready = await waitUntil { playback.isReady && playback.player.currentItem != nil }
        XCTAssertTrue(ready)
        XCTAssertNil(playback.lastError)
        let item = try XCTUnwrap(playback.player.currentItem)
        XCTAssertEqual(item.videoComposition?.renderSize, CGSize(width: 1280, height: 720))

        playback.seek(to: 2.5)
        XCTAssertEqual(store.playhead, 2.5)
        let seeked = await waitUntil { abs(playback.player.currentTime().seconds - 2.5) < 0.01 }
        XCTAssertTrue(seeked, "player time \(playback.player.currentTime().seconds)")

        // Property edit: same player item, new video composition.
        let clipID = p.tracks[0].clips[0].id
        let oldComposition = item.videoComposition
        store.updateClip(clipID, "Scale") { $0.transform.scale = 0.5 }
        let swapped = await waitUntil { item.videoComposition !== oldComposition }
        XCTAssertTrue(swapped)
        XCTAssertTrue(playback.player.currentItem === item, "property edits keep the player item")

        // Structural edit: new item, playhead preserved.
        store.mutate("Move") { $0.tracks[0].clips[1].start = 5 }
        let replaced = await waitUntil { playback.player.currentItem !== item }
        XCTAssertTrue(replaced)
        XCTAssertEqual(store.playhead, 2.5)
        let restored = await waitUntil { abs(playback.player.currentTime().seconds - 2.5) < 0.01 }
        XCTAssertTrue(restored)

        // Seeking clamps to the timeline.
        playback.seek(to: 100)
        XCTAssertEqual(store.playhead, store.project.duration)
        playback.seek(to: -3)
        XCTAssertEqual(store.playhead, 0)
    }

    @MainActor
    func testPlaybackAdvancesPlayheadAndRestartsAtEnd() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 1)]
        let store = EditorStore(project: p)
        let playback = PlaybackController(store: store)
        let ready = await waitUntil { playback.isReady }
        XCTAssertTrue(ready)

        playback.play()
        XCTAssertTrue(playback.isPlaying)
        let advanced = await waitUntil { store.playhead > 0.2 }
        XCTAssertTrue(advanced, "playhead follows playback")
        let ended = await waitUntil(4) { !playback.isPlaying }
        XCTAssertTrue(ended, "pauses at the end")
        XCTAssertEqual(store.playhead, 1, accuracy: 1e-6)

        playback.play()
        XCTAssertLessThan(store.playhead, 0.1, "play at the end restarts from 0")
        playback.pause()
        XCTAssertFalse(playback.isPlaying)
    }

    // MARK: - Export & performance

    func testExportProjectWithVideoImageTextAndAudio() async throws {
        let a = try await media("clip_a.mp4"), logo = try await media("logo.png")
        let music = try await media("music.mp3"), opus = try await media("opus.ogg")
        var p = makeProject([a, logo, music, opus])
        var v = Clip(mediaID: a.id, start: 0, duration: 2)
        v.fadeIn = 0.5
        p.tracks[0].clips = [v]
        var img = Clip(mediaID: logo.id, start: 0.5, duration: 1)
        img.transform.scale = 0.3
        p.tracks[1].clips = [img, Clip(mediaID: nil, start: 1.5, duration: 0.5, text: TextStyle(text: "Bye"))]
        var m = Clip(mediaID: music.id, start: 0, duration: 2)
        m.fadeOut = 0.5
        p.tracks[2].clips = [m]
        p.tracks[3].clips = [Clip(mediaID: opus.id, start: 0.5, duration: 1)]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushExportTest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = await Exporter()
        var settings = ExportSettings()
        settings.resolution = .p720
        await exporter.export(project: p, to: url, settings: settings)
        let state = await exporter.state
        XCTAssertEqual(state, .finished(url))
        let progress = await exporter.progress
        XCTAssertEqual(progress, 1)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let size = try await XCTUnwrap(video.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    func testExportCancel() async throws {
        let a = try await media("clip_a.mp4")
        var p = makeProject([a])
        p.tracks[0].clips = [Clip(mediaID: a.id, start: 0, duration: 6)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushCancel-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = await Exporter()
        var settings = ExportSettings()
        settings.container = .mov
        settings.resolution = .canvas
        let task = Task { await exporter.export(project: p, to: url, settings: settings) }
        try await Task.sleep(for: .milliseconds(150))
        await exporter.cancel()
        await task.value
        let state = await exporter.state
        XCTAssertEqual(state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBuildTimeFor60ClipProject() async throws {
        let a = try await media("clip_a.mp4"), b = try await media("clip_b.mov"), green = try await media("solid_green.png")
        let music = try await media("music.mp3")
        var p = makeProject([a, b, green, music])
        for i in 0..<60 {
            var c = Clip(mediaID: (i % 2 == 0 ? a : b).id, start: Double(i), duration: 1, sourceIn: 0.5)
            c.fadeIn = 0.2
            p.tracks[0].clips.append(c)
        }
        for i in 0..<10 {
            p.tracks[1].clips.append(Clip(mediaID: green.id, start: Double(i * 6), duration: 2))
            p.tracks[1].clips.append(Clip(mediaID: nil, start: Double(i * 6 + 3), duration: 2, text: TextStyle(text: "T\(i)")))
        }
        for i in 0..<6 {
            p.tracks[2].clips.append(Clip(mediaID: music.id, start: Double(i * 10), duration: 10))
        }
        _ = try await CompositionBuilder.build(project: p, assets: .shared) // warm caches
        let start = Date()
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.2, "build took \(elapsed)s")
        XCTAssertEqual(built.duration, 60, accuracy: 1e-6)
    }

    /// Median time of five property-only rebuilds of a project with `n` clips on V1, V2 and A1.
    func propertyRebuildTime(clipsPerTrack n: Int) async throws -> TimeInterval {
        let a = try await media("clip_a.mp4"), music = try await media("music.mp3")
        var p = makeProject([a, music])
        for i in 0..<n {
            p.tracks[0].clips.append(Clip(mediaID: a.id, start: Double(i), duration: 1, sourceIn: 1))
            var top = Clip(mediaID: a.id, start: Double(i) + 0.5, duration: 0.5)
            top.transform.scale = 0.5
            p.tracks[1].clips.append(top)
            var m = Clip(mediaID: music.id, start: Double(i), duration: 1)
            m.fadeIn = 0.1
            p.tracks[2].clips.append(m)
        }
        let first = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: nil)
        var previous = first
        var times: [TimeInterval] = []
        for k in 0..<5 {
            p.tracks[0].clips[0].transform.scale = 0.5 + Double(k) * 0.05
            let start = Date()
            previous = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: previous)
            times.append(Date().timeIntervalSince(start))
            XCTAssertTrue(previous.sharesComposition(with: first))
        }
        XCTAssertEqual(previous.videoComposition.instructions.count, 2 * n)
        return times.sorted()[2]
    }

    func testPropertyRebuildScalesLinearly() async throws {
        let small = try await propertyRebuildTime(clipsPerTrack: 100)
        let large = try await propertyRebuildTime(clipsPerTrack: 400)
        // Linear ≈ 4×; the old instruction sweep and audio-mix construction were quadratic (≈ 14×).
        XCTAssertLessThan(large, 0.025, "400 clips/track property rebuild took \(large * 1000) ms")
        XCTAssertLessThan(large / small, 8, "100 → 400 clips/track: \(small * 1000) → \(large * 1000) ms")
    }

    func testManyTitlesAreNotReRasterizedOnEveryRebuild() async throws {
        var p = makeProject([])
        for i in 0..<150 {
            p.tracks[0].clips.append(Clip(mediaID: nil, start: Double(i), duration: 1, text: TextStyle(text: "Title \(i) \(UUID())")))
        }
        func textImages(_ built: BuiltComposition) -> [CGImage] {
            built.videoComposition.instructions.compactMap { instruction -> CGImage? in
                guard case .image(let image)? = (instruction as? CompositorInstruction)?.snapshot.layers.first?.content else { return nil }
                return image.cgImage
            }
        }
        let first = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: nil)
        p.canvas.backgroundColor = RGBA(0.1, 0.1, 0.1)
        let second = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 0.5, reusing: first)
        let before = textImages(first), after = textImages(second)
        XCTAssertEqual(before.count, 150)
        XCTAssertEqual(after.count, 150)
        XCTAssertTrue(zip(before, after).allSatisfy { $0 === $1 }, "titles come from the cache")
    }

    func testAudioMixGainsAcrossAdjacentClips() async throws {
        let music = try await media("music.mp3")
        var p = makeProject([music])
        var a = Clip(mediaID: music.id, start: 1, duration: 1)
        a.volume = 0.5
        var b = Clip(mediaID: music.id, start: 2, duration: 2, sourceIn: 1)
        b.fadeIn = 1
        var c = Clip(mediaID: music.id, start: 4, duration: 2, sourceIn: 3)
        c.volume = 0.25
        c.fadeOut = 1
        p.tracks[2].clips = [a, b, c]
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        let params = try XCTUnwrap(built.audioMix.inputParameters.first)
        func gain(at seconds: Double) -> Float? {
            var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
            guard params.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 600),
                                       startVolume: &start, endVolume: &end, timeRange: &range),
                  range.containsTime(CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
            let f = Float((seconds - range.start.seconds) / max(1e-9, range.duration.seconds))
            return start + (end - start) * f
        }
        XCTAssertEqual(gain(at: 0.5) ?? -1, 0, accuracy: 0.001, "silent before the first clip")
        XCTAssertEqual(gain(at: 1.5) ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(gain(at: 2.5) ?? -1, 0.5, accuracy: 0.001, "halfway through the fade-in")
        XCTAssertEqual(gain(at: 3.5) ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(gain(at: 4.5) ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(gain(at: 5.5) ?? -1, 0.125, accuracy: 0.001, "halfway through the fade-out")
    }

    func testMutedClipsOnAudioTracksAreSilent() async throws {
        let music = try await media("music.mp3"), a = try await media("clip_a.mp4")
        var p = makeProject([music, a])
        var m = Clip(mediaID: music.id, start: 0, duration: 2)
        m.audioMuted = true
        var detached = Clip(mediaID: a.id, start: 0, duration: 2)
        detached.audioMuted = true
        p.tracks[2].clips = [m]
        p.tracks[3].clips = [detached]
        let muted = try await CompositionBuilder.build(project: p, assets: .shared)
        let mutedTracks = try await muted.composition.loadTracks(withMediaType: .audio)
        XCTAssertTrue(mutedTracks.isEmpty, "muted audio-track clips are left out")
        XCTAssertTrue(muted.audioMix.inputParameters.isEmpty)

        p.tracks[2].clips[0].audioMuted = false
        let unmuted = try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 1, reusing: muted)
        let unmutedTracks = try await unmuted.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(unmutedTracks.count, 1)
    }

    func testMissingStillIsReportedAndExportKeepsExistingFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushMissingStill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("vanishing.jpg")
        try FileManager.default.copyItem(at: try Fixture.url("solid_white.jpg"), to: copy)
        let still = try await MediaImporter.probe(copy)
        try FileManager.default.removeItem(at: copy)

        var p = makeProject([still])
        p.tracks[0].clips = [Clip(mediaID: still.id, start: 0, duration: 1)]
        let built = try await CompositionBuilder.build(project: p, assets: AssetCache())
        XCTAssertEqual(built.missingMedia, ["vanishing"])
        var hidden = p
        hidden.tracks[0].isHidden = true
        let hiddenBuilt = try await CompositionBuilder.build(project: hidden, assets: AssetCache())
        XCTAssertEqual(hiddenBuilt.missingMedia, ["vanishing"], "missing stills on hidden tracks are reported too")

        let destination = folder.appendingPathComponent("previous.mp4")
        try Data("previous export".utf8).write(to: destination)
        let exporter = await Exporter(assets: AssetCache())
        await exporter.export(project: p, to: destination, settings: ExportSettings())
        let state = await exporter.state
        XCTAssertEqual(state, .failed(EngineError.missingMedia("vanishing").localizedDescription))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous export".utf8), "a failed export keeps the old file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["previous.mp4"])
    }

    func testExportReplacesExistingFileOnlyOnSuccess() async throws {
        let red = try await media("solid_red.mp4")
        var p = makeProject([red])
        p.tracks[0].clips = [Clip(mediaID: red.id, start: 0, duration: 1)]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushReplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("movie.mov")
        let old = Data("previous export".utf8)
        try old.write(to: destination)
        var settings = ExportSettings()
        settings.container = .mov
        settings.resolution = .p720

        // Cancelled: the old file survives and no temporary file is left behind.
        var long = p
        long.tracks[0].clips = (0..<20).map { Clip(mediaID: red.id, start: Double($0) * 3, duration: 3) }
        let cancelled = await Exporter()
        let task = Task { await cancelled.export(project: long, to: destination, settings: settings) }
        try await Task.sleep(for: .milliseconds(150))
        await cancelled.cancel()
        await task.value
        let cancelledState = await cancelled.state
        XCTAssertEqual(cancelledState, .cancelled)
        XCTAssertEqual(try Data(contentsOf: destination), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["movie.mov"])

        // Succeeded: the new movie replaces the old file.
        let exporter = await Exporter()
        await exporter.export(project: p, to: destination, settings: settings)
        let state = await exporter.state
        XCTAssertEqual(state, .finished(destination))
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["movie.mov"])
    }

    // MARK: - Stills

    func stillExtent(_ built: BuiltComposition) throws -> CGSize {
        let instruction = try XCTUnwrap(built.videoComposition.instructions.first as? CompositorInstruction)
        guard case .image(let image)? = instruction.snapshot.layers.first?.content else {
            XCTFail("no still layer"); return .zero
        }
        return image.extent.size
    }

    func testStillsDecodeAtDisplaySize() async throws {
        let photo = try await media("photo.jpg") // 4000x3000, fits a 1280x720 canvas at 960x720
        var p = makeProject([photo])
        p.tracks[0].clips = [Clip(mediaID: photo.id, start: 0, duration: 2)]
        let cache = AssetCache()
        let preview = try await CompositionBuilder.build(project: p, assets: cache, renderScale: 0.5)
        XCTAssertEqual(try stillExtent(preview), CGSize(width: 512, height: 384), "480 px on screen → 512 px decode")
        let full = try await CompositionBuilder.build(project: p, assets: cache, renderScale: 1)
        XCTAssertEqual(try stillExtent(full), CGSize(width: 1024, height: 768))
        p.tracks[0].clips[0].transform.scale = 3
        let zoomed = try await CompositionBuilder.build(project: p, assets: cache, renderScale: 1)
        XCTAssertEqual(try stillExtent(zoomed), CGSize(width: 3072, height: 2304), "zoomed stills decode sharper")
        p.tracks[0].clips[0].transform.scale = 0.9
        let reused = try await CompositionBuilder.build(project: p, assets: cache, renderScale: 1)
        XCTAssertEqual(try stillExtent(reused), CGSize(width: 1024, height: 768), "smallest sufficient decode is reused")
        XCTAssertEqual(AssetCache.stillDecodeSize(displayLongSide: 10_000, media: photo), 4000)
        let white = try await media("solid_white.jpg")
        XCTAssertEqual(AssetCache.stillDecodeSize(displayLongSide: 900, media: white), 800)

        // A downscaled still still fills its rect.
        p.tracks[0].clips[0].transform.scale = 1
        p.tracks[0].clips[0].transform.fitMode = .fill
        let px = try await render(p, at: 1)
        XCTAssertFalse(isBlack(px.rgb(1, 1)))
        XCTAssertFalse(isBlack(px.rgb(px.width - 2, px.height - 2)))
    }

    func testStillCacheStaysWithinBudget() async throws {
        let photo = try await media("photo.jpg")
        let copies: [MediaItem] = (0..<6).map { _ in var m = photo; m.id = UUID(); return m }
        let cache = AssetCache()
        let perImage = 1024 * 768 * 4
        cache.imageByteBudget = 3 * perImage
        let batch = await cache.images(for: copies.map { .init(media: $0, displayLongSide: 1000) })
        XCTAssertEqual(batch.count, 6)
        XCTAssertEqual(batch.values.first?.extent.size, CGSize(width: 1024, height: 768))
        XCTAssertEqual(cache.cachedImageBytes, 6 * perImage, "one batch keeps every still it needs")

        let smaller = await cache.images(for: copies.prefix(2).map { .init(media: $0, displayLongSide: 1000) })
        XCTAssertEqual(smaller.count, 2)
        XCTAssertTrue(smaller[copies[0].id] === batch[copies[0].id], "served from the cache")
        XCTAssertLessThanOrEqual(cache.cachedImageBytes, 3 * perImage, "stills no longer needed are evicted")
        for m in copies { XCTAssertNotNil(cache.image(for: m, displayLongSide: 1000)) }
        XCTAssertLessThanOrEqual(cache.cachedImageBytes, 3 * perImage)
        cache.purgeAll()
        XCTAssertEqual(cache.cachedImageBytes, 0)
    }

    func testStillDecodingIsConcurrentAndFast() async throws {
        let photo = try await media("photo.jpg")
        var p = makeProject([])
        p.canvas = CanvasSettings(width: 1920, height: 1080, frameRate: 30)
        for i in 0..<30 {
            var m = photo
            m.id = UUID()
            p.media.append(m)
            p.tracks[0].clips.append(Clip(mediaID: m.id, start: Double(i) * 3, duration: 3))
        }
        let cache = AssetCache()
        let start = Date()
        let built = try await CompositionBuilder.build(project: p, assets: cache)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(built.missingMedia, [])
        XCTAssertLessThan(elapsed, 1.0, "30 photos took \(elapsed) s (full-size serial decoding took ~1.4 s)")
        XCTAssertLessThan(cache.cachedImageBytes, 30 * 1536 * 1152 * 4 + 1, "decoded at display size, not 4096 px")
    }

    // MARK: - Video shorter than its clip

    func testClipLongerThanItsVideoHoldsTheLastFrame() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushHold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var long = try await MediaImporter.probe(try TestMedia.videoWithLongerAudio(in: folder, video: 2, audio: 3))
        long.duration = 3 // as probed by older versions: the asset (audio) duration
        let red = try await media("solid_red.mp4")
        var p = makeProject([long, red])
        p.tracks[0].clips = [Clip(mediaID: long.id, start: 0, duration: 3), Clip(mediaID: red.id, start: 3, duration: 1)]
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        XCTAssertEqual(built.duration, 4, accuracy: 1e-6)
        let audio = try await built.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)

        func meanBrightness(_ px: Pixels) -> Double {
            var sum = 0.0, n = 0.0
            for y in stride(from: 0, to: px.height, by: 8) {
                for x in stride(from: 0, to: px.width, by: 8) { sum += px.brightness(x, y); n += 1 }
            }
            return sum / n
        }
        let lastFrame = meanBrightness(try await render(p, at: 1.95))
        for t in [2.05, 2.5, 2.95] {
            let held = meanBrightness(try await render(p, at: t))
            XCTAssertGreaterThan(held, 30, "frame at \(t) s is not black")
            XCTAssertEqual(held, lastFrame, accuracy: 12, "frame at \(t) s holds the last picture")
        }
        assertColor(try await render(p, at: 3.5).rgb(fx: 0.5, fy: 0.5), 255, 0, 0, "next clip follows")
    }

    // MARK: - Speed

    func testSpeedPlaysSourceFasterAndSlower() async throws {
        let source = try await media("red_then_blue.mp4") // 3 s red, then 3 s blue
        var p = makeProject([source])
        var fast = Clip(mediaID: source.id, start: 0, duration: 3)
        fast.speed = 2 // plays source 0…6
        var slow = Clip(mediaID: source.id, start: 3, duration: 4, sourceIn: 2)
        slow.speed = 0.5 // plays source 2…4
        p.tracks[0].clips = [fast, slow]
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        XCTAssertEqual(built.duration, 7, accuracy: 1e-6)

        assertColor(try await render(p, at: 1).rgb(fx: 0.5, fy: 0.5), 255, 0, 0, "2×: 1 s in shows source 2 s")
        assertColor(try await render(p, at: 2).rgb(fx: 0.5, fy: 0.5), 0, 0, 255, "2×: 2 s in shows source 4 s")
        assertColor(try await render(p, at: 3.5).rgb(fx: 0.5, fy: 0.5), 255, 0, 0, "½×: shows source 2.25 s")
        assertColor(try await render(p, at: 6.5).rgb(fx: 0.5, fy: 0.5), 0, 0, 255, "½×: shows source 3.75 s")
    }

    func testSpeedScalesAudioWithVideo() async throws {
        let clip = try await media("clip_a.mp4")
        var p = makeProject([clip])
        var c = Clip(mediaID: clip.id, start: 1, duration: 3)
        c.speed = 2
        p.tracks[0].clips = [c]
        let built = try await CompositionBuilder.build(project: p, assets: .shared)
        XCTAssertEqual(built.duration, 4, accuracy: 1e-6)
        for type in [AVMediaType.video, .audio] {
            let tracks = try await built.composition.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.last, "\(type)")
            let segments = try await track.load(.segments).filter { !$0.isEmpty }
            let segment = try XCTUnwrap(segments.last, "\(type)")
            XCTAssertEqual(segment.timeMapping.target.start.seconds, 1, accuracy: 0.01, "\(type)")
            XCTAssertEqual(segment.timeMapping.target.duration.seconds, 3, accuracy: 0.01, "\(type)")
            XCTAssertEqual(segment.timeMapping.source.duration.seconds, 6, accuracy: 0.05, "\(type)")
        }
    }

    // MARK: - Titles at output resolution

    func testTitlesRasterizeAtDisplayResolution() async throws {
        var style = TextStyle(text: "Sharp")
        style.shadow = true
        let size = TextRenderer.size(for: style, canvas: canvas.size)
        let double = try XCTUnwrap(TextRenderer.image(for: style, canvas: canvas.size, scale: 2))
        XCTAssertEqual(CGFloat(double.width), (size.width * 2).rounded(.up))
        XCTAssertEqual(CGFloat(double.height), (size.height * 2).rounded(.up))
        XCTAssertTrue(TextRenderer.image(for: style, canvas: canvas.size, scale: 1.9) === double, "scales round up to a cached step")
        XCTAssertEqual(TextRenderer.size(for: style, canvas: canvas.size), size, "geometry stays in canvas pixels")

        var p = makeProject([])
        var c = Clip(mediaID: nil, start: 0, duration: 2, text: style)
        p.tracks[0].clips = [c]
        func textLayer(_ built: BuiltComposition) throws -> (image: CIImage, contentSize: CGSize) {
            let instruction = try XCTUnwrap(built.videoComposition.instructions.first as? CompositorInstruction)
            let layer = try XCTUnwrap(instruction.snapshot.layers.first)
            guard case .image(let image) = layer.content else { throw XCTSkip("not an image layer") }
            return (image, layer.contentSize)
        }
        // A 4K export of a 720p canvas rasterizes at 3×.
        let export = try textLayer(try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 3))
        XCTAssertEqual(export.image.extent.width, (size.width * 3).rounded(.up))
        XCTAssertEqual(export.contentSize, size)
        // A title scaled up 1.5× at canvas resolution rasterizes at 1.5×.
        c.transform.scale = 1.5
        p.tracks[0].clips = [c]
        let scaled = try textLayer(try await CompositionBuilder.build(project: p, assets: .shared, renderScale: 1))
        XCTAssertEqual(scaled.image.extent.width, (size.width * 1.5).rounded(.up))
        XCTAssertEqual(scaled.contentSize, size)

        // The scaled raster lands exactly where the canvas-pixel one would.
        let rect = ClipGeometry.rect(content: size, canvas: canvas.size, transform: c.transform, isText: true)
        let px = try await render(p, at: 1)
        let s = renderSize.width / canvas.size.width
        var outside = 0
        for y in 0..<px.height {
            for x in stride(from: 0, to: px.width, by: 2) where px.brightness(x, y) > 200 {
                let point = CGPoint(x: (Double(x) + 0.5) / s, y: (Double(y) + 0.5) / s)
                if !rect.insetBy(dx: -4, dy: -4).contains(point) { outside += 1 }
            }
        }
        XCTAssertEqual(outside, 0)
    }

    // MARK: - Live drags

    @MainActor
    func testStreamingStructuralEditsKeepTheCurrentPlayerItem() async throws {
        let p = try await multiClipProject()
        let store = EditorStore(project: p)
        let playback = PlaybackController(store: store)
        let ready = await waitUntil { playback.isReady && playback.player.currentItem != nil }
        XCTAssertTrue(ready)
        playback.seek(to: 5)

        // A clip drag: one coalesced move per mouse event, every ~16 ms.
        let clipID = p.tracks[0].clips[1].id, trackID = p.tracks[0].id
        var items = Set<ObjectIdentifier>()
        for i in 1...40 {
            _ = store.moveClip(clipID, toTrack: trackID, start: 4 + Double(i) / 30, coalesce: "drag")
            try await Task.sleep(for: .milliseconds(16))
            if let item = playback.player.currentItem { items.insert(ObjectIdentifier(item)) } else { XCTFail("no item mid-drag") }
        }
        XCTAssertLessThanOrEqual(items.count, 2, "at most the first edit of the drag replaces the item, not every mouse event")

        // Once the edits settle, the final structure is installed.
        let expected = store.project.duration
        let settled = await waitUntil {
            guard let duration = playback.player.currentItem?.duration.seconds, duration.isFinite else { return false }
            return abs(duration - expected) < 0.01
        }
        XCTAssertTrue(settled, "final structure installed after the drag")
        XCTAssertEqual(store.playhead, 5)
    }
}

/// Collects AVVideoComposition validation complaints.
private final class ValidationRecorder: NSObject, AVVideoCompositionValidationHandling {
    var issues: [String] = []
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        issues.append("invalid value for \(key)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        issues.append("empty time range \(timeRange.start.seconds)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol) -> Bool {
        issues.append("invalid instruction time range \(videoCompositionInstruction.timeRange.start.seconds)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTrackIDIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol,
                          layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
        issues.append("invalid track id"); return true
    }
}
