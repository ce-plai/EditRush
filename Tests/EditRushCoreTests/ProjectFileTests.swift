import XCTest
@testable import EditRushCore

/// Hand-written project files: lenient decoding, relative media paths, validation and normalization.
@MainActor
final class ProjectFileTests: XCTestCase {
    private var tempDir: URL!
    private let videoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let audioID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushProjectFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, name: String = "Test.editrush") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func media(_ id: UUID, kind: MediaKind, duration: Double = 6) -> MediaItem {
        MediaItem(id: id, url: tempDir.appendingPathComponent("\(kind).mov"), name: "\(kind)", kind: kind,
                  duration: duration, pixelWidth: kind == .audio ? 0 : 1920, pixelHeight: kind == .audio ? 0 : 1080,
                  frameRate: 30, hasAudio: true)
    }

    func testMinimalFileUsesDefaults() throws {
        let url = try write("""
        {"media": [{"id": "\(videoID)", "url": "/tmp/a.mov", "kind": "video", "duration": 6}],
         "tracks": [{"kind": "video", "clips": [{"mediaID": "\(videoID)", "start": 1, "duration": 2}]},
                    {"kind": "video", "clips": [{"text": {"text": "Hi"}, "start": 0, "duration": 1}]}]}
        """)
        let p = try EditorStore.readProjectFile(url)
        XCTAssertEqual(p.name, "Test")
        XCTAssertEqual(p.canvas, CanvasSettings())
        XCTAssertEqual(p.media[0].name, "a")
        XCTAssertEqual(p.media[0].pixelWidth, 0)
        let clip = p.tracks[0].clips[0]
        XCTAssertEqual(clip.transform, .identity)
        XCTAssertEqual(clip.color, .identity)
        XCTAssertEqual(clip.volume, 1)
        XCTAssertEqual(clip.sourceIn, 0)
        XCTAssertNil(clip.label)
        XCTAssertEqual(p.tracks[1].clips[0].text?.text, "Hi")
        XCTAssertEqual(p.tracks[1].clips[0].text?.fontFamily, TextStyle().fontFamily)
        XCTAssertNotEqual(p.tracks[0].id, p.tracks[1].id, "missing ids are generated")
    }

    func testMissingRequiredFieldsAreReported() throws {
        let url = try write("""
        {"tracks": [{"kind": "video", "clips": [{"text": {}, "duration": 2}]}]}
        """)
        XCTAssertThrowsError(try EditorStore.readProjectFile(url)) { error in
            guard case .unreadable(let reason) = error as? ProjectFileError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("missing start"), reason)
        }
    }

    func testMediaPathsResolveAgainstProjectFolder() throws {
        let url = try write("""
        {"media": [{"id": "\(videoID)", "url": "footage/a.mov", "kind": "video"},
                   {"id": "\(audioID)", "url": "file:///tmp/b.wav", "kind": "audio"},
                   {"id": "\(UUID())", "url": "/tmp/c.png", "kind": "image"}],
         "tracks": []}
        """)
        let p = try EditorStore.readProjectFile(url)
        XCTAssertEqual(p.media[0].url.path, tempDir.appendingPathComponent("footage/a.mov").standardizedFileURL.path)
        XCTAssertEqual(p.media[1].url, URL(fileURLWithPath: "/tmp/b.wav"))
        XCTAssertEqual(p.media[2].url, URL(fileURLWithPath: "/tmp/c.png"))

        // Re-saved projects store absolute file URLs and read back identically.
        let store = EditorStore()
        try store.open(url)
        let saved = tempDir.appendingPathComponent("Saved.editrush")
        try store.save(to: saved)
        XCTAssertEqual(try EditorStore.readProjectFile(saved).media, p.media)
    }

    func testValidatorReportsErrors() {
        var p = Project()
        p.media = [media(videoID, kind: .video), media(audioID, kind: .audio, duration: 0)]
        var v1 = Track(kind: .video)
        v1.clips = [Clip(mediaID: videoID, start: 0, duration: 4), Clip(mediaID: videoID, start: 3, duration: 2),
                    Clip(mediaID: audioID, start: 10, duration: 1), Clip(mediaID: UUID(), start: 20, duration: 1),
                    Clip(mediaID: nil, start: 30, duration: 1)]
        var a1 = Track(kind: .audio)
        a1.clips = [Clip(mediaID: nil, start: 0, duration: 1, text: TextStyle())]
        p.tracks = [v1, a1]

        let errors = ProjectValidator.issues(in: p, checkFiles: false).filter { $0.severity == .error }
        let byPath = Dictionary(grouping: errors, by: \.path).mapValues { $0.map(\.message).joined(separator: " | ") }
        XCTAssertTrue(byPath["media[1]"]?.contains("duration unknown") == true, "\(byPath)")
        XCTAssertTrue(byPath["tracks[0].clips[1]"]?.contains("overlaps tracks[0].clips[0]") == true, "\(byPath)")
        XCTAssertTrue(byPath["tracks[0].clips[2]"]?.contains("audio clip on a video track") == true, "\(byPath)")
        XCTAssertTrue(byPath["tracks[0].clips[3]"]?.contains("is not in media") == true, "\(byPath)")
        XCTAssertTrue(byPath["tracks[0].clips[4]"]?.contains("needs either mediaID or text") == true, "\(byPath)")
        XCTAssertTrue(byPath["tracks[1].clips[0]"]?.contains("text clip on an audio track") == true, "\(byPath)")
    }

    func testValidatorChecksFiles() {
        var p = Project()
        p.media = [media(videoID, kind: .video)]
        let issues = ProjectValidator.issues(in: p)
        XCTAssertEqual(issues.map(\.path), ["media[0]"])
        XCTAssertTrue(issues[0].message.hasPrefix("file not found"))
    }

    func testOutOfRangeValuesWarnAndAreNormalizedOnOpen() throws {
        let url = try write("""
        {"canvas": {"frameRate": 30},
         "media": [{"id": "\(videoID)", "url": "a.mov", "kind": "video", "duration": 6, "pixelWidth": 1920, "pixelHeight": 1080}],
         "tracks": [{"kind": "video", "clips": [
            {"mediaID": "\(videoID)", "start": 5, "duration": 2},
            {"mediaID": "\(videoID)", "start": 0.01, "duration": 10, "sourceIn": 2, "fadeIn": 9, "volume": 5}]}]}
        """)
        let raw = try EditorStore.readProjectFile(url)
        let issues = ProjectValidator.issues(in: raw, checkFiles: false)
        XCTAssertEqual(issues.map(\.severity), [.warning])
        XCTAssertEqual(issues.first?.path, "tracks[0].clips[1]")
        for field in ["start", "duration", "fadeIn", "volume"] {
            XCTAssertTrue(issues.first?.message.contains(field) == true, "\(field) in \(issues)")
        }

        let store = EditorStore()
        try store.open(url)
        let clips = store.project.tracks[0].clips
        XCTAssertEqual(clips.map(\.start), [0, 5], "sorted by start, quantized to the frame grid")
        XCTAssertEqual(clips[0].duration, 4, accuracy: 1e-9, "trimmed to the media's remaining length")
        XCTAssertEqual(clips[0].fadeIn, 4, accuracy: 1e-9)
        XCTAssertEqual(clips[0].volume, 2)
        XCTAssertFalse(store.isDirty)
    }

    func testStoreBuiltProjectHasNoIssues() {
        let store = EditorStore()
        store.replaceProject(.empty(), url: nil)
        store.addTextClip(at: 0)
        store.addTextClip(at: 0)
        XCTAssertEqual(ProjectValidator.issues(in: store.project, checkFiles: false), [])
    }
}
