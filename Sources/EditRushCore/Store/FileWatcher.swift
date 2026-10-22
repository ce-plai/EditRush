import Foundation

/// Calls `onChange` on the main queue, debounced, after the file at `url` is written in place,
/// replaced (atomic save), deleted or recreated. Other changes in the file's folder also trigger it,
/// so `onChange` should check whether the content actually changed.
///
/// All work happens on the main queue. Watching stops when the watcher is released.
public final class FileWatcher: @unchecked Sendable {
    public let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var folderSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(url: URL, debounce: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        folderSource = source(url.deletingLastPathComponent().path, [.write])
        watchFile()
    }

    deinit {
        pending?.cancel()
        fileSource?.cancel()
        folderSource?.cancel()
    }

    /// (Re)opens the file: an atomic save replaces it with a new file the old source can't see.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = source(url.path, [.write, .extend, .delete, .rename])
    }

    private func source(_ path: String, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            watchFile()
            onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
