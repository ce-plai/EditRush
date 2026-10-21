import XCTest
import AVFoundation
import CoreGraphics
@testable import EditRushCore

final class MediaTests: XCTestCase {
    private static let allFixtures = [
        "clip_a.mp4", "clip_b.mov", "rotated_portrait.mov", "solid_red.mp4", "solid_blue.mov",
        "solid_green.png", "solid_white.jpg", "photo.jpg", "logo.png",
        "music.mp3", "tone.wav", "voice.ogg", "opus.ogg",
    ]

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Probe

    func testProbeEveryFixture() async throws {
        struct Expect { var kind: MediaKind; var duration: Double; var size: (Int, Int); var hasAudio: Bool }
        let expectations: [String: Expect] = [
            "clip_a.mp4": Expect(kind: .video, duration: 6, size: (1920, 1080), hasAudio: true),
            "clip_b.mov": Expect(kind: .video, duration: 5, size: (1280, 720), hasAudio: true),
            "rotated_portrait.mov": Expect(kind: .video, duration: 4, size: (720, 1280), hasAudio: false),
            "solid_red.mp4": Expect(kind: .video, duration: 3, size: (640, 360), hasAudio: false),
            "solid_blue.mov": Expect(kind: .video, duration: 3, size: (640, 360), hasAudio: false),
            "solid_green.png": Expect(kind: .image, duration: 0, size: (400, 400), hasAudio: false),
            "solid_white.jpg": Expect(kind: .image, duration: 0, size: (800, 600), hasAudio: false),
            "photo.jpg": Expect(kind: .image, duration: 0, size: (4000, 3000), hasAudio: false),
            "logo.png": Expect(kind: .image, duration: 0, size: (512, 512), hasAudio: false),
            "music.mp3": Expect(kind: .audio, duration: 10, size: (0, 0), hasAudio: true),
            "tone.wav": Expect(kind: .audio, duration: 4, size: (0, 0), hasAudio: true),
            "voice.ogg": Expect(kind: .audio, duration: 3, size: (0, 0), hasAudio: true),
            "opus.ogg": Expect(kind: .audio, duration: 3, size: (0, 0), hasAudio: true),
        ]
        for name in Self.allFixtures {
            let item = try await MediaImporter.probe(try Fixture.url(name))
            let e = try XCTUnwrap(expectations[name])
            XCTAssertEqual(item.kind, e.kind, name)
            XCTAssertEqual(item.duration, e.duration, accuracy: 0.1, name)
            XCTAssertEqual(item.pixelWidth, e.size.0, name)
            XCTAssertEqual(item.pixelHeight, e.size.1, name)
            XCTAssertEqual(item.hasAudio, e.hasAudio, name)
            XCTAssertEqual(item.name, (name as NSString).deletingPathExtension, name)
            if e.kind == .video { XCTAssertEqual(item.frameRate, 30, accuracy: 0.5, name) } else { XCTAssertEqual(item.frameRate, 0, name) }
        }
    }

    func testFailuresAreReportedNotThrown() async throws {
        let text = tempDir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let fakeVideo = tempDir.appendingPathComponent("broken.mp4")
        try Data(repeating: 0x42, count: 4096).write(to: fakeVideo)
        let fakeImage = tempDir.appendingPathComponent("broken.png")
        try Data(repeating: 0x13, count: 512).write(to: fakeImage)
        let missing = tempDir.appendingPathComponent("gone.mov")
        let good = try Fixture.url("tone.wav")

        let (items, failures) = await MediaImporter.importFiles([text, fakeVideo, good, fakeImage, missing])
        XCTAssertEqual(items.map(\.name), ["tone"])
        XCTAssertEqual(failures.map(\.url), [text, fakeVideo, fakeImage, missing])
        XCTAssertEqual(failures[0].reason, MediaError.unsupported("").reason)
        XCTAssertEqual(failures[2].reason, MediaError.unreadableImage("").reason)
        XCTAssertEqual(failures[3].reason, MediaError.missing("").reason)
        XCTAssertFalse(failures[1].reason.isEmpty)
        XCTAssertFalse(failures[1].reason.contains("broken"), "reasons must not repeat the file name")

        do {
            _ = try await MediaImporter.probe(text)
            XCTFail("probe should throw for unsupported files")
        } catch let error as MediaError {
            XCTAssertEqual(error, .unsupported("notes.txt"))
        }
    }

