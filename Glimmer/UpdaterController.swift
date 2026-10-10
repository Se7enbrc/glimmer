// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if canImport(Sparkle)
import Sparkle
import SwiftUI

/// Owns Sparkle's standard updater and scheduler for both update menu commands.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController
    /// Retained here: Sparkle holds its user driver delegate weakly.
    private let streamAwareAlerts = StreamAwareUpdateAlerts(
        isStreaming: { AppDelegate.boundManager?.isStreaming ?? false },
        showUpdate: { UpdaterController.shared.updater.checkForUpdates() },
        checkInBackground: { UpdaterController.shared.updater.checkForUpdatesInBackground() })

    private init() {
        // The delegate chooses allowed channels; Sparkle compares monotonic bundle versions.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: streamAwareAlerts, userDriverDelegate: streamAwareAlerts)
        streamAwareAlerts.observeAvailability(of: controller.updater)
        // Default to daily checks, preserving any opt-out made in Sparkle's update alert.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            controller.updater.automaticallyChecksForUpdates = true
        }
        controller.updater.updateCheckInterval = 86_400
    }

    var updater: SPUUpdater { controller.updater }
}

/// Defers daily checks and update alerts so neither downloads nor pulls focus
/// during a stream. User-initiated checks pass through.
@MainActor
final class StreamAwareUpdateAlerts: NSObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let updateChannelPreferenceKey = "GlimmerUpdateChannel"

    private let isStreaming: @MainActor () -> Bool
    private let showUpdate: @MainActor () -> Void
    private let checkInBackground: @MainActor () -> Void
    private let updateDefaults: UserDefaults
    private(set) var isHoldingUpdate = false
    private var hasPendingBackgroundCheck = false
    private(set) var canCheckForUpdates = true
    private var availabilityObservation: NSKeyValueObservation?

    init(
        isStreaming: @escaping @MainActor () -> Bool,
        showUpdate: @escaping @MainActor () -> Void,
        checkInBackground: @escaping @MainActor () -> Void,
        updateDefaults: UserDefaults = .standard
    ) {
        self.isStreaming = isStreaming
        self.showUpdate = showUpdate
        self.checkInBackground = checkInBackground
        self.updateDefaults = updateDefaults
    }

    // Enrollment lives outside the signed bundle so RC promotion can preserve its exact bytes.
    var allowedUpdateChannels: Set<String> {
        updateDefaults.string(forKey: Self.updateChannelPreferenceKey) == "rc" ? ["rc"] : []
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { allowedUpdateChannels }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try mayPerform(updateCheck)
    }

    func observeAvailability(of updater: SPUUpdater) {
        availabilityObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.availabilityDidChange(updater.canCheckForUpdates)
            }
        }
    }

    func availabilityDidChange(_ canCheck: Bool) {
        canCheckForUpdates = canCheck
        // Sparkle can report availability before its scheduling callback ends.
        Task { @MainActor [weak self] in
            self?.runPendingActionsWhenStreamEnds()
        }
    }

    func mayPerform(_ updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updates {
            hasPendingBackgroundCheck = false
            return
        }
        guard updateCheck == .updatesInBackground, isStreaming() else { return }
        hasPendingBackgroundCheck = true
        runPendingActionsWhenStreamEnds()
        throw NSError(domain: "StreamAwareUpdateAlerts", code: 1)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        !isStreaming()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate { holdUntilStreamEnds() }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        isHoldingUpdate = false
    }

    func holdUntilStreamEnds() {
        Diag.info("update alert held until the stream ends", "Update")
        isHoldingUpdate = true
        runPendingActionsWhenStreamEnds()
    }

    private func runPendingActionsWhenStreamEnds() {
        guard isHoldingUpdate || hasPendingBackgroundCheck else { return }
        guard isStreaming() else {
            runPendingActions()
            return
        }
        // onChange fires before the new value lands; re-read it on the next turn.
        withObservationTracking { _ = isStreaming() } onChange: { [weak self] in
            Task { @MainActor in self?.runPendingActionsWhenStreamEnds() }
        }
    }

    private func runPendingActions() {
        if isHoldingUpdate {
            isHoldingUpdate = false
            showUpdate()
        }
        if hasPendingBackgroundCheck {
            guard !isStreaming(), canCheckForUpdates else { return }
            hasPendingBackgroundCheck = false
            checkInBackground()
        }
    }
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
