import XCTest
@testable import EditRushCore

/// Thumbnails and waveforms of media whose file was missing load once the file is back and the
/// caches are told to retry.
final class MediaCacheRetryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushCacheRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Probes `fixture`, then points the item at a not-yet-existing copy in `tempDir`.
    private func offlineCopy(of fixture: String) async throws -> (media: MediaItem, source: URL) {
        let source = try Fixture.url(fixture)
        var media = try await MediaImporter.probe(source)
        media.url = tempDir.appendingPathComponent("offline-\(fixture)")
        return (media, source)
    }

    @MainActor
    func testPosterAndFilmstripLoadAfterMissingFileReturns() async throws {
        let cache = ThumbnailCache()
        let (clip, source) = try await offlineCopy(of: "clip_a.mp4")

        XCTAssertNil(cache.frame(for: clip, at: 1))
        try await waitFor { cache.hasFailed(clip.url) ? true : nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(cache.poster(for: clip), "a failed poster is not retried on its own")
        XCTAssertFalse(cache.isFilmstripComplete(for: clip))

        try FileManager.default.copyItem(at: source, to: clip.url)
        XCTAssertNil(cache.poster(for: clip), "still cached as failed until retried")
        cache.retryFailures(for: [clip.url])
        XCTAssertFalse(cache.hasFailed(clip.url))
        let poster = try await waitFor { cache.poster(for: clip) }
        XCTAssertGreaterThan(poster.width, 0)
        _ = cache.frame(for: clip, at: 1)
        try await waitFor { cache.isFilmstripComplete(for: clip) ? true : nil }
        XCTAssertEqual(cache.filmstripFrameCount(for: clip), 6)
    }

    @MainActor
    func testImagePosterLoadsAfterMissingFileReturns() async throws {
        let cache = ThumbnailCache()
        let (photo, source) = try await offlineCopy(of: "photo.jpg")
        XCTAssertNil(cache.poster(for: photo))
        try await waitFor { cache.hasFailed(photo.url) ? true : nil }

        try FileManager.default.copyItem(at: source, to: photo.url)
        cache.retryFailures(for: [photo.url])
        try await waitFor { cache.poster(for: photo) }
    }

    @MainActor
    func testRetryLeavesHealthyMediaAlone() async throws {
        let cache = ThumbnailCache()
        let clip = try await MediaImporter.probe(try Fixture.url("clip_b.mov"))
        let poster = try await waitFor { cache.poster(for: clip) }
        let version = cache.version
        cache.retryFailures(for: [clip.url])
        XCTAssertTrue(cache.poster(for: clip) === poster)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cache.version, version, "nothing to retry, so no re-render")
    }

    @MainActor
    func testWaveformLoadsAfterMissingFileReturns() async throws {
        let cache = WaveformCache(diskCacheDirectory: tempDir.appendingPathComponent("waveforms"))
        let (tone, source) = try await offlineCopy(of: "tone.wav")

        XCTAssertNil(cache.peaks(for: tone))
        try await waitFor { cache.hasFailed(tone.url) ? true : nil }
        XCTAssertNil(cache.peaks(for: tone), "a failure is not stored as an empty waveform")

        try FileManager.default.copyItem(at: source, to: tone.url)
        cache.retryFailures(for: [tone.url])
        XCTAssertFalse(cache.hasFailed(tone.url))
        let peaks = try await waitFor { cache.peaks(for: tone) }
        XCTAssertEqual(Double(peaks.count), 400, accuracy: 3)
    }

    // MARK: - Helpers

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
        throw CacheRetryTimeout()
    }
}

private struct CacheRetryTimeout: Error {}
