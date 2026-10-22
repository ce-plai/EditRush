import AppKit
import AVFoundation
import UniformTypeIdentifiers
import EditRushCore

/// Command-line modes for scripts and agents. Run the binary inside the app bundle
/// (`EditRush.app/Contents/MacOS/EditRush`); the project format is described in docs/project-format.md.
///
///   EditRush --validate project.editrush
///   EditRush --probe media.mov [more files…]
///   EditRush --frame out.png --project project.editrush [--at 12.5] [--max-size 1280x720]
///   EditRush --export out.mp4 --project project.editrush [--resolution 720p|1080p|4k|project] [--codec h264|hevc]
///
/// Results go to stdout, issues and progress to stderr. Exit status is 0 on success, 1 on failure.
/// `--frame` and `--export` refuse projects with validation errors and print warnings.
@MainActor
enum CommandLineTool {
    static let modes = ["--validate", "--probe", "--frame", "--export", "--help"]

    static func handles(_ args: [String]) -> Bool {
        args.dropFirst().contains { modes.contains($0) }
    }

    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            do {
                exit(try await perform(args) ? 0 : 1)
            } catch {
                log("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func perform(_ args: [String]) async throws -> Bool {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        if let path = value("--validate") { return validate(path) }
        if let i = args.firstIndex(of: "--probe") { return await probe(Array(args[(i + 1)...])) }
        if let out = value("--frame") {
            guard let project = try load(value("--project")) else { return false }
            let maxSize = try value("--max-size").map(size)
            return try await frame(project, at: value("--at").flatMap(Double.init) ?? 0, maxSize: maxSize, to: out)
        }
        if let out = value("--export") {
            guard let project = try load(value("--project")) else { return false }
            return try await export(project, to: out, resolution: value("--resolution"), codec: value("--codec"))
        }
        print(usage)
        return args.contains("--help")
    }

    // MARK: - Modes

    private static func validate(_ path: String) -> Bool {
        let project: Project
        do {
            project = try EditorStore.readProjectFile(URL(fileURLWithPath: path))
        } catch {
            log("error: \(error.localizedDescription)")
            return false
        }
        let issues = ProjectValidator.issues(in: project)
        issues.forEach { log($0.description) }
        let errors = issues.filter { $0.severity == .error }.count
        let normal = ProjectValidator.normalized(project)
        let clips = normal.tracks.reduce(0) { $0 + $1.clips.count }
        print(errors == 0 ? "OK" : "INVALID", "—", "\(normal.tracks.count) tracks, \(clips) clips, \(normal.media.count) media,",
              String(format: "%.3fs", normal.duration), "—", "\(errors) errors, \(issues.count - errors) warnings")
        return errors == 0
    }

    /// Prints a JSON array of media entries, ready to paste into a project's `media`.
    private static func probe(_ paths: [String]) async -> Bool {
        guard !paths.isEmpty else { log("error: --probe needs at least one file"); return false }
        let (items, failures) = await MediaImporter.importFiles(paths.map { URL(fileURLWithPath: $0) })
        failures.forEach { log("error: \($0.url.path): \($0.reason)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(items) { print(String(decoding: data, as: UTF8.self)) }
        return failures.isEmpty
    }

    private static func frame(_ project: Project, at t: Double, maxSize: CGSize?, to out: String) async throws -> Bool {
        guard project.duration > 0 else { log("error: the project has no clips"); return false }
        let image = try await FrameRenderer.image(of: project, at: t, maxSize: maxSize)
        let url = URL(fileURLWithPath: out)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            log("error: can't write \(url.path)")
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { log("error: can't write \(url.path)"); return false }
        print(url.path)
        return true
    }

    private static func export(_ project: Project, to out: String, resolution: String?, codec: String?) async throws -> Bool {
        guard project.duration > 0 else { log("error: the project has no clips"); return false }
        var settings = ExportSettings()
        let url = URL(fileURLWithPath: out)
        switch url.pathExtension.lowercased() {
        case "mp4": settings.container = .mp4
        case "mov": settings.container = .mov
        default: log("error: --export file must end in .mp4 or .mov"); return false
        }
        switch resolution?.lowercased() {
        case nil, "1080p": settings.resolution = .p1080
        case "720p": settings.resolution = .p720
        case "4k", "2160p": settings.resolution = .p2160
        case "project": settings.resolution = .canvas
        case let other?: log("error: unknown --resolution \(other) (720p, 1080p, 4k, project)"); return false
        }
        switch codec?.lowercased() {
        case nil, "h264": settings.codec = .h264
        case "hevc", "h265": settings.codec = .hevc
        case let other?: log("error: unknown --codec \(other) (h264, hevc)"); return false
        }

        let exporter = Exporter()
        let progress = Task { @MainActor in
            var last = -1
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let percent = Int(exporter.progress * 100)
                if percent != last { log("exporting \(percent)%"); last = percent }
            }
        }
        await exporter.export(project: project, to: url, settings: settings)
        progress.cancel()
        switch exporter.state {
        case .finished(let done):
            print(done.path)
            return true
        case .failed(let message):
            log("error: \(message)")
        default:
            log("error: export did not finish")
        }
        return false
    }

    // MARK: - Helpers

    /// Reads, validates and normalizes a project; prints issues. nil when it has errors.
    private static func load(_ path: String?) throws -> Project? {
        guard let path else { log("error: --project <file.editrush> is required"); return nil }
        let project = try EditorStore.readProjectFile(URL(fileURLWithPath: path))
        let issues = ProjectValidator.issues(in: project)
        issues.forEach { log($0.description) }
        guard !issues.contains(where: { $0.severity == .error }) else { return nil }
        return ProjectValidator.normalized(project)
    }

    private static func size(_ s: String) throws -> CGSize {
        let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw CommandLineError("--max-size must look like 1280x720")
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct CommandLineError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let usage = """
    EditRush command-line modes (project format: docs/project-format.md)

      --validate project.editrush
            Check a project file; prints issues and a summary. Exit 1 on errors.
      --probe media.mov [more files…]
            Print JSON media entries (id, url, kind, duration, size, frame rate, audio) for a project's "media".
      --frame out.png --project project.editrush [--at seconds] [--max-size WxH]
            Render the frame at a time to a PNG (full canvas size unless --max-size).
      --export out.mp4|out.mov --project project.editrush [--resolution 720p|1080p|4k|project] [--codec h264|hevc]
            Export the movie (defaults: 1080p, H.264).
      --snapshot out.png [--project project.editrush] [--playhead seconds] [--size WxH]
            Screenshot of the editor window showing the project.
    """
}
