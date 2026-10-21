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
    @discardableResult
    static func importURLs(_ urls: [URL], store: EditorStore) async -> [MediaItem] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += children.filter { MediaImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(url)
            }
        }
        let known = Set(store.project.media.map { $0.url.standardizedFileURL })
        let fresh = files.filter { !known.contains($0.standardizedFileURL) }
        let (items, failures) = await MediaImporter.importFiles(fresh)
        if !items.isEmpty { store.addMedia(items) }
        if !failures.isEmpty {
            store.statusMessage = "Couldn't import " + failures.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: ", ")
        }
        return files.compactMap { f in store.project.media.first { $0.url.standardizedFileURL == f.standardizedFileURL } }
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
