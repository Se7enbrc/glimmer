#if canImport(Sparkle)
import Sparkle
import SwiftUI

/// Owns the Sparkle updater for the app's lifetime. `SPUStandardUpdaterController`
/// wires the standard user driver (the "update available" / progress panels) and
/// starts the background update scheduler. One shared instance, reached from both
/// the app-menu command and the menu-bar dropdown.
///
/// The whole file is gated on `canImport(Sparkle)` so Glimmer still builds before
/// the Sparkle SPM package is linked - the updater and its menu items simply don't
/// exist until the package is added. Feed URL + ed25519 public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey); updates are published prompt-free by
/// `make release-publish`.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        // Auto-update IS the release channel. No build-type gating needed:
        // Sparkle only offers an update when the appcast's build number is
        // STRICTLY greater than the running build's. So a dev build OLDER than a
        // release grabs it, and a dev build at/after the latest release stays
        // silent until the next one - exactly the desired behavior, for free.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }
}

/// Tracks Sparkle's KVO-observable `canCheckForUpdates` as Observation-tracked
/// state so the menu command can grey out while a check is already running.
/// Modern Observation + `NSKeyValueObservation` - no Combine, matching the app's
/// `@Observable` model style.
@MainActor
@Observable
final class UpdateAvailability {
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(_ updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // Sparkle posts this KVO change on the main thread; assert it so the
            // @MainActor reads/writes are isolation-clean without a Task hop.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }
}

/// The "Check for Updates..." menu command. Disables itself mid-check via the
/// observed `UpdateAvailability` (a plain Button can't reflect that state).
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var availability: UpdateAvailability

    init(updater: SPUUpdater) {
        self.updater = updater
        _availability = State(initialValue: UpdateAvailability(updater))
    }

    var body: some View {
        Button("Check for Updates...") { updater.checkForUpdates() }
            .disabled(!availability.canCheckForUpdates)
    }
}
#endif
