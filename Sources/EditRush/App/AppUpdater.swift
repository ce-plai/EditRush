import SwiftUI
import Combine
import Sparkle

/// Sparkle auto-updates. Only runs in a bundled build whose Info.plist names a feed
/// (`Scripts/build_app.sh` adds `SUFeedURL` / `SUPublicEDKey`), so `swift run` never checks.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController?

    var updater: SPUUpdater? { controller?.updater }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}

/// "Check for Updates…" in the app menu; enabled while Sparkle isn't already mid-check.
struct CheckForUpdatesMenuItem: View {
    let updater: SPUUpdater
    @StateObject private var state: UpdaterState

    init(updater: SPUUpdater) {
        self.updater = updater
        _state = StateObject(wrappedValue: UpdaterState(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!state.canCheckForUpdates)
    }
}

@MainActor
private final class UpdaterState: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
