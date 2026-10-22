import XCTest
@testable import EditRushCore

/// Project files changed by another app (e.g. an agent) while the editor has them open.
@MainActor
final class OutsideChangeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditRushOutsideChangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Two video tracks; V1 holds titles "A" (0–2 s) and "B" (3–5 s).
    private func baseProject() -> Project {
        var p = Project.empty()
        p.tracks[0].clips = [Clip(mediaID: nil, start: 0, duration: 2, text: TextStyle(text: "A")),
                             Clip(mediaID: nil, start: 3, duration: 2, text: TextStyle(text: "B"))]
        return p
    }

    private func edit(_ p: Project, _ body: (inout Project) -> Void) -> Project {
        var p = p
        body(&p)
        return p
    }

    private func writeOutside(_ p: Project, to url: URL) throws {
        try JSONEncoder().encode(p).write(to: url, options: .atomic)
    }

    // MARK: - Merge

    func testMergeKeepsEditsFromBothSides() {
        let base = baseProject()
        let ours = edit(base) { $0.tracks[0].clips[0].volume = 0.5 }
        let title = Clip(mediaID: nil, start: 1, duration: 1, text: TextStyle(text: "New"))
        let theirs = edit(base) {
            $0.tracks[0].clips[1].fadeIn = 0.5
            $0.tracks[1].clips.append(title)
            $0.canvas.backgroundColor = .white
        }
        let outcome = ProjectMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(outcome.conflicts, 0)
        XCTAssertFalse(outcome.droppedOurs)
        let p = outcome.project
        XCTAssertEqual(p.tracks[0].clips[0].volume, 0.5)
        XCTAssertEqual(p.tracks[0].clips[1].fadeIn, 0.5)
        XCTAssertEqual(p.tracks[1].clips, [title])
        XCTAssertEqual(p.canvas.backgroundColor, .white)
    }

    func testMergeConflictKeepsOurs() {
        let base = baseProject()
        let ours = edit(base) { $0.tracks[0].clips[0].text?.text = "Ours" }
        let theirs = edit(base) { $0.tracks[0].clips[0].text?.text = "Theirs" }
        let outcome = ProjectMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(outcome.conflicts, 1)
        XCTAssertEqual(outcome.project.tracks[0].clips[0].text?.text, "Ours")
    }

    func testMergeDeletionsAndMovesBetweenTracks() {
        let base = baseProject()
        let ours = edit(base) {   // move B up to V2
            let b = $0.tracks[0].clips.removeLast()
            $0.tracks[1].clips.append(b)
        }
        let theirs = edit(base) { $0.tracks[0].clips.removeFirst() }   // delete A
        let outcome = ProjectMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(outcome.conflicts, 0)
        XCTAssertEqual(outcome.project.tracks[0].clips, [])
        XCTAssertEqual(outcome.project.tracks[1].clips.map(\.text?.text), ["B"])
    }

    func testMergeThatBreaksTheTimelineFallsBackToTheirs() {
        let base = baseProject()
        let ours = edit(base) { $0.tracks[1].clips.append(Clip(mediaID: nil, start: 0, duration: 4, text: TextStyle(text: "Ours"))) }
        let theirs = edit(base) { $0.tracks[1].clips.append(Clip(mediaID: nil, start: 1, duration: 4, text: TextStyle(text: "Theirs"))) }
        let outcome = ProjectMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(outcome.droppedOurs)
        XCTAssertEqual(outcome.project, theirs)
    }

    // MARK: - Store

    func testOutsideChangeLoadsAsOneUndoableStep() throws {
        let url = tempDir.appendingPathComponent("Edit.editrush")
        let store = EditorStore(project: baseProject())
        try store.save(to: url)
        let saved = store.project

        try writeOutside(edit(saved) { $0.tracks[0].clips[0].text?.text = "Agent" }, to: url)
        XCTAssertTrue(store.syncWithFile())
        XCTAssertEqual(store.project.tracks[0].clips[0].text?.text, "Agent")
        XCTAssertFalse(store.isDirty, "the file already holds it")
        XCTAssertEqual(store.undoActionName, "Outside Change")
        XCTAssertEqual(store.statusMessage?.hasPrefix("Loaded changes"), true)

        store.undo()
        XCTAssertEqual(store.project, saved)
        XCTAssertTrue(store.isDirty, "undoing it must be written back to the file")
    }

    func testOutsideChangeMergesWithUnsavedEdits() throws {
        let url = tempDir.appendingPathComponent("Edit.editrush")
        let store = EditorStore(project: baseProject())
        try store.save(to: url)
        let saved = store.project
        let a = saved.tracks[0].clips[0].id
        store.mutate("Volume") { $0.tracks[0].clips[0].volume = 0.25 }

        try writeOutside(edit(saved) { $0.tracks[0].clips[1].text?.text = "Agent" }, to: url)
        XCTAssertTrue(store.syncWithFile())
        XCTAssertEqual(store.project.clip(a)?.volume, 0.25)
        XCTAssertEqual(store.project.tracks[0].clips[1].text?.text, "Agent")
        XCTAssertTrue(store.isDirty, "our edit still has to be written")
    }

    func testOwnSaveIsNotAnOutsideChange() throws {
        let url = tempDir.appendingPathComponent("Edit.editrush")
        let store = EditorStore(project: baseProject())
        try store.save(to: url)
        store.statusMessage = nil
        XCTAssertTrue(store.syncWithFile())
        XCTAssertFalse(store.canUndo)
        XCTAssertNil(store.statusMessage)
    }

    func testUnusableFileIsNotLoadedOrOverwritten() throws {
        let url = tempDir.appendingPathComponent("Edit.editrush")
        let store = EditorStore(project: baseProject())
        try store.save(to: url)
        let saved = store.project

        try Data("{\"tracks\": [".utf8).write(to: url)   // half-written
        XCTAssertFalse(store.syncWithFile())
        XCTAssertEqual(store.project, saved)
        XCTAssertEqual(store.statusMessage?.contains("can't be loaded"), true)

        try writeOutside(edit(saved) { $0.tracks[0].clips[1].start = 1 }, to: url)   // overlaps A
        XCTAssertFalse(store.syncWithFile())
        XCTAssertEqual(store.project, saved)
        XCTAssertEqual(store.statusMessage?.contains("overlaps"), true)
    }

    // MARK: - Watcher

    func testWatcherSeesAtomicAndInPlaceWrites() throws {
        let url = tempDir.appendingPathComponent("Watched.editrush")
        try Data("1".utf8).write(to: url)
        var fired = 0
        var expectation = self.expectation(description: "atomic write")
        let watcher = FileWatcher(url: url, debounce: 0.05) {
            fired += 1
            expectation.fulfill()
        }
        try Data("2".utf8).write(to: url, options: .atomic)
        wait(for: [expectation], timeout: 2)

        expectation = self.expectation(description: "in-place write after the file was replaced")
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("3".utf8))
        try handle.close()
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(fired, 2)
        withExtendedLifetime(watcher) {}
    }
}
