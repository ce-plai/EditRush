import SwiftUI

/// Shared dark "Rush-like" palette and metrics. All UI modules use these instead of literals.
enum Theme {
    static let windowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let panelBackground = Color(red: 0.15, green: 0.15, blue: 0.16)
    static let panelHeader = Color(red: 0.18, green: 0.18, blue: 0.19)
    static let raised = Color(red: 0.22, green: 0.22, blue: 0.23)
    static let divider = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.30, green: 0.56, blue: 1.00)
    static let playhead = Color(red: 1.00, green: 0.30, blue: 0.30)
    static let selection = Color(red: 1.00, green: 0.80, blue: 0.20)

    static let videoClip = Color(red: 0.24, green: 0.42, blue: 0.80)
    static let imageClip = Color(red: 0.50, green: 0.36, blue: 0.80)
    static let textClip = Color(red: 0.85, green: 0.50, blue: 0.22)
    static let audioClip = Color(red: 0.20, green: 0.62, blue: 0.45)

    static let trackHeaderWidth: CGFloat = 96
    static let videoTrackHeight: CGFloat = 64
    static let audioTrackHeight: CGFloat = 48
    static let rulerHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 6
}