    func testFolderImportKeepsOrderAndSkipsUnsupported() async throws {
        _ = try Fixture.url("clip_a.mp4")
        let (items, failures) = await MediaImporter.importFiles([Fixture.folder])
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(Set(items.map(\.name)), Set(Self.allFixtures.map { ($0 as NSString).deletingPathExtension }))
        let names = items.map(\.url.lastPathComponent)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        // Mixed folder + file input keeps input order; unsupported files inside folders are ignored.
        let folder = tempDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Fixture.url("logo.png"), to: folder.appendingPathComponent("b.png"))
        try FileManager.default.copyItem(at: try Fixture.url("tone.wav"), to: folder.appendingPathComponent("a.wav"))
        try "x".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let mixed = await MediaImporter.importFiles([try Fixture.url("clip_b.mov"), folder, try Fixture.url("music.mp3")])
        XCTAssertEqual(mixed.items.map(\.name), ["clip_b", "a", "b", "music"])
        XCTAssertTrue(mixed.failures.isEmpty)
    }

    func testImportingAllFixturesIsFast() async throws {
        let urls = try Self.allFixtures.map { try Fixture.url($0) }
        let clock = ContinuousClock()
        let start = clock.now
        let (items, failures) = await MediaImporter.importFiles(urls)
        let elapsed = clock.now - start
        XCTAssertEqual(items.count, 13)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(items.map(\.url), urls, "results must be in input order")
        XCTAssertLessThan(elapsed, .milliseconds(500), "importing 13 fixtures took \(elapsed)")
        print("Imported \(items.count) fixtures in \(elapsed)")
    }

    func testVideoDurationIsBoundedByPicture() async throws {
        let url = try await TestMedia.videoWithLongerAudio(in: tempDir, video: 2, audio: 3)
        let assetDuration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThan(assetDuration, 2.9, "the file's audio outlasts its picture")
        let item = try await MediaImporter.probe(url)
        XCTAssertEqual(item.kind, .video)
        XCTAssertTrue(item.hasAudio)
        XCTAssertEqual(item.duration, 2, accuracy: 0.05, "audio past the last frame must not lengthen the clip")
    }

    // MARK: - Waveforms

    @MainActor
    func testToneWaveform() async throws {
        let cache = WaveformCache(diskCacheDirectory: tempDir)
        let tone = try await MediaImporter.probe(try Fixture.url("tone.wav"))
        XCTAssertNil(cache.peaks(for: tone), "first lookup schedules work and returns nil")
        let peaks = try await waitFor { cache.peaks(for: tone) }
        XCTAssertEqual(Double(peaks.count), 400, accuracy: 3)
        XCTAssertTrue(peaks.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(peaks.filter { $0 > 0.3 }.count, 350)
        XCTAssertGreaterThan(cache.version, 0)
    }

    @MainActor
    func testSilentWaveformStaysFlat() async throws {
        let url = tempDir.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
            buffer.frameLength = 88_200 // zero-filled
            try file.write(from: buffer)
        }
        let silence = try await MediaImporter.probe(url)
        XCTAssertEqual(silence.duration, 2, accuracy: 0.05)
        let cache = WaveformCache(diskCacheDirectory: nil)
        let peaks = try await waitFor { cache.peaks(for: silence) }
        XCTAssertEqual(Double(peaks.count), 200, accuracy: 3)
        XCTAssertLessThan(peaks.max() ?? 1, 0.001)
    }

    @MainActor
    func testVideoWaveformAndMediaWithoutAudio() async throws {
        let cache = WaveformCache(diskCacheDirectory: nil)
        let clip = try await MediaImporter.probe(try Fixture.url("clip_a.mp4"))
        let peaks = try await waitFor { cache.peaks(for: clip) }
        XCTAssertEqual(Double(peaks.count), 600, accuracy: 6)
        XCTAssertGreaterThan(peaks.filter { $0 > 0.3 }.count, 500)

        let red = try await MediaImporter.probe(try Fixture.url("solid_red.mp4"))
        let photo = try await MediaImporter.probe(try Fixture.url("photo.jpg"))
        XCTAssertNil(cache.peaks(for: red))
        XCTAssertNil(cache.peaks(for: photo))
    }

    @MainActor
    func testWaveformsPersistToDisk() async throws {
        let tone = try await MediaImporter.probe(try Fixture.url("voice.ogg"))
        let first = WaveformCache(diskCacheDirectory: tempDir)
        let computed = try await waitFor { first.peaks(for: tone) }
        XCTAssertEqual(Double(computed.count), 300, accuracy: 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.hasSuffix(".bin") }
        XCTAssertEqual(files.count, 1)

        let second = WaveformCache(diskCacheDirectory: tempDir)
        let clock = ContinuousClock()
        let start = clock.now
        let reloaded = try await waitFor { second.peaks(for: tone) }
        XCTAssertEqual(reloaded, computed)
        XCTAssertLessThan(clock.now - start, .milliseconds(250))

        // A corrupt cache file is ignored and recomputed.
        try Data([1, 2, 3]).write(to: tempDir.appendingPathComponent(files[0]))
        let third = WaveformCache(diskCacheDirectory: tempDir)
        let recomputed = try await waitFor { third.peaks(for: tone) }
        XCTAssertEqual(recomputed, computed)
    }

    func testOggWaveforms() async throws {
        for name in ["voice.ogg", "opus.ogg", "music.mp3"] {
            let url = try Fixture.url(name)
            let computed = await WaveformAnalyzer.compute(url: url)
            let peaks = try XCTUnwrap(computed, name)
            let item = try await MediaImporter.probe(url)
            // Encoder padding makes the container duration slightly longer than the decoded audio.
            XCTAssertEqual(Double(peaks.count), item.duration * WaveformCache.peaksPerSecond, accuracy: 10, name)
            XCTAssertGreaterThan(peaks.filter { $0 > 0.3 }.count, peaks.count / 2, name)
        }
    }

    // MARK: - Thumbnails

    @MainActor
    func testPostersForVideoImageAndPortrait() async throws {
        let cache = ThumbnailCache()
        let clip = try await MediaImporter.probe(try Fixture.url("clip_a.mp4"))
        let photo = try await MediaImporter.probe(try Fixture.url("photo.jpg"))
        let portrait = try await MediaImporter.probe(try Fixture.url("rotated_portrait.mov"))
        let music = try await MediaImporter.probe(try Fixture.url("music.mp3"))

        XCTAssertNil(cache.poster(for: music))
        let clipPoster = try await waitFor { cache.poster(for: clip) }
        let photoPoster = try await waitFor { cache.poster(for: photo) }
        let portraitPoster = try await waitFor { cache.poster(for: portrait) }

        XCTAssertEqual(Double(clipPoster.height), 480, accuracy: 1)
        XCTAssertEqual(Double(clipPoster.width) / Double(clipPoster.height), 16.0 / 9, accuracy: 0.02)
        XCTAssertEqual(Double(photoPoster.height), 480, accuracy: 1)
        XCTAssertEqual(Double(photoPoster.width), 640, accuracy: 1)
        XCTAssertGreaterThan(portraitPoster.height, portraitPoster.width, "portrait video must stay portrait")
        XCTAssertEqual(Double(portraitPoster.width) / Double(portraitPoster.height), 9.0 / 16, accuracy: 0.02)
        XCTAssertLessThanOrEqual(portraitPoster.height, 480)
        XCTAssertNil(cache.poster(for: music))
    }

    @MainActor
    func testFilmstripFrames() async throws {
        let cache = ThumbnailCache()
        let clip = try await MediaImporter.probe(try Fixture.url("clip_a.mp4"))
        let portrait = try await MediaImporter.probe(try Fixture.url("rotated_portrait.mov"))
        let logo = try await MediaImporter.probe(try Fixture.url("logo.png"))

        _ = cache.frame(for: clip, at: 0)
        _ = cache.frame(for: portrait, at: 0)
        try await waitFor { cache.isFilmstripComplete(for: clip) && cache.isFilmstripComplete(for: portrait) ? true : nil }
        XCTAssertEqual(cache.filmstripFrameCount(for: clip), 6)
        XCTAssertEqual(cache.filmstripFrameCount(for: portrait), 4)

        let f0 = try XCTUnwrap(cache.frame(for: clip, at: 0))
        let f3 = try XCTUnwrap(cache.frame(for: clip, at: 3.2))
        XCTAssertEqual(Double(f0.height), 180, accuracy: 1)
        XCTAssertFalse(f0 === f3, "different times map to different frames")
        XCTAssertTrue(cache.frame(for: clip, at: 2.9) === f3, "nearest frame wins")
        XCTAssertTrue(cache.frame(for: clip, at: 100) === cache.frame(for: clip, at: 5))
        let p = try XCTUnwrap(cache.frame(for: portrait, at: 1))
        XCTAssertGreaterThan(p.height, p.width)

        let logoFrame = try await waitFor { cache.frame(for: logo, at: 2) }
        XCTAssertTrue(logoFrame === cache.poster(for: logo), "images use their poster as filmstrip frame")
    }

    @MainActor
    func testRepeatedLookupsDoNotDuplicateWork() async throws {
        let cache = ThumbnailCache()
        let clip = try await MediaImporter.probe(try Fixture.url("clip_b.mov"))
        let clock = ContinuousClock()
        let start = clock.now
        for i in 0..<2000 { _ = cache.frame(for: clip, at: Double(i % 5)) }
        XCTAssertLessThan(clock.now - start, .milliseconds(100), "lookups must never block")
        try await waitFor { cache.isFilmstripComplete(for: clip) ? true : nil }
        XCTAssertEqual(cache.filmstripFrameCount(for: clip), 5)
    }

    func testFilmstripTimesCapLongMedia() {
        XCTAssertEqual(ThumbnailCache.filmstripTimes(duration: 6), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(ThumbnailCache.filmstripTimes(duration: 0.5), [0])
        XCTAssertTrue(ThumbnailCache.filmstripTimes(duration: 0).isEmpty)
        let long = ThumbnailCache.filmstripTimes(duration: 3600)
        XCTAssertEqual(long.count, 200)
        XCTAssertEqual(long[1], 18, accuracy: 1e-9)
        XCTAssertLessThan(long.last!, 3600)
    }

    // MARK: - Demo project

    func testDemoProjectHasNonOverlappingClips() async throws {
        _ = try Fixture.url("clip_a.mp4")
        let project = await DemoProject.make(from: Fixture.folder)
        XCTAssertEqual(project.media.count, 13)
        XCTAssertFalse(project.tracks[0].clips.isEmpty)
        for track in project.tracks {
            XCTAssertEqual(track.clips.map(\.start), track.clips.map(\.start).sorted())
            for (a, b) in zip(track.clips, track.clips.dropFirst()) {
                XCTAssertLessThanOrEqual(a.end, b.start + 1e-9, "clips overlap on \(project.displayName(of: track.id))")
            }
            for clip in track.clips {
                XCTAssertTrue(track.accepts(project.media(clip.mediaID)?.kind), "incompatible clip on track")
            }
        }
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor until it yields a value or `timeout` elapses.
    @MainActor
    @discardableResult
    private func waitFor<T>(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = condition() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out after \(timeout)", file: file, line: line)
        throw MediaTestTimeout()
    }
}

private struct MediaTestTimeout: Error {}

/// Media generated at test time.
enum TestMedia {
    /// A movie (passthrough from `clip_a.mp4`) whose audio track runs longer than its video track.
    static func videoWithLongerAudio(in folder: URL, video: Double, audio: Double) async throws -> URL {
        let source = AVURLAsset(url: try Fixture.url("clip_a.mp4"))
        let videoTracks = try await source.loadTracks(withMediaType: .video)
        let audioTracks = try await source.loadTracks(withMediaType: .audio)
        let v = try XCTUnwrap(videoTracks.first), a = try XCTUnwrap(audioTracks.first)
        let comp = AVMutableComposition()
        let cv = try XCTUnwrap(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let ca = try XCTUnwrap(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: video, preferredTimescale: 600)), of: v, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: audio, preferredTimescale: 600)), of: a, at: .zero)
        let url = folder.appendingPathComponent("longaudio-\(UUID().uuidString).mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mov)
        return url
    }
}
