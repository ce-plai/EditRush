import SwiftUI
import AppKit
import EditRushCore

// MARK: - Metrics

/// Layout constants shared by every inspector panel.
enum InspectorMetrics {
    static let hPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let fieldHeight: CGFloat = 20
    static let labelFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let captionFont = Font.system(size: 10.5)
}

// MARK: - Section

/// A titled group of controls separated from the next group by a hairline.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                accessory
            }
            .frame(height: 16)
            content
        }
        .padding(.horizontal, InspectorMetrics.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Slider

/// Compact Rush-style slider: thin track, fill drawn from `origin`, white knob.
/// Reports drag begin / end through `onEditingChanged` so callers can coalesce undo steps.
struct InspectorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Where the accent fill starts (e.g. 0 for bipolar controls). Defaults to the lower bound.
    var origin: Double?
    /// Replaces the plain track with a gradient (e.g. cool → warm) and hides the fill.
    var trackGradient: [Color]?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    private let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knob)
            let x = knob / 2 + usable * fraction(value)
            let o = knob / 2 + usable * fraction(origin ?? range.lowerBound)
            ZStack(alignment: .leading) {
                if let trackGradient {
                    Capsule()
                        .fill(LinearGradient(colors: trackGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 4)
                        .opacity(0.85)
                } else {
                    Capsule().fill(Color.white.opacity(0.13)).frame(height: 3)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, abs(x - o)), height: 3)
                        .offset(x: min(x, o))
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(x: x - knob / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        update(x: g.location.x, usable: usable)
                    }
                    .onEnded { g in
                        update(x: g.location.x, usable: usable)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 16)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 50
            let next = direction == .increment ? value + step : value - step
            value = next.inspectorClamped(to: range)
            onEditingChanged(false)
        }
    }

    private func fraction(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((v - range.lowerBound) / span).inspectorClamped(to: 0...1)
    }

    private func update(x: CGFloat, usable: CGFloat) {
        let f = Double((x - knob / 2) / usable).inspectorClamped(to: 0...1)
        let next = range.lowerBound + f * (range.upperBound - range.lowerBound)
        if next != value { value = next }
    }
}

// MARK: - Numeric field

/// Small numeric text field that commits on Return or focus loss, clamping to `range`.
/// Return also ends editing so editor shortcuts work again; Escape reverts and ends editing.
struct InspectorNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals = 0
    var width: CGFloat = 44
    /// Called after a committed edit (used to close the undo coalescing window).
    var onCommit: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(InspectorMetrics.valueFont)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .padding(.horizontal, 5)
            .frame(width: width, height: InspectorMetrics.fieldHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.accent : Theme.divider, lineWidth: 1))
            .onAppear { text = InspectorFormat.number(value, decimals: decimals) }
            .onChange(of: value) { _, v in if !focused { text = InspectorFormat.number(v, decimals: decimals) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit {
                commit()
                focused = false
            }
            .onExitCommand {
                text = InspectorFormat.number(value, decimals: decimals)
                focused = false
            }
            .onDisappear {
                // Selection changed mid-edit: keep what was typed.
                if text != InspectorFormat.number(value, decimals: decimals) { commit() }
            }
    }

    private func commit() {
        let cleaned = text.filter { "0123456789.,-−".contains($0) }
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        guard let parsed = Double(cleaned), parsed.isFinite else {
            text = InspectorFormat.number(value, decimals: decimals)
            return
        }
        let clamped = parsed.inspectorClamped(to: range)
        if clamped != value { value = clamped }
        text = InspectorFormat.number(clamped, decimals: decimals)
        onCommit()
    }
}

// MARK: - Slider row

/// Label + value field above a full-width slider, with a reset button that appears when the
/// value differs from `defaultValue`. Double-clicking the label also resets.
/// `value` and `range` are in display units (e.g. percent).
struct InspectorSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?
    var origin: Double?
    var unit = ""
    var decimals = 0
    /// Extra readout shown after the title (e.g. "−6.0 dB").
    var detail: String?
    var trackGradient: [Color]?
    /// Begin (true) / end (false) of a gesture or committed edit.
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var canReset: Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) > pow(10, -Double(decimals)) / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(InspectorMetrics.labelFont)
                    .foregroundStyle(Theme.textPrimary)
                    .onTapGesture(count: 2) { reset() }
                    .help(defaultValue == nil ? title : "Double-click to reset")
                if let detail {
                    Text(detail)
                        .font(InspectorMetrics.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                if defaultValue != nil {
                    InspectorResetButton(action: reset)
                        .opacity(canReset ? 1 : 0)
                        .disabled(!canReset)
                }
                InspectorNumberField(value: $value, range: range, decimals: decimals) { onEditingChanged(false) }
                Text(unit)
                    .font(InspectorMetrics.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, alignment: .leading)
            }
            InspectorSlider(value: $value, range: range, origin: origin, trackGradient: trackGradient,
                            onEditingChanged: onEditingChanged)
        }
    }

    private func reset() {
        guard let defaultValue, canReset else { return }
        onEditingChanged(false)
        value = defaultValue
        onEditingChanged(false)
    }
}

