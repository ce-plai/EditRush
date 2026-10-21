import SwiftUI
import AppKit
import CoreText
import EditRushCore

/// Content and styling of a text (title) clip.
struct TextInspectorPage: View {
    let clip: Clip
    @Environment(EditorStore.self) private var store

    var body: some View {
        let edit = InspectorClipEdit(store: store, clipID: clip.id)
        let style = clip.text ?? TextStyle()
        let canvasHeight = Double(store.project.canvas.height)

        VStack(spacing: 0) {
            InspectorSection("Text") {
                InspectorTextEditor(text: style.text, clipID: clip.id, onChange: { newText in
                    edit("Edit Text", field: "text") { $0.text?.text = newText }
                }, onEnd: { edit.editingChanged(false) })
            }

            InspectorSection("Font") {
                InspectorFontPicker(family: style.fontFamily) { family in
                    edit("Font") { $0.text?.fontFamily = family }
                }
                HStack(spacing: 6) {
                    InspectorIconToggle(systemImage: "bold", help: "Bold", isOn: style.isBold) {
                        edit("Bold") { $0.text?.isBold.toggle() }
                    }
                    InspectorIconToggle(systemImage: "italic", help: "Italic", isOn: style.isItalic) {
                        edit("Italic") { $0.text?.isItalic.toggle() }
                    }
                    Rectangle().fill(Theme.divider).frame(width: 1, height: 18).padding(.horizontal, 2)
                    ForEach(TextAlignmentOption.allCases, id: \.self) { a in
                        InspectorIconToggle(systemImage: Self.alignmentIcon(a), help: "Align \(a.rawValue.capitalized)",
                                            isOn: style.alignment == a) {
                            edit("Text Alignment") { $0.text?.alignment = a }
                        }
                    }
                }
                InspectorSliderRow(
                    title: "Size",
                    value: edit.binding("Font Size", field: "font-size", get: { style.fontSize * canvasHeight },
                                        set: { c, v in c.text?.fontSize = (v / max(1, canvasHeight)).inspectorClamped(to: 0.01...0.5) }),
                    range: (0.01 * canvasHeight)...(0.5 * canvasHeight), defaultValue: TextStyle().fontSize * canvasHeight,
                    unit: "px", onEditingChanged: edit.editingChanged)
            }

            InspectorSection("Appearance") {
                InspectorColorRow(title: "Text color", color: style.color) { rgba in
                    edit("Text Color", field: "text-color", timeout: Self.colorWellTimeout) { $0.text?.color = rgba }
                }
                InspectorColorRow(title: "Background box", color: style.backgroundColor.a > 0 ? style.backgroundColor : RGBA(0, 0, 0, 0.6),
                                  set: { rgba in
                                      edit("Text Background", field: "text-background", timeout: Self.colorWellTimeout) { $0.text?.backgroundColor = rgba }
                                  }, leading: {
                                      Toggle("", isOn: Binding(get: { style.backgroundColor.a > 0 }, set: { on in
                                          edit(on ? "Show Text Background" : "Hide Text Background") {
                                              $0.text?.backgroundColor = on ? RGBA(0, 0, 0, 0.6) : .clear
                                          }
                                      }))
                                      .toggleStyle(.checkbox)
                                      .labelsHidden()
                                  })
                InspectorToggleRow(title: "Drop shadow", isOn: style.shadow) { on in
                    edit(on ? "Add Text Shadow" : "Remove Text Shadow") { $0.text?.shadow = on }
                }
            }

            InspectorSection("Outline") {
                InspectorSliderRow(
                    title: "Width",
                    value: edit.binding("Outline Width", field: "outline-width", get: { style.outlineWidth * 100 },
                                        set: { $0.text?.outlineWidth = ($1 / 100).inspectorClamped(to: 0...0.25) }),
                    range: 0...25, defaultValue: 0, unit: "%", onEditingChanged: edit.editingChanged)
                InspectorColorRow(title: "Outline color", color: style.outlineColor) { rgba in
                    edit("Outline Color", field: "outline-color", timeout: Self.colorWellTimeout) { $0.text?.outlineColor = rgba }
                }
                .disabled(style.outlineWidth <= 0)
                .opacity(style.outlineWidth <= 0 ? 0.5 : 1)
            }
        }
    }

    /// Colour wells report no end of editing, so a pause this long starts a new undo step.
    private static let colorWellTimeout: TimeInterval = 1.5

