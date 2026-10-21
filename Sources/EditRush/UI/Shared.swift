import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditRushCore

/// Drag payload for media dragged from the media bin. Encoded as plain text so it works with
/// `.draggable(String)` / `.dropDestination(for: String.self)` / `NSItemProvider` text.
enum MediaDragPayload {
    static let prefix = "editrush-media:"
    static func string(for id: UUID) -> String { prefix + id.uuidString }
    static func mediaID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

/// Shared import flow used by the media bin, menus, and Finder drops on any panel.
@MainActor
enum ImportActions {
    /// Probes `urls` (folders are expanded one level), adds new media to the project bin, reports
    /// failures in `store.statusMessage`, and returns the project's MediaItems for those URLs in
    /// input order (already-imported files return their existing item).
    /// - coalesce: undo key shared with the edits that follow (e.g. placing the dropped clips),
    ///   so the import and those edits undo as one step.
    @discardableResult
    static func importURLs(_ urls: [URL], store: EditorStore, coalesce: String? = nil) async -> [MediaItem] {
        let files = await Task.detached(priority: .userInitiated) { MediaImporter.expandFolders(urls) }.value
        let known = Set(store.project.media.map { $0.url.standardizedFileURL })
        let fresh = files.filter { !known.contains($0.standardizedFileURL) }
        let (items, failures) = await MediaImporter.importFiles(fresh)
        if !items.isEmpty {
            if let coalesce {
                store.mutate("Import Media", coalesce: coalesce) { p in
                    var present = Set(p.media.map { $0.url.standardizedFileURL })
                    p.media += items.filter { present.insert($0.url.standardizedFileURL).inserted }
                }
            } else {
                store.addMedia(items)
            }
        }
        if !failures.isEmpty {
            store.statusMessage = "Couldn't import " + failures.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: ", ")
        }
        let byURL = Dictionary(store.project.media.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { byURL[$0.standardizedFileURL] }
    }

    /// Shows an NSOpenPanel for media and imports the choice.
    @discardableResult
    static func presentImportPanel(store: EditorStore) async -> [MediaItem] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaImporter.supportedContentTypes
        panel.message = "Choose video, audio or image files"
        guard panel.runModal() == .OK else { return [] }
        return await importURLs(panel.urls, store: store)
    }
}