/// Small circular-arrow reset button.
struct InspectorResetButton: View {
    var help = "Reset"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Buttons & toggles

/// Compact rounded button used for actions and quick presets.
struct InspectorButtonStyle: ButtonStyle {
    var isProminent = false
    var isSelected = false
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(background.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        if isProminent { return .white }
        if isDestructive { return Color(red: 1, green: 0.45, blue: 0.42) }
        return isSelected ? Theme.accent : Theme.textPrimary
    }

    private var background: Color {
        if isProminent { return Theme.accent }
        return isSelected ? Theme.accent.opacity(0.16) : Theme.raised
    }
}

/// Icon button that shows an on / off state (bold, italic, flip, ...).
struct InspectorIconToggle: View {
    let systemImage: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(InspectorButtonStyle(isSelected: isOn))
        .help(help)
    }
}

/// Label with a trailing switch.
struct InspectorToggleRow: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title).font(InspectorMetrics.labelFont).foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }
}

/// Label with a trailing colour well bound to an `RGBA` value.
struct InspectorColorRow<Leading: View>: View {
    let title: String
    let color: RGBA
    var supportsOpacity = true
    let set: (RGBA) -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(title).font(InspectorMetrics.labelFont).foregroundStyle(Theme.textPrimary)
            Spacer()
            ColorPicker("", selection: Binding(get: { color.inspectorColor }, set: { set(RGBA(inspectorColor: $0)) }),
                        supportsOpacity: supportsOpacity)
                .labelsHidden()
                .frame(width: 38, height: 20)
        }
    }
}

extension InspectorColorRow where Leading == EmptyView {
    init(title: String, color: RGBA, supportsOpacity: Bool = true, set: @escaping (RGBA) -> Void) {
        self.init(title: title, color: color, supportsOpacity: supportsOpacity, set: set, leading: { EmptyView() })
    }
}

/// Small explanatory text with an info glyph.
struct InspectorCaption: View {
    let text: String
    var systemImage = "info.circle"
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(InspectorMetrics.captionFont)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Key / value line used in summaries.
struct InspectorInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(InspectorMetrics.labelFont)
    }
}

/// Plain text field that keeps a local draft and commits on Return / focus loss.
/// Return also ends editing; Escape reverts and ends editing.
struct InspectorTextField: View {
    let text: String
    var placeholder = ""
    var font = Font.system(size: 12)
    var boxed = true
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .padding(.horizontal, boxed ? 7 : 3)
            .padding(.vertical, boxed ? 4 : 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(boxed || focused ? Theme.windowBackground : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Theme.accent : (boxed ? Theme.divider : .clear), lineWidth: 1))
            .onAppear { draft = text }
            .onChange(of: text) { _, t in if !focused { draft = t } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit {
                commit()
                focused = false
            }
            .onExitCommand { draft = text; focused = false }
            .onDisappear { commit() }
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}

// MARK: - Helpers

extension Comparable {
    func inspectorClamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

extension RGBA {
    /// SwiftUI colour for inspector colour wells.
    var inspectorColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Converts any SwiftUI colour to sRGB components.
    init(inspectorColor color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

/// Text formatting for inspector readouts.
enum InspectorFormat {
    static func number(_ v: Double, decimals: Int) -> String {
        let s = String(format: "%.\(max(0, decimals))f", v)
        // Avoid "-0" / "-0.00".
        if let d = Double(s), d == 0 { return String(format: "%.\(max(0, decimals))f", 0.0) }
        return s
    }

    /// "MM:SS:FF" (or "H:MM:SS:FF") at the canvas frame rate.
    static func timecode(_ t: Seconds, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        let frames = max(0, Int((t * Double(rate)).rounded()))
        let f = frames % rate, s = frames / rate
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d:%02d", h, m, sec, f) : String(format: "%02d:%02d:%02d", m, sec, f)
    }

    /// Human duration, e.g. "16.4 s", "2:05".
    static func duration(_ t: Seconds) -> String {
        if t < 60 { return String(format: "%.1f s", t) }
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Linear gain as decibels.
    static func decibels(_ gain: Double) -> String {
        guard gain > 0.0001 else { return "−∞ dB" }
        let db = 20 * log10(gain)
        let s = String(format: "%+.1f dB", abs(db) < 0.05 ? 0 : db)
        return s.replacingOccurrences(of: "-", with: "−")
    }
}

/// Applies inspector edits to one clip with per-field undo coalescing.
@MainActor
struct InspectorClipEdit {
    let store: EditorStore
    let clipID: UUID

    /// Edits the clip; `field` groups consecutive edits of one control into a single undo step.
    /// Pass `timeout` for controls with no end event (colour wells): a pause that long starts a new step.
    func callAsFunction(_ action: String, field: String? = nil, timeout: TimeInterval? = nil, _ body: (inout Clip) -> Void) {
        store.updateClip(clipID, action, coalesce: field.map { "inspector-\($0)-\(clipID.uuidString)" },
                         coalesceTimeout: timeout, body)
    }

    /// Slider `onEditingChanged` handler: closes the coalescing window when a drag / commit ends.
    func editingChanged(_ began: Bool) {
        if !began { store.endCoalescing() }
    }

    /// Binding in display units for a slider row: `get` reads the clip snapshot, `set` writes through the store.
    func binding(_ action: String, field: String, get: @escaping @Sendable () -> Double,
                 set: @escaping (inout Clip, Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: { v in self(action, field: field) { set(&$0, v) } })
    }
}
