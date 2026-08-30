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
        // PRESCRIPTIVE nag policy (2026-08-26). Previously nothing set a check
        // schedule: Sparkle's own opt-in prompt decided whether SCHEDULED
        // checks ever ran, and the only forced check fired on a user-initiated
        // OPEN - which a Glimmer that sits running for days never triggers, so
        // multi-day sessions rode releases behind without a single nag (a
        // 3-day 2026.8.11 process ran through the .12 release unprompted).
        // Now: automatic checks ON BY DEFAULT, DAILY. Sparkle's standard driver
        // shows the update alert whenever a scheduled or launch check finds one
        // - that alert IS the nag, at startup (first scheduled check fires
        // shortly after launch, and the on-open background check in GlimmerApp
        // still forces one per open) and every 24h of uptime thereafter.
        //
        // DEFAULT, not policy: the write is gated on Sparkle's own persisted
        // key being ABSENT. Setting it unconditionally re-enabled automatic
        // checks on every launch, so a user who turned them off in the update
        // alert's own UI had that choice reverted by the next start - the
        // opt-out we promise was silently a no-op. Absent key = the user has
        // never decided, so we decide for them (on); present = their answer,
        // whichever way it goes, and we leave it alone.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            controller.updater.automaticallyChecksForUpdates = true
        }
        controller.updater.updateCheckInterval = 86_400
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

/// The "Check for Updates…" menu command. Disables itself mid-check via the
/// observed `UpdateAvailability` (a plain Button can't reflect that state).
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var availability: UpdateAvailability

    init(updater: SPUUpdater) {
        self.updater = updater
        _availability = State(initialValue: UpdateAvailability(updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!availability.canCheckForUpdates)
    }
}
#endif
