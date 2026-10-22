import AppKit

/// The standard About panel with EditRush's credits under the version.
@MainActor
enum AboutPanel {
    static let credits = """
    created by pl.ai

    windows port by Pete Baron
    motivational cheerleading by happylander

    thanks to the board + Alex Meckes
    """

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "EditRush", .credits: text])
        NSApp.activate()
    }
}
