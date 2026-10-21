import SwiftUI
import EditRushCore

/// Project name, canvas format and summary, shown when nothing is selected.
struct ProjectInspector: View {
    @Environment(EditorStore.self) private var store

    private static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    private static let customTag = -1

    var body: some View {
        let project = store.project
        let canvas = project.canvas
        let presetIndex = CanvasSettings.presets.firstIndex {
            $0.settings.width == canvas.width && $0.settings.height == canvas.height
        } ?? Self.customTag

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                InspectorSection("Project") {
                    InspectorTextField(text: project.name, placeholder: "Untitled") { name in
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.mutate("Rename Project") { $0.name = trimmed.isEmpty ? "Untitled" : trimmed }
                    }
                }

                InspectorSection("Canvas") {
                    InspectorCanvasPreview(canvas: canvas)
                    Picker("", selection: Binding(get: { presetIndex }, set: { index in
                        guard CanvasSettings.presets.indices.contains(index) else { return }
                        var next = canvas
                        next.width = CanvasSettings.presets[index].settings.width
                        next.height = CanvasSettings.presets[index].settings.height
                        store.setCanvas(next)
                    })) {
                        ForEach(CanvasSettings.presets.indices, id: \.self) { i in
                            Text(CanvasSettings.presets[i].name).tag(i)
                        }
                        Divider()
                        Text("Custom").tag(Self.customTag)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)

                    HStack(spacing: 6) {
                        dimensionField("W", value: canvas.width) { var c = canvas; c.width = $0; store.setCanvas(c) }
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary)
                        dimensionField("H", value: canvas.height) { var c = canvas; c.height = $0; store.setCanvas(c) }
                        Spacer(minLength: 4)
                        Button {
                            var c = canvas
                            swap(&c.width, &c.height)
                            store.setCanvas(c)
                        } label: {
                            Image(systemName: "rectangle.portrait.rotate")
                        }
                        .buttonStyle(InspectorButtonStyle())
                        .help("Swap width and height")
                        .disabled(canvas.width == canvas.height)
                    }

                    HStack(spacing: 6) {
                        Text("Frame rate").font(InspectorMetrics.labelFont).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        InspectorNumberField(
                            value: Binding(get: { canvas.frameRate }, set: { fps in
                                var c = canvas
                                c.frameRate = fps
                                store.setCanvas(c)
                            }),
                            range: 1...120, decimals: canvas.frameRate.rounded() == canvas.frameRate ? 0 : 3, width: 52)
                        Menu {
                            ForEach(Self.frameRates, id: \.self) { fps in
                                Button(InspectorFormat.number(fps, decimals: fps.rounded() == fps ? 0 : 3) + " fps") {
                                    var c = canvas
                                    c.frameRate = fps
                                    store.setCanvas(c)
                                }
                            }
                        } label: {
                            Text("fps")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                        .font(InspectorMetrics.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Common frame rates")
                    }

                    InspectorColorRow(title: "Background", color: canvas.backgroundColor, supportsOpacity: false) { rgba in
                        var c = canvas
                        c.backgroundColor = RGBA(rgba.r, rgba.g, rgba.b, 1)
                        store.mutate("Change Background", coalesce: "inspector-background", coalesceTimeout: 1.5) { $0.canvas = c }
                    }
                }

                InspectorSection("Summary") {
                    VStack(spacing: 7) {
                        InspectorInfoRow(title: "Duration", value: InspectorFormat.timecode(project.duration, fps: canvas.frameRate))
                        InspectorInfoRow(title: "Clips", value: "\(project.tracks.reduce(0) { $0 + $1.clips.count })")
                        InspectorInfoRow(title: "Tracks", value: "\(project.videoTracks.count) video · \(project.audioTracks.count) audio")
                        InspectorInfoRow(title: "Media", value: "\(project.media.count)")
                    }
                }

                VStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 22, weight: .light))
                    Text("Select a clip in the timeline to edit its text, transform, fades, color and audio.")
                        .font(InspectorMetrics.captionFont)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
    }

    /// Integer pixel field; values are rounded to even numbers (required by H.264 / HEVC).
    private func dimensionField(_ label: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(InspectorMetrics.captionFont).foregroundStyle(Theme.textSecondary)
            InspectorNumberField(
                value: Binding(get: { Double(value) }, set: { v in
                    let even = Int((v / 2).rounded()) * 2
                    if even != value { set(even) }
                }),
                range: 16...8192, decimals: 0, width: 54)
        }
    }
}

/// Small proportional rectangle illustrating the canvas aspect ratio and background colour.
struct InspectorCanvasPreview: View {
    let canvas: CanvasSettings

    var body: some View {
        let maxW: CGFloat = 92, maxH: CGFloat = 52
        let aspect = CGFloat(canvas.aspect)
        let size = aspect >= maxW / maxH ? CGSize(width: maxW, height: maxW / aspect) : CGSize(width: maxH * aspect, height: maxH)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(canvas.backgroundColor.inspectorColor)
                .frame(width: size.width, height: size.height)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .frame(width: maxW, height: maxH)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(canvas.width) + " × " + String(canvas.height))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.ratio(canvas) + " · " + InspectorFormat.number(canvas.frameRate, decimals: canvas.frameRate.rounded() == canvas.frameRate ? 0 : 3) + " fps")
                    .font(InspectorMetrics.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private static func ratio(_ c: CanvasSettings) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(1, gcd(c.width, c.height))
        let w = c.width / g, h = c.height / g
        return w <= 32 && h <= 32 ? "\(w):\(h)" : String(format: "%.2f:1", c.aspect)
    }
}
