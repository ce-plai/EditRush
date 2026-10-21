import XCTest
@testable import EditRushCore

final class ModelTests: XCTestCase {
    func testFadeFactor() {
        var c = Clip(mediaID: nil, start: 10, duration: 4)
        c.fadeIn = 1; c.fadeOut = 2
        XCTAssertEqual(c.fadeFactor(at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(c.fadeFactor(at: 10.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.fadeFactor(at: 11.5), 1, accuracy: 1e-9)
        XCTAssertEqual(c.fadeFactor(at: 13), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.fadeFactor(at: 14), 0, accuracy: 1e-9)
    }

    func testGeometryFitAndOffset() {
        let canvas = CGSize(width: 1920, height: 1080)
        var t = ClipTransform()
        let r = ClipGeometry.rect(content: CGSize(width: 1080, height: 1920), canvas: canvas, transform: t, isText: false)
        XCTAssertEqual(r.height, 1080, accuracy: 0.01)
        XCTAssertEqual(r.midX, 960, accuracy: 0.01)
        t.scale = 0.5; t.offsetX = 0.25; t.offsetY = -0.25
        let r2 = ClipGeometry.rect(content: CGSize(width: 1920, height: 1080), canvas: canvas, transform: t, isText: false)
        XCTAssertEqual(r2.width, 960, accuracy: 0.01)
        XCTAssertEqual(r2.midX, 1440, accuracy: 0.01)
        XCTAssertEqual(r2.midY, 270, accuracy: 0.01)
    }

    func testProjectCodableRoundTrip() throws {
        var p = Project.empty()
        p.tracks[0].clips.append(Clip(mediaID: nil, start: 1, duration: 2, text: TextStyle(text: "Hi")))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
    }
}
