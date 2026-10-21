import SwiftUI
import EditRushCore

/// Shared fades and actions for several selected clips.
struct MultiSelectionInspector: View {
    let clips: [Clip]
    @Environment(EditorStore.self) private var store
    /// Values shown while a slider is dragged; applied with `setFades` when the drag ends so
    /// one gesture is one undo step.
    @State private var draftIn: Seconds?
    @State private var draftOut: Seconds?

    private var breakdown: String {
        var counts: [InspectorClipKind: Int] = [:]
        for clip in clips { counts[InspectorClipKind(clip: clip, media: store.media(clip.mediaID)), default: 0] += 1 }
        let order: [InspectorClipKind] = [.video, .image, .text, .audio]
        return order.compactMap { kind in
            counts[kind].map { "\($0) \(kind.title.lowercased())" }
        }.joined(separator: " · ")
    }

    var body: some View {
        let limit = max(0.01, min(inspectorMaxFade, clips.map(\.duration).min() ?? inspectorMaxFade))
        let fadeIns = clips.map(\.fadeIn), fadeOuts = clips.map(\.fadeOut)

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                header
                InspectorSection("Fade In (from black)") {
                    InspectorSliderRow(
                        title: "Duration",
                        value: Binding(get: { draftIn ?? fadeIns.max() ?? 0 }, set: { draftIn = $0 }),
                        range: 0...limit, defaultValue: 0, unit: "s", decimals: 2,
                        detail: Self.isMixed(fadeIns) && draftIn == nil ? "Mixed" : nil) { began in
                        if !began, let v = draftIn { store.setFades(in: v, out: nil); draftIn = nil }
                    }
                    InspectorFadePresets(current: Self.isMixed(fadeIns) ? -1 : fadeIns.first ?? 0, limit: limit) {
                        store.setFades(in: $0, out: nil)
                    }
                }
                InspectorSection("Fade Out (to black)") {
                    InspectorSliderRow(
                        title: "Duration",
                        value: Binding(get: { draftOut ?? fadeOuts.max() ?? 0 }, set: { draftOut = $0 }),
                        range: 0...limit, defaultValue: 0, unit: "s", decimals: 2,
                        detail: Self.isMixed(fadeOuts) && draftOut == nil ? "Mixed" : nil) { began in
                        if !began, let v = draftOut { store.setFades(in: nil, out: v); draftOut = nil }
                    }
                    InspectorFadePresets(current: Self.isMixed(fadeOuts) ? -1 : fadeOuts.first ?? 0, limit: limit) {
                        store.setFades(in: nil, out: $0)
                    }
                }
                InspectorSection("Actions") {
                    HStack(spacing: 6) {
                        Button { store.duplicateSelection() } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorButtonStyle())
                        Button { store.joinSelection() } label: {
                            Label("Join", systemImage: "arrow.right.and.line.vertical.and.arrow.left").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorButtonStyle())
                        .disabled(!store.canJoinSelection)
                        .help("Join adjacent clips from the same source")
                    }
                    HStack(spacing: 6) {
                        Button { store.deleteSelection(ripple: false) } label: {
                            Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorButtonStyle(isDestructive: true))
                        Button { store.deleteSelection(ripple: true) } label: {
                            Label("Ripple Delete", systemImage: "arrow.left.to.line").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorButtonStyle(isDestructive: true))
                        .help("Delete and close the gap")
                    }
                }
                InspectorCaption(text: "Fades apply to every selected clip. On upper tracks they dissolve to the layers below.")
                    .padding(.horizontal, InspectorMetrics.hPadding)
                    .padding(.vertical, 12)
            }
        }
    }

    private var header: some View {
        let total = (clips.map(\.end).max() ?? 0) - (clips.map(\.start).min() ?? 0)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.raised).frame(width: 26, height: 26).offset(x: 4, y: -4)
                RoundedRectangle(cornerRadius: 6).fill(Theme.accent.gradient).frame(width: 26, height: 26)
                Text("\(clips.count)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(clips.count) clips selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(breakdown + " · spans " + InspectorFormat.duration(total))
                    .font(InspectorMetrics.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, InspectorMetrics.hPadding)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private static func isMixed(_ values: [Double]) -> Bool {
        guard let first = values.first else { return false }
        return values.contains { abs($0 - first) > 0.0005 }
    }
}
