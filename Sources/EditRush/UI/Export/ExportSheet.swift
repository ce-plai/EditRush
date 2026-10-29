import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditRushCore

/// Export flow: settings → save panel → progress (cancellable, hideable) → result.
struct ExportSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(Exporter.self) private var exporter
    @Environment(ShellState.self) private var shell
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.resolution") private var resolution: ExportSettings.Resolution = .p1080
    @AppStorage("export.codec") private var codec: ExportSettings.Codec = .h264
    @AppStorage("export.container") private var container: ExportSettings.Container = .mp4
    @AppStorage("export.lastDirectory") private var lastDirectory: String = ""
    /// File size slider, 0…1 across `sizeRange` on a log scale; 1 = best quality (no target).
    @State private var sizePosition: Double = 1
    @State private var poster: CGImage?
    @State private var note: String?

    private enum Phase: Equatable {
        case settings, exporting, finished(URL), failed(String)
    }

    private var phase: Phase {
        switch exporter.state {
        case .exporting: return .exporting
        case .finished(let url) where shell.exportSessionActive: return .finished(url)
        case .failed(let message) where shell.exportSessionActive: return .failed(message)
        default: return .settings
        }
    }

    private var settings: ExportSettings {
        var s = ExportSettings()
        s.resolution = resolution
        s.codec = codec
        s.container = container
        s.targetFileSize = targetFileSize(in: s.fileSizeRange(for: store.project.canvas, duration: duration))
        return s
    }

    /// nil at the slider's top end; otherwise a size between the range's ends, rounded to two
    /// significant digits so the export aims for exactly the size shown.
    private func targetFileSize(in range: ClosedRange<Int64>) -> Int64? {
        guard sizePosition < 1, duration > 0 else { return nil }
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        let bytes = low * pow(high / low, sizePosition)
        let step = pow(10, floor(log10(bytes)) - 1)
        return Int64((bytes / step).rounded() * step)
    }

    private var duration: Seconds { store.project.duration }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            Group {
                switch phase {
                case .settings: settingsForm
                case .exporting: progressView
                case .finished(let url): ExportResultView(url: url)
                case .failed(let message): failureView(message)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 250)
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Theme.panelHeader)
        }
        .frame(width: 560)
        .background(Theme.panelBackground)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(phase == .exporting)
        .animation(.snappy(duration: 0.2), value: phase)
        .task { await renderPoster() }
        .onChange(of: exporter.state) { _, state in
            if state == .cancelled, shell.exportSessionActive {
                shell.exportSessionActive = false
                note = "Export cancelled."
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: "\(store.project.name) · \(Self.format(duration)) · \(store.project.canvas.width)×\(store.project.canvas.height) canvas")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Theme.panelHeader)
    }

    private var headerTitle: String {
        switch phase {
        case .settings: "Export Video"
        case .exporting: "Exporting…"
        case .finished: "Export Complete"
        case .failed: "Export Failed"
        }
    }

    // MARK: Settings

    private var settingsForm: some View {
        let size = settings.outputSize(for: store.project.canvas)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                posterView
                VStack(alignment: .leading, spacing: 10) {
                    summaryRow("Output", "\(Int(size.width)) × \(Int(size.height))", emphasized: true)
                    summaryRow("Duration", Self.format(duration, fractional: true))
                    summaryRow("Frame rate", "\(Self.formatRate(store.project.canvas.frameRate)) fps")
                    summaryRow("File", "\(codec.rawValue) · .\(fileExtension)" + (settings.targetFileSize == nil ? "" : " · " + sizeLabel))
                }
                Spacer(minLength: 0)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    formLabel("Resolution")
                    Picker("Resolution", selection: $resolution) {
                        ForEach(ExportSettings.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                GridRow {
                    formLabel("Codec")
                    Picker("Codec", selection: $codec) {
                        ForEach(ExportSettings.Codec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                GridRow {
                    formLabel("Format")
                    Picker("Format", selection: $container) {
                        ForEach(ExportSettings.Container.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                GridRow {
                    formLabel("File size")
                    HStack(spacing: 10) {
                        Slider(value: $sizePosition, in: 0...1) {
                            Text("File size")
                        } minimumValueLabel: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").help("Smaller file")
                        } maximumValueLabel: {
                            Image(systemName: "sparkles").help("Best quality")
                        }
                        .disabled(duration <= 0)
                        Text(sizeLabel)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 92, alignment: .trailing)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(hint)
                .font(.caption)
                .foregroundStyle(note == nil ? Theme.textSecondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeLabel: String {
        guard let bytes = settings.targetFileSize else { return "Best quality" }
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var hint: String {
        if let note { return note }
        if duration <= 0 { return "Add clips to the timeline to export." }
        if settings.targetFileSize != nil {
            return sizePosition < 0.3
                ? "The file will be about this size, but the picture will look noticeably soft or blocky."
                : "The file will be about this size — handy for upload limits. Smaller sizes lower the picture quality."
        }
        return codec == .hevc
            ? "HEVC makes smaller files at the same quality; plays on Apple devices and modern browsers."
            : "H.264 plays everywhere — the safest choice for sharing and uploading."
    }

    private var posterView: some View {
        ZStack {
            Color.black
            if let poster {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 208, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
    }

    private func summaryRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(emphasized ? .title3.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: Progress

    private var progressView: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "\(Int((exporter.progress * 100).rounded(.down)))%")
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(remainingText(now: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                ProgressView(value: min(1, max(0, exporter.progress)))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                if let url = shell.exportURL {
                    Label(url.lastPathComponent, systemImage: "doc")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("You can hide this window and keep editing; the Export button shows progress.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func remainingText(now: Date) -> String {
        guard let start = shell.exportStartedAt else { return "" }
        let elapsed = now.timeIntervalSince(start)
        let p = exporter.progress
        guard p > 0.03, elapsed > 1 else { return "Estimating time…" }
        let remaining = max(0, elapsed * (1 - p) / p)
        if remaining < 5 { return "Almost done" }
        if remaining < 60 { return "About \(Int(remaining.rounded())) s remaining" }
        return "About \(Int((remaining / 60).rounded(.up))) min remaining"
    }

    // MARK: Failure

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("The video couldn't be exported.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .settings:
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: chooseDestinationAndExport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ShellAccentButtonStyle())
                    .disabled(duration <= 0)
            case .exporting:
                Button("Hide") { dismiss() }
                Spacer()
                Button("Cancel Export", role: .destructive) { exporter.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished(let url):
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ShellAccentButtonStyle())
            case .failed:
                Button("Close", action: finish)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { shell.exportSessionActive = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ShellAccentButtonStyle())
            }
        }
        .controlSize(.large)
    }

    // MARK: Actions

    private var fileExtension: String { container == .mp4 ? "mp4" : "mov" }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.prompt = "Export"
        panel.allowedContentTypes = [container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ShellDocumentController.fileSafeName(store.project.name) + "." + fileExtension
        panel.directoryURL = lastDirectory.isEmpty
            ? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            : URL(fileURLWithPath: lastDirectory, isDirectory: true)
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != fileExtension { url.appendPathExtension(fileExtension) }
        lastDirectory = url.deletingLastPathComponent().path
        // The save panel already confirmed replacing an existing file.
        try? FileManager.default.removeItem(at: url)

        note = nil
        shell.exportURL = url
        shell.exportStartedAt = Date()
        shell.exportSessionActive = true
        let project = store.project
        let settings = settings
        Task { await exporter.export(project: project, to: url, settings: settings) }
    }

    private func finish() {
        shell.exportSessionActive = false
        dismiss()
    }

    private func renderPoster() async {
        let project = store.project
        guard project.duration > 0 else { return }
        let t = store.playhead > 0 && store.playhead < project.duration ? store.playhead : project.duration * 0.3
        poster = try? await FrameRenderer.image(of: project, at: t, maxSize: CGSize(width: 400, height: 400))
    }

    // MARK: Formatting

    /// "0:13" or with `fractional` "0:13.5".
    static func format(_ seconds: Seconds, fractional: Bool = false) -> String {
        let clamped = max(0, seconds)
        let m = Int(clamped) / 60
        if fractional {
            return String(format: "%d:%04.1f", m, clamped - Double(m * 60))
        }
        let s = Int(clamped.rounded()) - m * 60
        return String(format: "%d:%02d", m, s)
    }

    static func formatRate(_ fps: Double) -> String {
        fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
    }
}

/// Success state: file name, location and size.
private struct ExportResultView: View {
    let url: URL
    @State private var fileSize: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            Text(url.lastPathComponent)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text([url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), fileSize]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let path = url.path
            let bytes = await Task.detached(priority: .utility) {
                (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            }.value
            if let bytes { fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        }
    }
}
