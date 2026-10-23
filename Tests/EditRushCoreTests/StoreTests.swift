import XCTest
@testable import EditRushCore

@MainActor
final class StoreTests: XCTestCase {
    // MARK: Fixtures

    private let video = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/video.mp4"), name: "video.mp4", kind: .video,
                                  duration: 10, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, hasAudio: true)
    private let silentVideo = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/silent.mov"), name: "silent.mov", kind: .video,
                                        duration: 4, pixelWidth: 640, pixelHeight: 360, frameRate: 30, hasAudio: false)
    private let audio = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/music.mp3"), name: "music.mp3", kind: .audio,
                                  duration: 8, hasAudio: true)
    private let image = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/photo.jpg"), name: "photo.jpg", kind: .image,
                                  duration: 0, pixelWidth: 4000, pixelHeight: 3000)

    private func makeStore() -> EditorStore {
        let store = EditorStore()
        store.addMedia([video, silentVideo, audio, image])
        return store
    }

    /// A store whose first video track holds clips at the given (start, duration) of `video`.
    private func storeWithV1(_ spans: [(Seconds, Seconds)], sourceIns: [Seconds]? = nil) -> (EditorStore, [UUID]) {
        var p = Project.empty()
        p.media = [video, silentVideo, audio, image]
        var ids: [UUID] = []
        for (i, s) in spans.enumerated() {
            let c = Clip(mediaID: video.id, start: s.0, duration: s.1, sourceIn: sourceIns?[i] ?? 0)
            ids.append(c.id)
            p.tracks[0].clips.append(c)
        }
        let store = EditorStore(project: p)
        return (store, ids)
    }

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        EditorStore.flushPendingAutosaves()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func assertInvariants(_ p: Project, context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let fps = p.canvas.frameRate
        func check(_ ok: Bool, _ what: String) { XCTAssertTrue(ok, "\(what) \(context)", file: file, line: line) }
        for track in p.tracks {
            for c in track.clips {
                check(abs(c.start * fps - (c.start * fps).rounded()) < 1e-6, "unquantized start")
                check(abs(c.duration * fps - (c.duration * fps).rounded()) < 1e-6, "unquantized duration")
                check(c.duration >= p.canvas.frameDuration - 1e-9, "shorter than a frame")
                check(c.start >= 0, "negative start")
                check(c.fadeIn >= 0 && c.fadeOut >= 0 && c.fadeIn + c.fadeOut <= c.duration + 1e-9, "fades exceed duration")
                check(c.sourceIn >= 0, "negative sourceIn")
                if let m = p.media(c.mediaID), m.kind != .image {
                    check(c.sourceOut <= m.duration + 1e-6, "past the end of the source")
                }
                if track.kind == .audio {
                    check(c.mediaID != nil && c.text == nil, "non-audio content on an audio track")
                } else {
                    check(p.media(c.mediaID)?.kind != .audio, "audio media on a video track")
                }
            }
            for (a, b) in zip(track.clips, track.clips.dropFirst()) {
                check(a.start <= b.start, "unsorted")
                check(a.end <= b.start + 1e-6, "overlap")
            }
        }
    }

    // MARK: Media

    func testAddMediaDedupesByStandardizedURL() {
        let store = makeStore()
        XCTAssertEqual(store.project.media.count, 4)
        let dup = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/../editrush-tests/video.mp4"), name: "again", kind: .video, duration: 10)
        let fresh = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/new.wav"), name: "new.wav", kind: .audio, duration: 2)
        let fresh2 = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/new.wav"), name: "new.wav", kind: .audio, duration: 2)
        store.addMedia([dup, fresh, fresh2])
        XCTAssertEqual(store.project.media.count, 5)
        XCTAssertEqual(store.project.media.last?.id, fresh.id)
        let revision = store.revision
        store.addMedia([dup])
        XCTAssertEqual(store.revision, revision, "no change, no revision bump")
    }

    func testRemoveMediaRemovesClipsInOneUndoStep() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addClip(mediaID: video.id, at: 0))
        let b = try XCTUnwrap(store.addClip(mediaID: video.id, at: 20))
        let c = try XCTUnwrap(store.addClip(mediaID: image.id, at: 0))
        store.selectedMediaID = video.id
        store.selection = [a, b, c]
        store.removeMedia(video.id)
        XCTAssertNil(store.project.media(video.id))
        XCTAssertNil(store.clip(a)); XCTAssertNil(store.clip(b))
        XCTAssertNotNil(store.clip(c))
        XCTAssertNil(store.selectedMediaID)
        XCTAssertEqual(store.selection, [c])
        XCTAssertEqual(store.undoActionName, "Remove Media")
        store.undo()
        XCTAssertNotNil(store.clip(a)); XCTAssertNotNil(store.clip(b))
        XCTAssertNotNil(store.project.media(video.id))
    }

    // MARK: Nearest free start

    func testNearestFreeStart() {
        var t = Track(kind: .video)
        t.clips = [Clip(mediaID: nil, start: 2, duration: 2), Clip(mediaID: nil, start: 5, duration: 3)]   // [2,4] [5,8]
        XCTAssertEqual(t.nearestFreeStart(duration: 1, near: 0.5), 0.5)          // fits as desired
        XCTAssertEqual(t.nearestFreeStart(duration: 1, near: 2.4), 1)            // before first clip is closer
        XCTAssertEqual(t.nearestFreeStart(duration: 1, near: 3.6), 4)            // gap [4,5] fits exactly
        XCTAssertEqual(t.nearestFreeStart(duration: 2, near: 3.6), 0)            // [4,5] too small; [0,2] is closer than 8
        XCTAssertEqual(t.nearestFreeStart(duration: 2, near: 5.5), 8)            // after the last clip is closer
        XCTAssertEqual(t.nearestFreeStart(duration: 3, near: 1), 8)              // nothing before fits
        XCTAssertEqual(t.nearestFreeStart(duration: 1, near: -3), 0)             // clamped at 0
        XCTAssertEqual(t.nearestFreeStart(duration: 2, near: 5, excluding: [t.clips[1].id]), 5)
        XCTAssertTrue(t.isFree(start: 4, duration: 1))
        XCTAssertFalse(t.isFree(start: 3.9, duration: 1))
        XCTAssertTrue(Track(kind: .video).isFree(start: 0, duration: 100))
    }

    // MARK: addClip / addTextClip

    func testAddClipDefaultsAndSelection() throws {
        let store = makeStore()
        store.playhead = 1.01
        let v = try XCTUnwrap(store.addClip(mediaID: video.id))
        let clip = try XCTUnwrap(store.clip(v))
        XCTAssertEqual(clip.start, 1.0, accuracy: 1e-9, "quantized playhead")
        XCTAssertEqual(clip.duration, 10, accuracy: 1e-9)
        XCTAssertEqual(store.selection, [v])
        XCTAssertEqual(store.project.track(containing: v)?.id, store.project.tracks[0].id)

        let i = try XCTUnwrap(store.addClip(mediaID: image.id, at: 20))
        XCTAssertEqual(try XCTUnwrap(store.clip(i)).duration, 5, accuracy: 1e-9)
        XCTAssertEqual(store.project.track(containing: i)?.id, store.project.tracks[0].id, "V1 is free at 20")

        let a = try XCTUnwrap(store.addClip(mediaID: audio.id, at: 0))
        XCTAssertEqual(store.project.track(containing: a)?.kind, .audio)
        XCTAssertEqual(try XCTUnwrap(store.clip(a)).duration, 8, accuracy: 1e-9)
        XCTAssertNil(store.addClip(mediaID: UUID()))
        assertInvariants(store.project)
    }

    func testAddClipPicksLowestFreeTrackThenCreatesVideoTrackAboveVideoTracks() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.addClip(mediaID: video.id, at: 0))
        let second = try XCTUnwrap(store.addClip(mediaID: video.id, at: 2))
        XCTAssertEqual(store.project.locate(clip: first)?.track, 0)
        XCTAssertEqual(store.project.locate(clip: second)?.track, 1, "V1 busy → V2")
        let third = try XCTUnwrap(store.addClip(mediaID: image.id, at: 3))
        XCTAssertEqual(store.project.tracks.map(\.kind), [.video, .video, .video, .audio, .audio])
        XCTAssertEqual(store.project.locate(clip: third)?.track, 2, "new video track inserted after the last video track")
        XCTAssertEqual(store.project.displayName(of: store.project.tracks[2].id), "V3")
        assertInvariants(store.project)
    }

    func testAddAudioClipCreatesAudioTrackAtEnd() throws {
        let store = makeStore()
        store.addClip(mediaID: audio.id, at: 0)
        store.addClip(mediaID: audio.id, at: 1)
        let third = try XCTUnwrap(store.addClip(mediaID: audio.id, at: 2))
        XCTAssertEqual(store.project.tracks.count, 5)
        XCTAssertEqual(store.project.locate(clip: third)?.track, 4)
        XCTAssertEqual(store.project.tracks[4].kind, .audio)
    }

    func testAddClipOnExplicitTrackResolvesOverlap() throws {
        let store = makeStore()
        let v1 = store.project.tracks[0].id
        store.addClip(mediaID: image.id, trackID: v1, at: 0)        // [0,5]
        let b = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: v1, at: 3))
        XCTAssertEqual(store.project.locate(clip: b)?.track, 0)
        XCTAssertEqual(try XCTUnwrap(store.clip(b)).start, 5, accuracy: 1e-9)
        // Incompatible explicit track falls back to an audio track.
        let a = try XCTUnwrap(store.addClip(mediaID: audio.id, trackID: v1, at: 0))
        XCTAssertEqual(store.project.track(containing: a)?.kind, .audio)
        assertInvariants(store.project)
    }

    func testAddClipSkipsLockedTracks() throws {
        let store = makeStore()
        store.setTrack(store.project.tracks[0].id, locked: true)
        let id = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: store.project.tracks[0].id, at: 0))
        XCTAssertEqual(store.project.locate(clip: id)?.track, 1)
    }

    func testAddClipQuantizesMediaDurationDown() throws {
        let store = makeStore()
        let odd = MediaItem(url: URL(fileURLWithPath: "/tmp/editrush-tests/odd.mov"), name: "odd", kind: .video, duration: 2.019, hasAudio: false)
        store.addMedia([odd])
        let id = try XCTUnwrap(store.addClip(mediaID: odd.id, at: 0))
        XCTAssertEqual(try XCTUnwrap(store.clip(id)).duration, 2.0, accuracy: 1e-9)
    }

    func testAddTextClipUsesTopmostFreeVideoTrack() throws {
        let store = makeStore()
        let t1 = try XCTUnwrap(store.addTextClip(at: 1))
        XCTAssertEqual(store.project.locate(clip: t1)?.track, 1, "topmost video track")
        let text = try XCTUnwrap(store.clip(t1))
        XCTAssertEqual(text.duration, 5, accuracy: 1e-9)
        XCTAssertEqual(text.text, TextStyle())
        XCTAssertNil(text.mediaID)
        let t2 = try XCTUnwrap(store.addTextClip(at: 2, style: TextStyle(text: "Two")))
        XCTAssertEqual(store.project.locate(clip: t2)?.track, 0, "V2 busy → V1")
        let t3 = try XCTUnwrap(store.addTextClip(at: 3))
        XCTAssertEqual(store.project.locate(clip: t3)?.track, 2, "new video track above")
        XCTAssertEqual(store.project.videoTracks.count, 3)
        XCTAssertEqual(store.selection, [t3])
        assertInvariants(store.project)
    }

    // MARK: Split

    func testSplitVideoAdvancesSourceInAndMovesFades() throws {
        let (store, ids) = storeWithV1([(1, 6)], sourceIns: [2])
        store.updateClip(ids[0], "Fades") { $0.fadeIn = 1; $0.fadeOut = 1.5 }
        let right = try XCTUnwrap(store.split(clipID: ids[0], at: 3.01))
        let l = try XCTUnwrap(store.clip(ids[0])), r = try XCTUnwrap(store.clip(right))
        XCTAssertEqual(l.start, 1, accuracy: 1e-9); XCTAssertEqual(l.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(l.sourceIn, 2, accuracy: 1e-9)
        XCTAssertEqual(r.start, 3, accuracy: 1e-9); XCTAssertEqual(r.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(r.sourceIn, 4, accuracy: 1e-9)
        XCTAssertEqual(l.fadeIn, 1); XCTAssertEqual(l.fadeOut, 0)
        XCTAssertEqual(r.fadeIn, 0); XCTAssertEqual(r.fadeOut, 1.5)
        XCTAssertNotEqual(right, ids[0])
        XCTAssertEqual(store.selection, [right])
        assertInvariants(store.project)
    }

    func testSplitClampsFadesToNewDurations() throws {
        let (store, ids) = storeWithV1([(0, 6)])
        store.updateClip(ids[0], "Fades") { $0.fadeIn = 3; $0.fadeOut = 3 }
        let right = try XCTUnwrap(store.split(clipID: ids[0], at: 1))
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[0])).fadeIn, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.clip(right)).fadeOut, 3, accuracy: 1e-9)
    }

    func testSplitImageKeepsSourceInZero() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addClip(mediaID: image.id, at: 0))
        let right = try XCTUnwrap(store.split(clipID: id, at: 2))
        XCTAssertEqual(try XCTUnwrap(store.clip(right)).sourceIn, 0)
        XCTAssertEqual(try XCTUnwrap(store.clip(right)).duration, 3, accuracy: 1e-9)
    }

    func testSplitNoOpNearEdgesAndOnLockedTracks() throws {
        let (store, ids) = storeWithV1([(0, 2)])
        XCTAssertNil(store.split(clipID: ids[0], at: 0.01))
        XCTAssertNil(store.split(clipID: ids[0], at: 1.99))
        XCTAssertNotNil(store.split(clipID: ids[0], at: 1.0 / 30), "exactly one frame in is allowed")
        store.undo()
        store.setTrack(store.project.tracks[0].id, locked: true)
        XCTAssertNil(store.split(clipID: ids[0], at: 1))
        XCTAssertEqual(store.project.tracks[0].clips.count, 1)
    }

    func testSplitAtPlayheadPrefersSelectedClipsUnderPlayhead() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addClip(mediaID: video.id, at: 0))
        let b = try XCTUnwrap(store.addClip(mediaID: image.id, at: 0))
        let c = try XCTUnwrap(store.addClip(mediaID: audio.id, at: 0))
        store.playhead = 2
        store.selection = [b]
        store.splitAtPlayhead()
        XCTAssertEqual(store.project.tracks[0].clips.count, 1, "unselected video untouched")
        XCTAssertEqual(store.project.tracks[1].clips.count, 2)
        XCTAssertEqual(store.undoActionName, "Split")

        // Selected clip not under the playhead → split everything under the playhead (unlocked).
        store.selection = [a]
        store.playhead = 12
        store.splitAtPlayhead()
        XCTAssertEqual(store.project.tracks[0].clips.count, 1, "nothing under playhead at 12")

        store.selection = []
        store.playhead = 1
        store.setTrack(store.project.tracks[2].id, locked: true)
        store.splitAtPlayhead()
        XCTAssertEqual(store.project.tracks[0].clips.count, 2)
        XCTAssertEqual(store.project.tracks[1].clips.count, 3)
        XCTAssertEqual(store.project.tracks[2].clips.count, 1, "locked audio track untouched")
        XCTAssertEqual(store.selection.count, 2, "right parts selected")
        XCTAssertTrue(store.selection.allSatisfy { abs((store.clip($0)?.start ?? -1) - 1) < 1e-9 })
        XCTAssertNotNil(store.clip(c))
        assertInvariants(store.project)
    }

    // MARK: Join

    func testJoinAfterSplitRestoresClip() throws {
        let (store, ids) = storeWithV1([(0, 6)], sourceIns: [1])
        store.updateClip(ids[0], "Fades") { $0.fadeIn = 0.5; $0.fadeOut = 1; $0.transform.scale = 0.5 }
        let original = try XCTUnwrap(store.clip(ids[0]))
        let right = try XCTUnwrap(store.split(clipID: ids[0], at: 2))
        let right2 = try XCTUnwrap(store.split(clipID: right, at: 4))
        store.selection = [ids[0], right, right2]
        XCTAssertTrue(store.canJoinSelection)
        store.joinSelection()
        XCTAssertEqual(store.project.tracks[0].clips, [original])
        XCTAssertEqual(store.selection, [ids[0]])
        XCTAssertEqual(store.undoActionName, "Join Clips")
    }

    func testJoinImagesAndTextAfterSplit() throws {
        let store = makeStore()
        let img = try XCTUnwrap(store.addClip(mediaID: image.id, at: 0))
        let imgRight = try XCTUnwrap(store.split(clipID: img, at: 2))
        store.selection = [img, imgRight]
        XCTAssertTrue(store.canJoinSelection)
        store.joinSelection()
        XCTAssertEqual(store.clip(img)?.duration ?? 0, 5, accuracy: 1e-9)

        let text = try XCTUnwrap(store.addTextClip(at: 10))
        let textRight = try XCTUnwrap(store.split(clipID: text, at: 12))
        store.selection = [text, textRight]
        XCTAssertTrue(store.canJoinSelection)
        store.updateClip(textRight, "Edit Text") { $0.text?.text = "Different" }
        XCTAssertFalse(store.canJoinSelection, "different text cannot merge")
    }

    func testJoinRejectsInvalidSelections() throws {
        // Gap between clips.
        let (s1, gapIDs) = storeWithV1([(0, 2), (3, 2)], sourceIns: [0, 3])
        s1.selection = Set(gapIDs)
        XCTAssertFalse(s1.canJoinSelection)
        // Adjacent but non-continuous source.
        let (s2, jumpIDs) = storeWithV1([(0, 2), (2, 2)], sourceIns: [0, 5])
        s2.selection = Set(jumpIDs)
        XCTAssertFalse(s2.canJoinSelection)
        let before = s2.project
        s2.joinSelection()
        XCTAssertEqual(s2.project, before)
        XCTAssertFalse(s2.canUndo)
        // Single clip.
        s2.selection = [jumpIDs[0]]
        XCTAssertFalse(s2.canJoinSelection)
        // Different media.
        let store = makeStore()
        let a = try XCTUnwrap(store.addClip(mediaID: silentVideo.id, at: 0))
        let b = try XCTUnwrap(store.addClip(mediaID: video.id, trackID: store.project.tracks[0].id, at: 4))
        store.selection = [a, b]
        XCTAssertFalse(store.canJoinSelection)
        // Different tracks.
        let c = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: store.project.tracks[1].id, at: 4))
        store.selection = [a, c]
        XCTAssertFalse(store.canJoinSelection)
        // Locked track.
        let (s3, ids3) = storeWithV1([(0, 2), (2, 2)], sourceIns: [0, 2])
        s3.selection = Set(ids3)
        XCTAssertTrue(s3.canJoinSelection)
        s3.setTrack(s3.project.tracks[0].id, locked: true)
        XCTAssertFalse(s3.canJoinSelection)
    }

    // MARK: Delete & gaps

    func testDeleteNonRipple() {
        let (store, ids) = storeWithV1([(0, 2), (2, 2), (4, 2)])
        store.selection = [ids[1]]
        store.deleteSelection(ripple: false)
        XCTAssertEqual(store.project.tracks[0].clips.map(\.start), [0, 4])
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testRippleDeleteMultipleClips() {
        // [0,2] [2,4] gap [5,6] [6,9] [10,11]
        let (store, ids) = storeWithV1([(0, 2), (2, 2), (5, 1), (6, 3), (10, 1)])
        store.selection = [ids[1], ids[3]]
        store.deleteSelection(ripple: true)
        let clips = store.project.tracks[0].clips
        XCTAssertEqual(clips.map(\.id), [ids[0], ids[2], ids[4]])
        XCTAssertEqual(clips[1].start, 3, accuracy: 1e-9, "shifted by 2")
        XCTAssertEqual(clips[2].start, 5, accuracy: 1e-9, "shifted by 2 + 3")
        XCTAssertEqual(store.undoActionName, "Ripple Delete")
        assertInvariants(store.project)
        store.undo()
        XCTAssertEqual(store.project.tracks[0].clips.map(\.id), ids)
    }

    func testRippleDeleteOnlyAffectsOwnTrackAndRespectsLock() throws {
        let (store, ids) = storeWithV1([(0, 2), (2, 2)])
        let other = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: store.project.tracks[1].id, at: 3))
        store.selection = [ids[0]]
        store.deleteSelection(ripple: true)
        XCTAssertEqual(store.project.tracks[0].clips.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(store.clip(other)?.start ?? -1, 3, accuracy: 1e-9)

        store.setTrack(store.project.tracks[0].id, locked: true)
        store.selection = [ids[1]]
        store.deleteSelection(ripple: false)
        XCTAssertNotNil(store.clip(ids[1]))
    }

    func testCloseGapsWithSelectionAndAll() {
        let (store, ids) = storeWithV1([(1, 1), (3, 1), (6, 1)])
        store.selection = [ids[1]]
        store.closeGaps()
        XCTAssertEqual(store.project.tracks[0].clips.map(\.start), [1, 2, 5])
        store.selection = []
        store.closeGaps()
        XCTAssertEqual(store.project.tracks[0].clips.map(\.start), [0, 1, 2])
        assertInvariants(store.project)
    }

    // MARK: Duplicate

    func testDuplicatePlacesCopiesAfterOriginals() {
        let (store, ids) = storeWithV1([(0, 2), (2, 2), (10, 1)])
        store.selection = [ids[0], ids[1]]
        store.duplicateSelection()
        let clips = store.project.tracks[0].clips
        XCTAssertEqual(clips.map(\.start), [0, 2, 4, 6, 10])
        XCTAssertEqual(store.selection.count, 2)
        XCTAssertFalse(store.selection.contains(ids[0]))
        XCTAssertEqual(Set(clips[2...3].map(\.id)), store.selection)
        XCTAssertEqual(clips[2].sourceIn, clips[0].sourceIn)
        assertInvariants(store.project)
    }

    // MARK: Move

    func testMoveClipResolvesOverlapAndChecksCompatibility() throws {
        let (store, ids) = storeWithV1([(0, 2), (4, 2)])
        XCTAssertTrue(store.moveClip(ids[0], toTrack: store.project.tracks[0].id, start: 3.5))
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 2, accuracy: 1e-9, "nearest free start before the [4,6] clip")
        XCTAssertTrue(store.moveClip(ids[0], toTrack: store.project.tracks[1].id, start: 3.51))
        XCTAssertEqual(store.project.locate(clip: ids[0])?.track, 1)
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 3.5, accuracy: 1e-9)
        XCTAssertFalse(store.moveClip(ids[0], toTrack: store.project.tracks[2].id, start: 0), "video → audio refused")
        XCTAssertFalse(store.moveClip(ids[0], toTrack: UUID(), start: 0))
        XCTAssertTrue(store.moveClip(ids[0], toTrack: store.project.tracks[1].id, start: -5))
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 0, accuracy: 1e-9)
        assertInvariants(store.project)
    }

    func testMoveClipRefusedForLockedSourceOrTarget() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.setTrack(store.project.tracks[1].id, locked: true)
        XCTAssertFalse(store.moveClip(ids[0], toTrack: store.project.tracks[1].id, start: 0))
        store.setTrack(store.project.tracks[1].id, locked: false)
        store.setTrack(store.project.tracks[0].id, locked: true)
        XCTAssertFalse(store.moveClip(ids[0], toTrack: store.project.tracks[1].id, start: 0))
        XCTAssertEqual(store.project.locate(clip: ids[0])?.track, 0)
    }

    func testMoveCoalescingIsOneUndoStep() {
        let (store, ids) = storeWithV1([(0, 2)])
        let original = store.project
        let v1 = store.project.tracks[0].id
        for x in stride(from: 0.5, through: 5, by: 0.5) {
            store.moveClip(ids[0], toTrack: v1, start: x, coalesce: "move-\(ids[0])")
        }
        store.endCoalescing()
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 5, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.project, original)
        XCTAssertFalse(store.canUndo)
        store.redo()
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 5, accuracy: 1e-9)

        // After endCoalescing the same key starts a new step.
        store.moveClip(ids[0], toTrack: v1, start: 6, coalesce: "move-\(ids[0])")
        store.endCoalescing()
        store.moveClip(ids[0], toTrack: v1, start: 7, coalesce: "move-\(ids[0])")
        store.undo()
        XCTAssertEqual(store.clip(ids[0])?.start ?? -1, 6, accuracy: 1e-9)
    }

    // MARK: Trim

    func testTrimLeadingClampedByMediaStartAndNeighbour() {
        // [0,1] then a 10 s source clip at [3,7] with sourceIn 1.
        let (store, ids) = storeWithV1([(0, 1), (3, 4)], sourceIns: [0, 1])
        store.trimClip(ids[1], edge: .leading, to: 0)
        var c = store.clip(ids[1])!
        XCTAssertEqual(c.start, 2, accuracy: 1e-9, "sourceIn can't go below 0")
        XCTAssertEqual(c.sourceIn, 0, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 5, accuracy: 1e-9)
        XCTAssertEqual(c.end, 7, accuracy: 1e-9)

        store.trimClip(ids[1], edge: .leading, to: 4)
        c = store.clip(ids[1])!
        XCTAssertEqual(c.start, 4, accuracy: 1e-9)
        XCTAssertEqual(c.sourceIn, 2, accuracy: 1e-9)
        XCTAssertEqual(c.end, 7, accuracy: 1e-9)

        // Neighbour clamp: second clip has plenty of source before it.
        let (s2, ids2) = storeWithV1([(0, 2), (3, 2)], sourceIns: [0, 5])
        s2.trimClip(ids2[1], edge: .leading, to: 0.5)
        XCTAssertEqual(s2.clip(ids2[1])!.start, 2, accuracy: 1e-9)
        XCTAssertEqual(s2.clip(ids2[1])!.sourceIn, 4, accuracy: 1e-9)

        // 1-frame minimum.
        s2.trimClip(ids2[1], edge: .leading, to: 100)
        XCTAssertEqual(s2.clip(ids2[1])!.duration, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(s2.clip(ids2[1])!.end, 5, accuracy: 1e-9)
        assertInvariants(s2.project)
    }

    func testTrimTrailingClampedByMediaEndAndNeighbour() {
        let (store, ids) = storeWithV1([(0, 2), (20, 1)], sourceIns: [3, 0])
        store.trimClip(ids[0], edge: .trailing, to: 50)
        XCTAssertEqual(store.clip(ids[0])!.duration, 7, accuracy: 1e-9, "media is 10 s, sourceIn 3")
        store.trimClip(ids[0], edge: .trailing, to: -3)
        XCTAssertEqual(store.clip(ids[0])!.duration, 1.0 / 30, accuracy: 1e-9)

        let (s2, ids2) = storeWithV1([(0, 2), (4, 1)])
        s2.trimClip(ids2[0], edge: .trailing, to: 9)
        XCTAssertEqual(s2.clip(ids2[0])!.end, 4, accuracy: 1e-9, "stops at the next clip")
        assertInvariants(s2.project)
    }

    func testTrimImagesAndTextAreUnbounded() throws {
        let store = makeStore()
        let img = try XCTUnwrap(store.addClip(mediaID: image.id, at: 10))
        store.trimClip(img, edge: .trailing, to: 100)
        XCTAssertEqual(store.clip(img)!.end, 100, accuracy: 1e-9)
        store.trimClip(img, edge: .leading, to: 0)
        XCTAssertEqual(store.clip(img)!.start, 0, accuracy: 1e-9)
        XCTAssertEqual(store.clip(img)!.sourceIn, 0)
        let text = try XCTUnwrap(store.addTextClip(at: 0))
        store.trimClip(text, edge: .trailing, to: 60)
        XCTAssertEqual(store.clip(text)!.duration, 60, accuracy: 1e-9)
    }

    func testTrimClampsFadesAndRespectsLock() {
        let (store, ids) = storeWithV1([(0, 6)])
        store.updateClip(ids[0], "Fades") { $0.fadeIn = 2; $0.fadeOut = 2 }
        store.trimClip(ids[0], edge: .trailing, to: 2)
        let c = store.clip(ids[0])!
        XCTAssertEqual(c.fadeIn + c.fadeOut, 2, accuracy: 1e-9)
        XCTAssertEqual(c.fadeIn, 1, accuracy: 1e-9)

        store.setTrack(store.project.tracks[0].id, locked: true)
        store.trimClip(ids[0], edge: .trailing, to: 5)
        XCTAssertEqual(store.clip(ids[0])!.duration, 2, accuracy: 1e-9)
    }

    func testTrimCoalescing() {
        let (store, ids) = storeWithV1([(0, 2)])
        let original = store.project
        for t in [2.5, 3.0, 3.5, 4.0] { store.trimClip(ids[0], edge: .trailing, to: t, coalesce: "trim") }
        store.endCoalescing()
        XCTAssertEqual(store.clip(ids[0])!.duration, 4, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.project, original)
    }

    // MARK: updateClip normalisation

    func testUpdateClipClampsValues() throws {
        let store = makeStore()
        let text = try XCTUnwrap(store.addTextClip(at: 0))
        store.updateClip(text, "Edit") { c in
            c.transform.opacity = 3
            c.transform.scale = 0
            c.volume = -1
            c.filterIntensity = 7
            c.fadeIn = 4; c.fadeOut = 6
            c.text?.fontSize = 2
            c.color.exposure = 9; c.color.brightness = -5; c.color.contrast = 0
            c.color.saturation = 3; c.color.temperature = -4; c.color.vignette = 2
            c.id = UUID()
        }
        let c = try XCTUnwrap(store.clip(text), "id changes are ignored")
        XCTAssertEqual(c.transform.opacity, 1)
        XCTAssertEqual(c.transform.scale, 0.02)
        XCTAssertEqual(c.volume, 0)
        XCTAssertEqual(c.filterIntensity, 1)
        XCTAssertEqual(c.fadeIn, 2, accuracy: 1e-9, "scaled proportionally: 4/10 × 5")
        XCTAssertEqual(c.fadeOut, 3, accuracy: 1e-9)
        XCTAssertEqual(c.text?.fontSize, 0.6)
        XCTAssertEqual(c.color.exposure, 2); XCTAssertEqual(c.color.brightness, -1)
        XCTAssertEqual(c.color.contrast, 0.25); XCTAssertEqual(c.color.saturation, 2)
        XCTAssertEqual(c.color.temperature, -1); XCTAssertEqual(c.color.vignette, 1)

        store.updateClip(text, "Edit") { $0.transform.scale = 100; $0.fadeIn = -1; $0.text?.fontSize = 0 }
        XCTAssertEqual(store.clip(text)!.transform.scale, 20)
        XCTAssertEqual(store.clip(text)!.fadeIn, 0)
        XCTAssertEqual(store.clip(text)!.text?.fontSize, 0.01)
    }

    func testUpdateClipTimingStaysValid() {
        let (store, ids) = storeWithV1([(0, 2), (2, 2)])
        store.updateClip(ids[0], "Duration") { $0.duration = 50 }
        XCTAssertEqual(store.clip(ids[0])!.duration, 10, accuracy: 1e-9, "bounded by 10 s source")
        XCTAssertGreaterThanOrEqual(store.clip(ids[0])!.start, 4 - 1e-9, "moved off the neighbour")
        store.updateClip(ids[1], "Start") { $0.start = 1.234 }
        XCTAssertEqual(store.clip(ids[1])!.start * 30, (store.clip(ids[1])!.start * 30).rounded(), accuracy: 1e-9)
        assertInvariants(store.project)
    }

    func testUpdateClipNoChangeRecordsNoUndo() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.updateClip(ids[0], "Opacity") { $0.transform.opacity = 1 }
        XCTAssertFalse(store.canUndo)
        store.updateClip(ids[0], "Opacity") { $0.transform.opacity = 5 }   // clamps to the current value
        XCTAssertFalse(store.canUndo)
    }

    func testUpdateClipSliderCoalescing() {
        let (store, ids) = storeWithV1([(0, 2)])
        for v in [0.9, 0.7, 0.5, 0.3, 0.1] {
            store.updateClip(ids[0], "Opacity", coalesce: "opacity-\(ids[0])") { $0.transform.opacity = v }
        }
        store.endCoalescing()
        store.updateClip(ids[0], "Scale") { $0.transform.scale = 2 }
        XCTAssertEqual(store.undoActionName, "Scale")
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.opacity, 0.1, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.opacity, 1)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(store.redoActionName, "Opacity")
    }

    // MARK: Detach audio, fades

    func testDetachAudio() throws {
        let (store, ids) = storeWithV1([(1, 4)], sourceIns: [2])
        store.updateClip(ids[0], "Edit") { $0.volume = 1.5; $0.fadeIn = 0.5; $0.fadeOut = 1 }
        store.detachAudio(ids[0])
        XCTAssertTrue(store.clip(ids[0])!.audioMuted)
        let a = try XCTUnwrap(store.project.tracks[2].clips.first)
        XCTAssertEqual(a.mediaID, video.id)
        XCTAssertEqual(a.start, 1); XCTAssertEqual(a.duration, 4); XCTAssertEqual(a.sourceIn, 2)
        XCTAssertEqual(a.volume, 1.5); XCTAssertEqual(a.fadeIn, 0.5); XCTAssertEqual(a.fadeOut, 1)
        XCTAssertEqual(store.undoActionName, "Detach Audio")

        // Second detach is a no-op (already muted).
        let revision = store.revision
        store.detachAudio(ids[0])
        XCTAssertEqual(store.revision, revision)

        store.undo()
        XCTAssertFalse(store.clip(ids[0])!.audioMuted)
        XCTAssertTrue(store.project.tracks[2].clips.isEmpty)
    }

    func testDetachAudioUsesFreeOrNewAudioTrack() throws {
        let (store, ids) = storeWithV1([(0, 4)])
        store.addClip(mediaID: audio.id, at: 0)   // A1 busy
        store.addClip(mediaID: audio.id, at: 2)   // A2 busy
        store.detachAudio(ids[0])
        XCTAssertEqual(store.project.tracks.count, 5)
        XCTAssertEqual(store.project.tracks[4].kind, .audio)
        XCTAssertEqual(store.project.tracks[4].clips.first?.mediaID, video.id)
        // Silent video / images cannot detach.
        let silent = try XCTUnwrap(store.addClip(mediaID: silentVideo.id, at: 30))
        let revision = store.revision
        store.detachAudio(silent)
        XCTAssertEqual(store.revision, revision)
    }

    func testSetFadesOnSelection() {
        let (store, ids) = storeWithV1([(0, 2), (2, 4), (6, 1)])
        store.selection = [ids[0], ids[1]]
        store.setFades(in: 1.5, out: nil)
        XCTAssertEqual(store.clip(ids[0])!.fadeIn, 1.5); XCTAssertEqual(store.clip(ids[1])!.fadeIn, 1.5)
        XCTAssertEqual(store.clip(ids[2])!.fadeIn, 0)
        store.setFades(in: nil, out: 1.5)
        XCTAssertEqual(store.clip(ids[0])!.fadeIn + store.clip(ids[0])!.fadeOut, 2, accuracy: 1e-9)
        XCTAssertEqual(store.clip(ids[1])!.fadeOut, 1.5)
        XCTAssertEqual(store.clip(ids[1])!.fadeIn, 1.5)
        store.undo()
        XCTAssertEqual(store.clip(ids[1])!.fadeOut, 0)
    }

    // MARK: Tracks

    func testAddRemoveTracks() throws {
        let store = makeStore()
        let v = store.addTrack(.video)
        XCTAssertEqual(store.project.trackIndex(v), 2)
        let a = store.addTrack(.audio)
        XCTAssertEqual(store.project.trackIndex(a), store.project.tracks.count - 1)

        let clip = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: v, at: 0))
        XCTAssertEqual(store.selection, [clip])
        store.removeTrack(v)
        XCTAssertNil(store.project.trackIndex(v))
        XCTAssertNil(store.clip(clip))
        XCTAssertTrue(store.selection.isEmpty)

        store.removeTrack(store.project.videoTracks[0].id)
        XCTAssertEqual(store.project.videoTracks.count, 1)
        store.removeTrack(store.project.videoTracks[0].id)
        XCTAssertEqual(store.project.videoTracks.count, 1, "never remove the last video track")

        let locked = store.project.audioTracks[0].id
        store.setTrack(locked, locked: true)
        store.removeTrack(locked)
        XCTAssertNotNil(store.project.trackIndex(locked))
    }

    func testSetTrackFlagsAndUndoNames() {
        let store = makeStore()
        let id = store.project.tracks[0].id
        store.setTrack(id, muted: true)
        XCTAssertTrue(store.project.tracks[0].isMuted)
        XCTAssertEqual(store.undoActionName, "Mute Track")
        store.setTrack(id, hidden: true, locked: true)
        XCTAssertTrue(store.project.tracks[0].isHidden)
        XCTAssertTrue(store.project.tracks[0].isLocked)
        store.undo()
        XCTAssertFalse(store.project.tracks[0].isLocked)
        XCTAssertTrue(store.project.tracks[0].isMuted)
    }

    // MARK: Snapping

    func testSnapTargetsAndSnap() {
        let (store, ids) = storeWithV1([(1, 2), (5, 1)])
        store.playhead = 4
        XCTAssertEqual(store.snapTargets(), [0, 1, 3, 4, 5, 6])
        XCTAssertEqual(store.snapTargets(excluding: [ids[1]]), [0, 1, 3, 4])
        XCTAssertEqual(store.snap(3.08, thresholdSeconds: 0.1), 3)
        XCTAssertEqual(store.snap(3.5, thresholdSeconds: 0.1), 3.5)
        XCTAssertEqual(store.snap(5.95, excluding: [ids[1]], thresholdSeconds: 0.1), 5.95)
        XCTAssertEqual(store.snap(4.04, thresholdSeconds: 0.1), 4, "playhead")
        store.snappingEnabled = false
        XCTAssertEqual(store.snap(3.08, thresholdSeconds: 0.1), 3.08)
    }

    // MARK: Clipboard & nudge

    func testSelectAllSkipsLockedTracks() throws {
        let (store, ids) = storeWithV1([(0, 1), (1, 1)])
        let other = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: store.project.tracks[1].id, at: 0))
        store.setTrack(store.project.tracks[1].id, locked: true)
        store.selectAll()
        XCTAssertEqual(store.selection, Set(ids))
        XCTAssertFalse(store.selection.contains(other))
    }

    func testCopyPasteKeepsRelativeTimingAndTracks() throws {
        let store = makeStore()
        let v = try XCTUnwrap(store.addClip(mediaID: image.id, trackID: store.project.tracks[0].id, at: 1))
        let t = try XCTUnwrap(store.addTextClip(at: 2, trackID: store.project.tracks[1].id))
        let a = try XCTUnwrap(store.addClip(mediaID: audio.id, at: 1.5))
        XCTAssertFalse(store.canPaste)
        store.selection = [v, t, a]
        store.copySelection()
        XCTAssertTrue(store.canPaste)

        store.playhead = 20
        store.pasteAtPlayhead()
        XCTAssertEqual(store.selection.count, 3)
        XCTAssertTrue(store.selection.isDisjoint(with: [v, t, a]), "new ids")
        let pasted = store.selection.compactMap { id in store.project.locate(clip: id).map { (id, $0.track) } }
        let byTrack = Dictionary(uniqueKeysWithValues: pasted.map { ($0.1, store.clip($0.0)!) })
        XCTAssertEqual(byTrack[0]?.start ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(byTrack[1]?.start ?? -1, 21, accuracy: 1e-9)
        XCTAssertEqual(byTrack[2]?.start ?? -1, 20.5, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Paste")

        // Pasting again at the same spot keeps timing by moving to a free / new track.
        store.pasteAtPlayhead()
        XCTAssertEqual(store.selectedClips.map(\.start).sorted(), [20, 20.5, 21])
        assertInvariants(store.project)
    }

    func testCutPasteAndPasteSkipsRemovedMedia() throws {
        let (store, ids) = storeWithV1([(0, 2), (2, 2)])
        store.selection = [ids[0]]
        store.cutSelection()
        XCTAssertNil(store.clip(ids[0]))
        XCTAssertEqual(store.clip(ids[1])!.start, 2, "cut is not a ripple")
        XCTAssertEqual(store.undoActionName, "Cut")
        store.playhead = 0
        store.pasteAtPlayhead()
        XCTAssertEqual(store.project.tracks[0].clips.count, 2)
        XCTAssertEqual(store.project.tracks[0].clips[0].start, 0)

        store.removeMedia(video.id)
        let revision = store.revision
        store.pasteAtPlayhead()
        XCTAssertEqual(store.revision, revision)
    }

    func testPasteIntoLockedTrackFallsBack() throws {
        let (store, ids) = storeWithV1([(0, 2)])
        store.selection = [ids[0]]
        store.copySelection()
        store.setTrack(store.project.tracks[0].id, locked: true)
        store.playhead = 10
        store.pasteAtPlayhead()
        XCTAssertEqual(store.project.tracks[0].clips.count, 1)
        XCTAssertEqual(store.project.tracks[1].clips.count, 1)
    }

    func testNudgeClampedByZeroAndNeighbours() {
        let (store, ids) = storeWithV1([(0.5, 1), (2, 1), (3, 1), (5, 1)])
        let f = 1.0 / 30
        store.selection = [ids[1], ids[2]]
        store.nudgeSelection(frames: 3)
        XCTAssertEqual(store.clip(ids[1])!.start, 2 + 3 * f, accuracy: 1e-9)
        store.nudgeSelection(frames: 1000)
        XCTAssertEqual(store.clip(ids[2])!.end, 5, accuracy: 1e-9, "stopped by the next unselected clip")
        XCTAssertEqual(store.clip(ids[1])!.start, 3, accuracy: 1e-9)
        store.nudgeSelection(frames: -1000)
        XCTAssertEqual(store.clip(ids[1])!.start, 1.5, accuracy: 1e-9, "stopped by the previous clip")
        store.endCoalescing()

        store.selection = [ids[0]]
        store.nudgeSelection(frames: -100)
        XCTAssertEqual(store.clip(ids[0])!.start, 0, accuracy: 1e-9, "clamped at 0")
        let revision = store.revision
        store.nudgeSelection(frames: -1)
        XCTAssertEqual(store.revision, revision)

        store.setTrack(store.project.tracks[0].id, locked: true)
        store.nudgeSelection(frames: 5)
        XCTAssertEqual(store.clip(ids[0])!.start, 0, accuracy: 1e-9)
        assertInvariants(store.project)
    }

    func testRepeatedNudgesUndoTogether() {
        let (store, ids) = storeWithV1([(1, 1)])
        store.selection = [ids[0]]
        for _ in 0..<5 { store.nudgeSelection(frames: 1) }
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.start, 1, accuracy: 1e-9)
    }

    // MARK: Undo / dirty

    func testUndoRedoRestoresExactState() throws {
        let store = makeStore()
        let states = [store.project]
        let id = try XCTUnwrap(store.addClip(mediaID: video.id, at: 0))
        let s1 = store.project
        store.split(clipID: id, at: 3)
        let s2 = store.project
        store.selectAll()
        store.deleteSelection(ripple: true)
        store.undo(); XCTAssertEqual(store.project, s2)
        store.undo(); XCTAssertEqual(store.project, s1)
        store.undo(); XCTAssertEqual(store.project, states[0])
        store.redo(); store.redo()
        XCTAssertEqual(store.project, s2)
        store.addTextClip(at: 0)
        XCTAssertFalse(store.canRedo, "new edit clears redo")
    }

    func testDirtyTracking() throws {
        let store = makeStore()
        XCTAssertTrue(store.isDirty)
        store.newProject()
        XCTAssertFalse(store.isDirty)
        store.addMedia([image])
        XCTAssertTrue(store.isDirty)
        store.undo()
        XCTAssertFalse(store.isDirty, "back to the clean state")

        store.addMedia([image])
        let url = tempDir.appendingPathComponent("Dirty.editrush")
        try store.save(to: url)
        XCTAssertFalse(store.isDirty)
        store.addTextClip(at: 0)
        XCTAssertTrue(store.isDirty)
        store.undo()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.project.name, "Dirty", "undo never reverts the file name")
    }

    // MARK: Files

    func testSaveOpenRoundTrip() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addClip(mediaID: video.id, at: 1))
        store.addTextClip(at: 2)
        store.updateClip(id, "Look") { $0.filter = .noir; $0.color.contrast = 1.4; $0.transform.offsetX = 0.2 }
        let url = tempDir.appendingPathComponent("My Film.editrush")
        try store.save(to: url)
        XCTAssertEqual(store.projectURL, url)
        XCTAssertEqual(store.project.name, "My Film")
        XCTAssertFalse(store.isDirty)

        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\n  \""), "pretty printed")
        let canvasRange = try XCTUnwrap(json.range(of: "\"canvas\"")), mediaRange = try XCTUnwrap(json.range(of: "\"media\""))
        XCTAssertLessThan(canvasRange.lowerBound, mediaRange.lowerBound, "sorted keys")

        let other = EditorStore()
        other.statusMessage = nil
        try other.open(url)
        XCTAssertEqual(other.project, store.project)
        XCTAssertEqual(other.projectURL, url)
        XCTAssertFalse(other.isDirty)
        XCTAssertFalse(other.canUndo)
        XCTAssertEqual(other.statusMessage?.hasPrefix("Missing media"), true, "test media files don't exist")
    }

    func testOpenReportsNoMissingMediaWhenFilesExist() throws {
        let file = tempDir.appendingPathComponent("real.png")
        try Data([0]).write(to: file)
        var p = Project.empty()
        p.media = [MediaItem(url: file, name: "real.png", kind: .image, duration: 0)]
        let url = tempDir.appendingPathComponent("Real.editrush")
        try EditorStore(project: p).save(to: url)
        let store = EditorStore()
        try store.open(url)
        XCTAssertNil(store.statusMessage)
    }

    func testOpenRejectsNewerVersionAndGarbage() throws {
        var p = Project.empty()
        p.version = Project.currentVersion + 1
        let url = tempDir.appendingPathComponent("Future.editrush")
        try JSONEncoder().encode(p).write(to: url)
        let store = makeStore()
        let before = store.project
        XCTAssertThrowsError(try store.open(url)) { error in
            XCTAssertEqual(error as? ProjectFileError, .newerVersion(found: Project.currentVersion + 1, supported: Project.currentVersion))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertEqual(store.project, before)

        let junk = tempDir.appendingPathComponent("Junk.editrush")
        try Data("{\"version\": 1}".utf8).write(to: junk)
        XCTAssertThrowsError(try store.open(junk)) { error in
            guard case .unreadable = error as? ProjectFileError else { return XCTFail("\(error)") }
        }
        try Data("not json".utf8).write(to: junk)
        XCTAssertThrowsError(try store.open(junk))
    }

    func testAutosaveAndRestore() throws {
        let store = makeStore()
        store.autosaveFileURL = tempDir.appendingPathComponent("Nested/Autosave.editrush")
        store.addTextClip(at: 0)
        let saved = tempDir.appendingPathComponent("Proj.editrush")
        try store.save(to: saved)
        store.addTextClip(at: 10)
        store.autosave()
        EditorStore.flushPendingAutosaves()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.autosaveFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: EditorStore.autosaveStateURL(for: store.autosaveFileURL).path))

        let restored = EditorStore()
        restored.autosaveFileURL = store.autosaveFileURL
        XCTAssertTrue(restored.restoreAutosave())
        XCTAssertEqual(restored.project, store.project)
        XCTAssertEqual(restored.projectURL, saved)
        XCTAssertFalse(restored.isDirty)

        let missing = EditorStore()
        missing.autosaveFileURL = tempDir.appendingPathComponent("None/Autosave.editrush")
        XCTAssertFalse(missing.restoreAutosave())
    }

    func testAutosaveSkipsUnchangedAndReflectsLatestEdit() throws {
        let store = makeStore()
        store.autosaveFileURL = tempDir.appendingPathComponent("Autosave.editrush")
        store.autosave()
        EditorStore.flushPendingAutosaves()
        try FileManager.default.removeItem(at: store.autosaveFileURL)
        store.autosave()   // nothing changed → no write
        EditorStore.flushPendingAutosaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.autosaveFileURL.path))
        store.addTextClip(at: 3)
        store.autosave()
        let restored = EditorStore()
        restored.autosaveFileURL = store.autosaveFileURL
        XCTAssertTrue(restored.restoreAutosave(), "restore waits for the pending write")
        XCTAssertEqual(restored.project, store.project)
        XCTAssertNil(restored.projectURL)
    }

    // MARK: Group moves & duplicates

    /// V1: 10 s video at 0 with its audio detached onto A1 (0–10); A1 also holds music at 14–22.
    private func storeWithDetachedPairAndMusic() throws -> (EditorStore, video: UUID, audio: UUID, music: UUID) {
        let (store, ids) = storeWithV1([(0, 10)])
        store.detachAudio(ids[0])
        let a1 = store.project.tracks[2]
        let detached = try XCTUnwrap(a1.clips.first?.id)
        let music = try XCTUnwrap(store.addClip(mediaID: audio.id, trackID: a1.id, at: 14))
        XCTAssertEqual(store.clip(music)?.start, 14)
        return (store, ids[0], detached, music)
    }

    func testMoveClipsKeepsDetachedPairInSync() throws {
        let (store, v, a, music) = try storeWithDetachedPairAndMusic()
        let original = store.project
        let key = "drag-\(UUID())"
        // Live drag in small steps towards +6: the pair stops together against the music (+4).
        var applied: Seconds = 0
        for target in stride(from: 0.5, through: 6, by: 0.5) {
            store.moveClips([v, a], by: target - applied, coalesce: key)
            applied = try XCTUnwrap(store.clip(v)).start
            XCTAssertEqual(store.clip(a)?.start, store.clip(v)?.start, "target \(target)")
        }
        XCTAssertEqual(store.clip(v)!.start, 4, accuracy: 1e-9)
        // Dragging further jumps the whole group past the music, still in sync.
        store.moveClips([v, a], by: 20 - applied, coalesce: key)
        XCTAssertEqual(store.clip(v)!.start, 22, accuracy: 1e-9)
        XCTAssertEqual(store.clip(a)!.start, 22, accuracy: 1e-9)
        XCTAssertEqual(store.clip(music)?.start, 14, "unselected clips never move")
        XCTAssertEqual(store.project.locate(clip: a)?.track, 2)
        store.endCoalescing()
        assertInvariants(store.project)
        XCTAssertEqual(store.undoActionName, "Move Clips")
        store.undo()
        XCTAssertEqual(store.project, original, "the whole drag is one undo step")
    }

    func testMoveClipsBlockedByUnselectedNeighbourAndZero() {
        let (store, ids) = storeWithV1([(0, 5), (10, 5), (16, 4)])
        store.moveClips([ids[0], ids[1]], by: 3)
        XCTAssertEqual(store.clip(ids[0])!.start, 1, accuracy: 1e-9, "clamped by the unselected clip at 16")
        XCTAssertEqual(store.clip(ids[1])!.start, 11, accuracy: 1e-9)
        store.moveClips([ids[0], ids[1]], by: -5)
        XCTAssertEqual(store.clip(ids[0])!.start, 0, accuracy: 1e-9, "clamped at 0")
        XCTAssertEqual(store.clip(ids[1])!.start, 10, accuracy: 1e-9)
        // A requested shift past the obstacle uses the nearest spot where the whole group fits
        // (here the group straddles the unselected clip: [11, 16) · C [16, 20) · [21, 26)).
        store.moveClips([ids[0], ids[1]], by: 12)
        XCTAssertEqual(store.clip(ids[0])!.start, 11, accuracy: 1e-9)
        XCTAssertEqual(store.clip(ids[1])!.start, 21, accuracy: 1e-9)
        XCTAssertEqual(store.clip(ids[2])!.start, 16, accuracy: 1e-9)
        // Shifts are whole frames.
        store.moveClips([ids[0], ids[1]], by: -0.51 / 30)
        XCTAssertEqual(store.clip(ids[0])!.start, 11 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(store.clip(ids[1])!.start, 21 - 1.0 / 30, accuracy: 1e-9)
        assertInvariants(store.project)
    }

    func testMoveClipsLeavesLockedTracksAlone() throws {
        let (store, ids) = storeWithV1([(0, 2)])
        let v2 = store.project.tracks[1].id
        let other = try XCTUnwrap(store.addClip(mediaID: video.id, trackID: v2, at: 0))
        store.setTrack(v2, locked: true)
        store.moveClips([ids[0], other], by: 3)
        XCTAssertEqual(store.clip(ids[0])!.start, 3, accuracy: 1e-9)
        XCTAssertEqual(store.clip(other)!.start, 0, "clips on locked tracks stay put")
        // Moving onto the locked V2 is refused; the time shift still applies.
        store.moveClips([ids[0]], by: 1, trackOffset: 1)
        XCTAssertEqual(store.project.locate(clip: ids[0])?.track, 0)
        XCTAssertEqual(store.clip(ids[0])!.start, 4, accuracy: 1e-9)
        let revision = store.revision
        store.moveClips([other], by: 5)
        XCTAssertEqual(store.revision, revision)
    }

    func testMoveClipsTrackOffset() throws {
        let (store, v, a, _) = try storeWithDetachedPairAndMusic()
        // Both kinds move one track up their own order: V1 → V2, A1 → A2.
        store.moveClips([v, a], by: 0, trackOffset: 1)
        XCTAssertEqual(store.project.locate(clip: v)?.track, 1)
        XCTAssertEqual(store.project.locate(clip: a)?.track, 3)
        XCTAssertEqual(store.clip(v)?.start, 0)
        XCTAssertEqual(store.clip(a)?.start, 0)
        // No V3 / A3: the offset is refused as a whole, the time shift still applies.
        store.moveClips([v, a], by: 2, trackOffset: 1)
        XCTAssertEqual(store.project.locate(clip: v)?.track, 1)
        XCTAssertEqual(store.project.locate(clip: a)?.track, 3)
        XCTAssertEqual(store.clip(v)!.start, 2, accuracy: 1e-9)
        XCTAssertEqual(store.clip(a)!.start, 2, accuracy: 1e-9)
        // Back down onto A1 and +3 s, where the music limits the shared shift to +2 (start 4).
        store.moveClips([v, a], by: 3, trackOffset: -1)
        XCTAssertEqual(store.project.locate(clip: v)?.track, 0)
        XCTAssertEqual(store.project.locate(clip: a)?.track, 2)
        XCTAssertEqual(store.clip(v)!.start, 4, accuracy: 1e-9)
        XCTAssertEqual(store.clip(a)!.start, 4, accuracy: 1e-9)
        assertInvariants(store.project)
    }

    func testDuplicateKeepsGroupTiming() throws {
        let (store, v, a, music) = try storeWithDetachedPairAndMusic()
        store.selection = [v, a]
        store.duplicateSelection()
        let copies = store.selectedClips
        XCTAssertEqual(copies.count, 2)
        XCTAssertFalse(store.selection.contains(v) || store.selection.contains(a) || store.selection.contains(music))
        XCTAssertEqual(copies.map(\.start), [22, 22], "one shared offset, past the music on A1")
        XCTAssertEqual(Set(copies.compactMap { store.project.locate(clip: $0.id)?.track }), [0, 2])
        assertInvariants(store.project)
        store.undo()
        XCTAssertEqual(store.project.tracks.flatMap(\.clips).count, 3)
    }

    func testDuplicateSkipsLockedTracks() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.selection = [ids[0]]
        store.setTrack(store.project.tracks[0].id, locked: true)
        let revision = store.revision
        store.duplicateSelection()
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.selection, [ids[0]])
    }

    // MARK: Coalescing

    func testCoalescedGestureSurvivesPause() {
        let (store, ids) = storeWithV1([(0, 2)])
        let v1 = store.project.tracks[0].id
        let key = "timeline-move-\(UUID())"
        store.moveClip(ids[0], toTrack: v1, start: 2, coalesce: key)
        Thread.sleep(forTimeInterval: 1.6)   // mouse held still
        store.moveClip(ids[0], toTrack: v1, start: 3, coalesce: key)
        store.endCoalescing()
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.start, 0, accuracy: 1e-9)
        XCTAssertFalse(store.canUndo)
    }

    func testCoalescingEndsOnOtherKeyOrPlainMutate() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.updateClip(ids[0], "Opacity", coalesce: "a") { $0.transform.opacity = 0.5 }
        store.updateClip(ids[0], "Opacity", coalesce: "b") { $0.transform.opacity = 0.4 }
        store.updateClip(ids[0], "Opacity", coalesce: "b") { $0.transform.opacity = 0.3 }
        store.updateClip(ids[0], "Scale") { $0.transform.scale = 2 }
        store.updateClip(ids[0], "Opacity", coalesce: "b") { $0.transform.opacity = 0.2 }
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.opacity, 0.3, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.scale, 1, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.opacity, 0.5, accuracy: 1e-9)
        store.undo()
        XCTAssertFalse(store.canUndo)
    }

    func testCoalesceTimeoutIsOptIn() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.updateClip(ids[0], "Color", coalesce: "color", coalesceTimeout: 0.05) { $0.transform.opacity = 0.5 }
        store.updateClip(ids[0], "Color", coalesce: "color", coalesceTimeout: 0.05) { $0.transform.opacity = 0.4 }
        Thread.sleep(forTimeInterval: 0.1)
        store.updateClip(ids[0], "Color", coalesce: "color", coalesceTimeout: 0.05) { $0.transform.opacity = 0.3 }
        store.undo()
        XCTAssertEqual(store.clip(ids[0])!.transform.opacity, 0.4, accuracy: 1e-9)
        store.undo()
        XCTAssertFalse(store.canUndo)
    }

    func testAddClipsCoalesceIntoOneUndoStep() throws {
        let store = makeStore()
        let before = store.project
        let key = "drop-\(UUID())"
        var t: Seconds = 0
        for id in [video.id, image.id, silentVideo.id] {
            let clip = try XCTUnwrap(store.addClip(mediaID: id, at: t, coalesce: key))
            t = store.clip(clip)!.end
        }
        store.endCoalescing()
        XCTAssertEqual(store.project.tracks[0].clips.map(\.start), [0, 10, 15])
        store.undo()
        XCTAssertEqual(store.project, before)
        // Without a key every add is its own step.
        store.addClip(mediaID: video.id, at: 0)
        store.addClip(mediaID: image.id, at: 10)
        store.undo()
        XCTAssertEqual(store.project.tracks[0].clips.count, 1)
    }

    func testDetachAudioCoalescesIntoOneUndoStep() {
        let (store, ids) = storeWithV1([(0, 2), (4, 2), (8, 2)])
        let before = store.project
        let key = "detach-\(UUID())"
        for id in ids { store.detachAudio(id, coalesce: key) }
        store.endCoalescing()
        XCTAssertEqual(store.project.tracks[2].clips.count, 3)
        XCTAssertTrue(ids.allSatisfy { store.clip($0)!.audioMuted })
        store.undo()
        XCTAssertEqual(store.project, before)
        XCTAssertFalse(store.canUndo)
    }

    func testUndoLimit() {
        XCTAssertEqual(EditorStore.undoLimit, 1000)
        let (store, ids) = storeWithV1([(0, 2)])
        for i in 0..<(EditorStore.undoLimit + 5) {
            store.updateClip(ids[0], "Opacity") { $0.transform.opacity = i.isMultiple(of: 2) ? 0.5 : 0.25 }
        }
        var undos = 0
        while store.canUndo { store.undo(); undos += 1 }
        XCTAssertEqual(undos, EditorStore.undoLimit)
    }

    // MARK: Hidden tracks

    func testAutomaticPlacementSkipsHiddenTracks() throws {
        let store = makeStore()
        let v1 = store.project.tracks[0].id, v2 = store.project.tracks[1].id, a1 = store.project.tracks[2].id
        store.setTrack(v2, hidden: true)
        let title = try XCTUnwrap(store.addTextClip(at: 0))
        XCTAssertEqual(store.project.track(containing: title)?.id, v1, "topmost visible video track")
        let second = try XCTUnwrap(store.addTextClip(at: 0))
        XCTAssertEqual(store.project.tracks.count, 5, "V1 busy, V2 hidden: a new video track")
        XCTAssertEqual(store.project.locate(clip: second)?.track, 2)
        XCTAssertFalse(store.project.tracks[2].isHidden)

        store.setTrack(a1, hidden: true)
        let music = try XCTUnwrap(store.addClip(mediaID: audio.id, at: 0))
        XCTAssertEqual(store.project.track(containing: music)?.kind, .audio)
        XCTAssertNotEqual(store.project.track(containing: music)?.id, a1)

        // An explicit hidden target is respected.
        let explicit = try XCTUnwrap(store.addClip(mediaID: video.id, trackID: v2, at: 0))
        XCTAssertEqual(store.project.track(containing: explicit)?.id, v2)
        assertInvariants(store.project)
    }

    func testDetachAudioSkipsHiddenAudioTrack() {
        let (store, ids) = storeWithV1([(0, 2)])
        store.setTrack(store.project.tracks[2].id, hidden: true)
        store.detachAudio(ids[0])
        XCTAssertTrue(store.project.tracks[2].clips.isEmpty)
        XCTAssertEqual(store.project.tracks[3].clips.count, 1)
    }

    // MARK: Speed

    func testSetSpeedKeepsSourceRangeAndRipplesLaterClips() throws {
        let (store, ids) = storeWithV1([(0, 4), (5, 2)], sourceIns: [1, 0])
        store.setSpeed(2, for: [ids[0]])
        var c = try XCTUnwrap(store.clip(ids[0]))
        XCTAssertEqual(c.speed, 2)
        XCTAssertEqual(c.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(c.sourceIn, 1); XCTAssertEqual(c.sourceOut, 5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[1])).start, 3, accuracy: 1e-9, "later clip keeps its 1 s gap")

        store.setSpeed(0.5, for: [ids[0]])
        c = try XCTUnwrap(store.clip(ids[0]))
        XCTAssertEqual(c.duration, 8, accuracy: 1e-9)
        XCTAssertEqual(c.sourceOut, 5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[1])).start, 9, accuracy: 1e-9)
        assertInvariants(store.project)

        store.undo()
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[0])).duration, 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[1])).start, 3, accuracy: 1e-9)
    }

    func testSetSpeedClampsAndSkipsImagesTextAndLockedTracks() throws {
        let store = makeStore()
        let img = try XCTUnwrap(store.addClip(mediaID: image.id, at: 0))
        let title = try XCTUnwrap(store.addTextClip(at: 20))
        let vid = try XCTUnwrap(store.addClip(mediaID: video.id, at: 40))
        store.setSpeed(50, for: [img, title, vid])
        XCTAssertEqual(store.clip(img)?.speed, 1); XCTAssertEqual(store.clip(img)?.duration, 5)
        XCTAssertEqual(store.clip(title)?.speed, 1)
        XCTAssertEqual(store.clip(vid)?.speed, Clip.speedRange.upperBound)
        XCTAssertEqual(try XCTUnwrap(store.clip(vid)).duration, 1, accuracy: 1e-9, "10 s of source at 10×")

        store.updateClip(img, "Speed") { $0.speed = 3 }
        XCTAssertEqual(store.clip(img)?.speed, 1, "images have no speed")
        store.updateClip(vid, "Speed") { $0.speed = 0.01 }
        XCTAssertEqual(store.clip(vid)?.speed, Clip.speedRange.lowerBound)

        let track = try XCTUnwrap(store.project.track(containing: vid))
        store.setTrack(track.id, locked: true)
        store.setSpeed(1, for: [vid])
        XCTAssertEqual(store.clip(vid)?.speed, Clip.speedRange.lowerBound)
        assertInvariants(store.project)
    }

    func testSpeedDragIsOneUndoStepAndDoesNotDrift() throws {
        let (store, ids) = storeWithV1([(0, 10), (10, 2)])
        for speed in [0.37, 1.53, 0.71, 2.9, 0.13, 1] { store.setSpeed(speed, for: [ids[0]], coalesce: "drag") }
        store.endCoalescing()
        let c = try XCTUnwrap(store.clip(ids[0]))
        XCTAssertEqual(c.duration, 10, accuracy: 1e-9, "back at 100 %, the clip is its original length")
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[1])).start, 10, accuracy: 1e-9)
        store.undo()
        XCTAssertFalse(store.canUndo, "the whole drag is one undo step")

        for speed in [0.5, 0.25] { store.setSpeed(speed, for: [ids[0]], coalesce: "drag2") }
        store.endCoalescing()
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[0])).duration, 40, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[0])).speed, 1)
    }

    func testSplitTrimAndJoinAtSpeed() throws {
        let (store, ids) = storeWithV1([(2, 4)], sourceIns: [1])
        store.setSpeed(2, for: [ids[0]])
        // Clip [2, 4) plays source 1…5.
        let right = try XCTUnwrap(store.split(clipID: ids[0], at: 3))
        XCTAssertEqual(try XCTUnwrap(store.clip(right)).sourceIn, 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.clip(right)).sourceOut, 5, accuracy: 1e-9)
        store.selection = [ids[0], right]
        XCTAssertTrue(store.canJoinSelection)
        store.joinSelection()
        XCTAssertEqual(try XCTUnwrap(store.clip(ids[0])).duration, 2, accuracy: 1e-9)

        // Leading edge: 1 s of source before sourceIn is 0.5 s of timeline at 2×.
        store.trimClip(ids[0], edge: .leading, to: 0)
        var c = try XCTUnwrap(store.clip(ids[0]))
        XCTAssertEqual(c.start, 1.5, accuracy: 1e-9); XCTAssertEqual(c.sourceIn, 0, accuracy: 1e-9)
        // Trailing edge: the 10 s source runs out at 1.5 + 10 / 2.
        store.trimClip(ids[0], edge: .trailing, to: 50)
        c = try XCTUnwrap(store.clip(ids[0]))
        XCTAssertEqual(c.end, 6.5, accuracy: 1e-9); XCTAssertEqual(c.sourceOut, 10, accuracy: 1e-9)
        assertInvariants(store.project)

        // Different speeds don't join.
        let (s2, ids2) = storeWithV1([(0, 2), (2, 2)], sourceIns: [0, 2])
        s2.updateClip(ids2[1], "Speed") { $0.speed = 1.5 }
        s2.selection = Set(ids2)
        XCTAssertFalse(s2.canJoinSelection)
    }

    func testDetachAudioKeepsSpeed() throws {
        let (store, ids) = storeWithV1([(0, 4)])
        store.setSpeed(0.5, for: [ids[0]])
        store.detachAudio(ids[0])
        let audio = try XCTUnwrap(store.project.audioTracks.first?.clips.first)
        XCTAssertEqual(audio.speed, 0.5)
        XCTAssertEqual(audio.duration, 8, accuracy: 1e-9)
    }

    // MARK: Invariants under a random edit sequence

    func testRandomEditSequenceKeepsInvariants() {
        for seed: UInt64 in [0xED17_2025, 1, 2, 3, 42, 31_337] {
            runRandomEdits(seed: seed, steps: 500)
        }
    }

    private func runRandomEdits(seed: UInt64, steps: Int) {
        var rng = SeededGenerator(seed: seed)
        let store = makeStore()
        let mediaIDs = [video.id, silentVideo.id, audio.id, image.id]
        func randomSelection(_ clips: [Clip]) -> Set<UUID> { Set(clips.filter { _ in Bool.random(using: &rng) }.map(\.id)) }
        for step in 0..<steps {
            let clips = store.project.tracks.flatMap(\.clips)
            let any = clips.randomElement(using: &rng)
            let canGrow = clips.count < 80
            switch Int.random(in: 0..<21, using: &rng) {
            case 20:
                store.setSpeed(pow(10, .random(in: -1.2...1.2, using: &rng)), for: randomSelection(clips),
                               coalesce: Bool.random(using: &rng) ? "speed" : nil)
            case 18:
                store.moveClips(randomSelection(clips), by: .random(in: -20...20, using: &rng),
                                trackOffset: .random(in: -2...2, using: &rng))
            case 19: if let track = store.project.tracks.randomElement(using: &rng) { store.setTrack(track.id, hidden: Bool.random(using: &rng)) }
            case 0, 1: store.addClip(mediaID: mediaIDs.randomElement(using: &rng)!, at: .random(in: 0...30, using: &rng))
            case 2: store.addTextClip(at: .random(in: 0...30, using: &rng))
            case 3: if let any { store.split(clipID: any.id, at: .random(in: any.start...any.end, using: &rng)) }
            case 4:
                if let any, let track = store.project.tracks.randomElement(using: &rng) {
                    store.moveClip(any.id, toTrack: track.id, start: .random(in: 0...40, using: &rng))
                }
            case 5: if let any { store.trimClip(any.id, edge: Bool.random(using: &rng) ? .leading : .trailing, to: .random(in: 0...40, using: &rng)) }
            case 6: store.selection = randomSelection(clips); store.deleteSelection(ripple: Bool.random(using: &rng))
            case 7 where canGrow: store.selection = randomSelection(clips); store.duplicateSelection()
            case 8: store.selection = randomSelection(clips); store.nudgeSelection(frames: .random(in: -40...40, using: &rng))
            case 9 where canGrow: store.copySelection(); store.playhead = .random(in: 0...30, using: &rng); store.pasteAtPlayhead()
            case 10: store.selection = randomSelection(clips); store.closeGaps()
            case 11: if Bool.random(using: &rng) { store.undo() } else { store.redo() }
            case 12: store.playhead = .random(in: 0...30, using: &rng); store.selection = randomSelection(clips); store.splitAtPlayhead()
            case 13: store.selection = randomSelection(clips); store.joinSelection()
            case 14: if let any { store.detachAudio(any.id) }
            case 15:
                if let any {
                    store.updateClip(any.id, "Random") { c in
                        c.duration = .random(in: -1...20, using: &rng)
                        c.start = .random(in: -5...30, using: &rng)
                        c.fadeIn = .random(in: -1...10, using: &rng)
                    }
                }
            case 16: if let track = store.project.tracks.randomElement(using: &rng) { store.setTrack(track.id, locked: Bool.random(using: &rng)) }
            default: store.selection = randomSelection(clips); store.setFades(in: .random(in: 0...5, using: &rng), out: .random(in: 0...5, using: &rng))
            }
            assertInvariants(store.project, context: "seed \(seed) step \(step)")
        }
    }
}

/// Deterministic SplitMix64 so the randomized test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
