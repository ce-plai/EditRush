import SwiftUI
import EditRushCore

/// Long-lived app objects shared by every view (inject with `.environment(...)`).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let store: EditorStore
    let playback: PlaybackController
    let exporter: Exporter
    /// True when running `--snapshot` (views must not depend on live AVPlayer layers / windows).
    var isSnapshotMode = false

    private init() {
        store = EditorStore()
        playback = PlaybackController(store: store)
        exporter = Exporter()
    }
}

extension View {
    /// Injects all shared app objects.
    @MainActor func appEnvironment(_ env: AppEnvironment? = nil) -> some View {
        let env = env ?? .shared
        return self.environment(env.store)
            .environment(env.playback)
            .environment(env.exporter)
            .environment(ThumbnailCache.shared)
            .environment(WaveformCache.shared)
    }
}