    private static func alignmentIcon(_ a: TextAlignmentOption) -> String {
        switch a {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

/// Multi-line editor that pushes every keystroke to the store (coalesced into one undo step).
/// Return inserts a new line; Escape or a click elsewhere ends editing. Takes focus with all text
/// selected when `InspectorFocus` requests text editing for `clipID`.
struct InspectorTextEditor: View {
    let text: String
    var clipID: UUID?
    let onChange: (String) -> Void
    /// Called when editing ends (focus leaves the editor).
    let onEnd: () -> Void
    @FocusState private var focused: Bool
    @State private var selectsAllOnFocus = false

    var body: some View {
        let request = InspectorFocus.shared.textEditRequest.flatMap { $0.clipID == clipID ? $0 : nil }
        TextEditor(text: Binding(get: { text }, set: { if $0 != text { onChange($0) } }))
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.accent : Theme.divider, lineWidth: 1))
            .onExitCommand { focused = false }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    onEnd()
                } else if selectsAllOnFocus {
                    selectsAllOnFocus = false
                    Self.selectAllInFocusedEditor()
                }
            }
            .onChange(of: request, initial: true) { _, request in
                guard let request else { return }
                // Focus once the editor is in its window (it may have just been created).
                DispatchQueue.main.async {
                    InspectorFocus.shared.consume(request)
                    if focused {
                        Self.selectAllInFocusedEditor()
                    } else {
                        selectsAllOnFocus = true
                        focused = true
                    }
                }
            }
    }

    /// Selects all text so typing replaces the placeholder title (after focus has settled).
    private static func selectAllInFocusedEditor() {
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }
}

// MARK: - Font picker

/// Installed font families, loaded once off the main thread.
@MainActor
@Observable
final class InspectorFontCatalog {
    static let shared = InspectorFontCatalog()

    /// Popular, widely installed families shown first (filtered to what is installed).
    static let curated = [
        "Helvetica Neue", "Avenir Next", "SF Pro", "Futura", "Gill Sans", "Montserrat", "Arial", "Arial Black",
        "Impact", "DIN Alternate", "DIN Condensed", "Optima", "Trebuchet MS", "Verdana", "Georgia", "Baskerville",
        "Didot", "Bodoni 72", "Palatino", "Times New Roman", "Rockwell", "American Typewriter", "Courier New", "Menlo",
        "Marker Felt", "Chalkboard SE", "Noteworthy", "Bradley Hand", "Snell Roundhand", "Zapfino", "Copperplate",
    ]

    private(set) var popular: [String] = []
    private(set) var all: [String] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var isLoading = false

    func load() {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
                .filter { !$0.hasPrefix(".") }
            let unique = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            await MainActor.run {
                let installed = Set(unique)
                self.popular = Self.curated.filter { installed.contains($0) }
                self.all = unique
                self.isLoaded = true
                self.isLoading = false
            }
        }
    }
}

/// Button showing the current family in its own face; opens a searchable list.
struct InspectorFontPicker: View {
    let family: String
    let select: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack {
                Text(family)
                    .font(.custom(family, size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isPresented ? Theme.accent : Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Font family")
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            InspectorFontList(current: family) { chosen in
                select(chosen)
                isPresented = false
            }
        }
        .onAppear { InspectorFontCatalog.shared.load() }
    }
}

/// Searchable list of font families: popular first, then everything installed.
struct InspectorFontList: View {
    let current: String
    let select: (String) -> Void
    @State private var query = ""
    private let catalog = InspectorFontCatalog.shared

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool = { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
        let popular = catalog.popular.filter(matches)
        let all = catalog.all.filter(matches)

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Search fonts", text: $query).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(8)
            .background(Theme.windowBackground)
            Divider()
            if !catalog.isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !popular.isEmpty {
                                header("Popular")
                                ForEach(popular, id: \.self) { row($0, id: "p-" + $0) }
                            }
                            header("All Fonts")
                            ForEach(all, id: \.self) { row($0, id: "a-" + $0) }
                            if popular.isEmpty && all.isEmpty {
                                Text("No matching fonts")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(12)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .onAppear {
                        if catalog.popular.contains(current) { proxy.scrollTo("p-" + current, anchor: .center) }
                        else { proxy.scrollTo("a-" + current, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 250, height: 380)
        .background(Theme.panelBackground)
        .onAppear { catalog.load() }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(_ family: String, id: String) -> some View {
        Button { select(family) } label: {
            HStack {
                Text(family).font(.custom(family, size: 14)).lineLimit(1)
                Spacer()
                if family == current {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(family == current ? Theme.accent.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
    }
}
