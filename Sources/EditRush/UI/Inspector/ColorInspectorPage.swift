import SwiftUI
import EditRushCore

/// Per-clip colour adjustments. Sliders show friendly units; the model keeps Core Image ranges.
struct ColorInspectorPage: View {
    let clip: Clip
    @Environment(EditorStore.self) private var store

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let c = clip.color

        VStack(spacing: 0) {
            InspectorSection("Light", accessory: {
                Button("Reset All") { edit("Reset Color") { $0.color = .identity } }
                    .buttonStyle(InspectorButtonStyle())
                    .disabled(c.isIdentity)
            }) {
                InspectorSliderRow(
                    title: "Exposure",
                    value: edit.binding("Exposure", field: "exposure", get: { c.exposure },
                                        set: { $0.color.exposure = $1.inspectorClamped(to: -2...2) }),
                    range: -2...2, defaultValue: 0, origin: 0, unit: "EV", decimals: 2,
                    onEditingChanged: edit.editingChanged)
                InspectorSliderRow(
                    title: "Brightness",
                    value: edit.binding("Brightness", field: "brightness", get: { c.brightness * 200 },
                                        set: { $0.color.brightness = ($1 / 200).inspectorClamped(to: -0.5...0.5) }),
                    range: -100...100, defaultValue: 0, origin: 0, onEditingChanged: edit.editingChanged)
                InspectorSliderRow(
                    title: "Contrast",
                    value: edit.binding("Contrast", field: "contrast", get: { c.contrast * 100 },
                                        set: { $0.color.contrast = ($1 / 100).inspectorClamped(to: 0.25...2) }),
                    range: 25...200, defaultValue: 100, origin: 100, unit: "%", onEditingChanged: edit.editingChanged)
            }
            InspectorSection("Color") {
                InspectorSliderRow(
                    title: "Saturation",
                    value: edit.binding("Saturation", field: "saturation", get: { c.saturation * 100 },
                                        set: { $0.color.saturation = ($1 / 100).inspectorClamped(to: 0...2) }),
                    range: 0...200, defaultValue: 100, unit: "%",
                    trackGradient: [Color(white: 0.5), Color(red: 0.95, green: 0.3, blue: 0.55), Color(red: 1, green: 0.1, blue: 0.2)],
                    onEditingChanged: edit.editingChanged)
                InspectorSliderRow(
                    title: "Temperature",
                    value: edit.binding("Temperature", field: "temperature", get: { c.temperature * 100 },
                                        set: { $0.color.temperature = ($1 / 100).inspectorClamped(to: -1...1) }),
                    range: -100...100, defaultValue: 0, origin: 0,
                    trackGradient: [Color(red: 0.25, green: 0.55, blue: 1), Color(white: 0.75), Color(red: 1, green: 0.62, blue: 0.2)],
                    onEditingChanged: edit.editingChanged)
            }
            InspectorSection("Effects") {
                InspectorSliderRow(
                    title: "Vignette",
                    value: edit.binding("Vignette", field: "vignette", get: { c.vignette * 100 },
                                        set: { $0.color.vignette = ($1 / 100).inspectorClamped(to: 0...1) }),
                    range: 0...100, defaultValue: 0, unit: "%", onEditingChanged: edit.editingChanged)
            }
            InspectorCaption(text: "Double-click a slider's name to reset it.")
                .padding(.horizontal, InspectorMetrics.hPadding)
                .padding(.vertical, 12)
        }
    }
}
