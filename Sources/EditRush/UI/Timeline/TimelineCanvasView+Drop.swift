import AppKit
import UniformTypeIdentifiers
import EditRushCore

/// Where a drag from the media bin / Finder would land (drawn as a ghost while dragging).
struct TimelineDropPreview: Equatable {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .string,
        NSPasteboard.PasteboardType(UTType.plainText.identifier),
        NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
    ]

    struct Segment: Equatable {
        let title: String
        let duration: Seconds
    }

    let start: Seconds
    let segments: [Segment]
    let trackKind: TrackKind
    /// Row the first item lands on; nil = a new track will be created.
    let trackID: UUID?
    /// True when the pointer is directly over a compatible row (the drop targets that track);
    /// false when the store picks the track (`trackID` is then only a prediction).
    let isExplicitTrack: Bool

    var duration: Seconds { segments.reduce(0) { $0 + $1.duration } }
}

/// Media being dragged onto the timeline.
enum TimelineDropSource {
    case media([MediaItem])
    case files([URL])
}

extension TimelineCanvasView {
    /// Placeholder length for items whose duration is unknown until imported, and images.
    static let defaultDropDuration: Seconds = 5

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropPreview(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropPreview(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropSource(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard let source = dropSource(from: sender), let preview = dropPreview ?? makeDropPreview(source, at: p) else {
            setDropPreview(nil)
            return false
        }
        setDropPreview(nil)
        switch source {
        case .media(let items):
            place(items, preview: preview)
        case .files(let urls):
            let store = self.store
            let key = "drop-\(UUID())"
            Task { @MainActor [weak self] in
                let items = await ImportActions.importURLs(urls, store: store, coalesce: key)
                if let self { self.place(items, preview: preview, coalesce: key) } else { store.endCoalescing() }
            }
        }
        return true
    }

    private func updateDropPreview(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        guard let source = dropSource(from: sender), p.y >= rulerHeight else {
            setDropPreview(nil)
            return []
        }
        setDropPreview(makeDropPreview(source, at: p))
        return .copy
    }

    private func setDropPreview(_ preview: TimelineDropPreview?) {
        guard preview != dropPreview else { return }
        dropPreview = preview
        needsDisplay = true
    }

    /// Reads media payloads ("editrush-media:<UUID>") or supported file URLs from the pasteboard.
    func dropSource(from info: NSDraggingInfo) -> TimelineDropSource? {
        if let cached = cachedDropSource, cached.sequence == info.draggingSequenceNumber { return cached.source }
        let source = readDropSource(info.draggingPasteboard)
        cachedDropSource = (info.draggingSequenceNumber, source)
        return source
    }

    private func readDropSource(_ pb: NSPasteboard) -> TimelineDropSource? {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { url in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return true }
            return MediaImporter.supportedExtensions.contains(url.pathExtension.lowercased())
        }
        if !files.isEmpty { return .files(files) }

        var strings = (pb.readObjects(forClasses: [NSString.self]) as? [String]) ?? []
        if strings.isEmpty, let s = pb.string(forType: .string) { strings = [s] }
        let ids = strings
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { MediaDragPayload.mediaID(from: $0.trimmingCharacters(in: .whitespaces)) }
        let items = ids.compactMap { mediaIndex[$0] }
        return items.isEmpty ? nil : .media(items)
    }

    func makeDropPreview(_ source: TimelineDropSource, at p: CGPoint) -> TimelineDropPreview? {
        let entries: [(kind: MediaKind, segment: TimelineDropPreview.Segment)]
        switch source {
        case .media(let items):
            entries = items.map { ($0.kind, .init(title: $0.name, duration: $0.kind == .image ? Self.defaultDropDuration : max($0.duration, store.frameDuration))) }
        case .files(let urls):
            entries = urls.map { url in
                let ext = url.pathExtension.lowercased()
                let kind: MediaKind = MediaImporter.audioExtensions.contains(ext) ? .audio
                    : MediaImporter.imageExtensions.contains(ext) ? .image : .video
                return (kind, .init(title: url.deletingPathExtension().lastPathComponent, duration: Self.defaultDropDuration))
            }
        }
        guard let first = entries.first else { return nil }
        let trackKind: TrackKind = first.kind == .audio ? .audio : .video
        let threshold = Seconds(TimelineMetrics.snapDistance / pps)
        let start = store.project.canvas.quantize(store.snap(time(atX: p.x), thresholdSeconds: threshold))

        if let row = row(atViewY: p.y), let track = track(row.trackID), !track.isLocked, track.accepts(first.kind) {
            return TimelineDropPreview(start: start, segments: entries.map(\.segment), trackKind: trackKind,
                                       trackID: track.id, isExplicitTrack: true)
        }
        // Predict the store's choice: the lowest compatible visible, unlocked track that is free there.
        let duration = first.segment.duration
        let predicted = store.project.tracks.first { track in
            track.kind == trackKind && track.allowsAutomaticPlacement && track.isFree(start: start, duration: duration)
        }
        return TimelineDropPreview(start: start, segments: entries.map(\.segment), trackKind: trackKind,
                                   trackID: predicted?.id, isExplicitTrack: false)
    }

    /// Adds `items` one after another starting at the preview position (one undo step) and selects them.
    private func place(_ items: [MediaItem], preview: TimelineDropPreview, coalesce key: String = "drop-\(UUID())") {
        var t = preview.start
        var added: [UUID] = []
        for item in items {
            let explicit = preview.isExplicitTrack ? preview.trackID.flatMap { id in
                track(id)?.accepts(item.kind) == true ? id : nil
            } : nil
            let id = store.addClip(mediaID: item.id, trackID: explicit, at: t, coalesce: key)
            if let id { added.append(id) }
            let fallback = item.kind == .image ? Self.defaultDropDuration : item.duration
            t = id.flatMap { store.clip($0)?.end } ?? (t + fallback)
        }
        store.endCoalescing()
        if added.count > 1 { store.selection = Set(added) }
    }
}
