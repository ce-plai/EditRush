import SwiftUI
import EditRushCore

/// Scale, position, rotation, opacity, flips and fit mode of a visual clip.
struct TransformInspectorPage: View {
    let clip: Clip
    let kind: InspectorClipKind
    @Environment(EditorStore.self) private var store

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let t = clip.transform

        VStack(spacing: 0) {
            InspectorSection("Size") {
                InspectorSliderRow(
                    title: "Scale",
                    value: edit.binding("Scale", field: "scale", get: { t.scale * 100 },
                                        set: { $0.transform.scale = ($1 / 100).inspectorClamped(to: 0.02...4) }),
                    range: 2...400, defaultValue: 100, unit: "%", onEditingChanged: edit.editingChanged)
                if kind != .text {
                    HStack(spacing: 6) {
                        Text("Frame").font(InspectorMetrics.labelFont).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        ForEach(FitMode.allCases, id: \.self) { mode in
                            Button {
                                edit(mode == .fit ? "Fit to Frame" : "Fill Frame") { $0.transform.fitMode = mode }
                            } label: {
                                Label(mode == .fit ? "Fit" : "Fill",
                                      systemImage: mode == .fit ? "rectangle.inset.filled" : "rectangle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .frame(width: 58)
                            }
                            .buttonStyle(InspectorButtonStyle(isSelected: t.fitMode == mode))
                            .help(mode == .fit ? "Show the whole frame (letterbox)" : "Fill the canvas (crop)")
                        }
                    }
                }
            }

            InspectorSection("Position", accessory: {
                Button("Center") { edit("Center") { $0.transform.offsetX = 0; $0.transform.offsetY = 0 } }
                    .buttonStyle(InspectorButtonStyle())
                    .disabled(t.offsetX == 0 && t.offsetY == 0)
            }) {
                InspectorSliderRow(
                    title: "X",
                    value: edit.binding("Move", field: "position-x", get: { t.offsetX * 100 },
                                        set: { $0.transform.offsetX = ($1 / 100).inspectorClamped(to: -1...1) }),
                    range: -100...100, defaultValue: 0, origin: 0, unit: "%", onEditingChanged: edit.editingChanged)
                InspectorSliderRow(
                    title: "Y",
                    value: edit.binding("Move", field: "position-y", get: { t.offsetY * 100 },
                                        set: { $0.transform.offsetY = ($1 / 100).inspectorClamped(to: -1...1) }),
                    range: -100...100, defaultValue: 0, origin: 0, unit: "%", onEditingChanged: edit.editingChanged)
            }

            InspectorSection("Rotation & Opacity") {
                InspectorSliderRow(
                    title: "Rotation",
                    value: edit.binding("Rotate", field: "rotation", get: { t.rotation },
                                        set: { $0.transform.rotation = $1.inspectorClamped(to: -180...180) }),
                    range: -180...180, defaultValue: 0, origin: 0, unit: "°", onEditingChanged: edit.editingChanged)
                InspectorSliderRow(
                    title: "Opacity",
                    value: edit.binding("Opacity", field: "opacity", get: { t.opacity * 100 },
                                        set: { $0.transform.opacity = ($1 / 100).inspectorClamped(to: 0...1) }),
                    range: 0...100, defaultValue: 100, unit: "%", onEditingChanged: edit.editingChanged)
                HStack(spacing: 6) {
                    InspectorIconToggle(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                        help: "Flip Horizontal", isOn: t.flipHorizontal) {
                        edit("Flip Horizontal") { $0.transform.flipHorizontal.toggle() }
                    }
                    InspectorIconToggle(systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                        help: "Flip Vertical", isOn: t.flipVertical) {
                        edit("Flip Vertical") { $0.transform.flipVertical.toggle() }
                    }
                    InspectorIconToggle(systemImage: "rotate.left", help: "Rotate 90° Left", isOn: false) {
                        edit("Rotate") { $0.transform.rotation = Self.rotate($0.transform.rotation, by: -90) }
                    }
                    InspectorIconToggle(systemImage: "rotate.right", help: "Rotate 90° Right", isOn: false) {
                        edit("Rotate") { $0.transform.rotation = Self.rotate($0.transform.rotation, by: 90) }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    edit("Reset Transform") { $0.transform = .identity }
                } label: {
                    Label("Reset Transform", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(InspectorButtonStyle())
                .disabled(t.isIdentity)
                Spacer()
            }
            .padding(.vertical, 14)
        }
    }

    /// Adds `delta` degrees and wraps into -180...180.
    private static func rotate(_ angle: Double, by delta: Double) -> Double {
        var a = (angle + delta).truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }
}
