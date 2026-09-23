//
//  AppModel+RawHID.swift
//
//  The raw-HID DualSense auto-offer: the up-front explanation and the three
//  entry points the launcher's offer alert drives. Pure move out of
//  AppModel.swift (which holds the stored `rawHID*` flags these read) to keep
//  the class core under the file-length limit; behavior is unchanged.
//

import Foundation
import GameController
import IOKit.hid

extension AppModel {

    /// Shared up-front explanation shown before macOS's Input Monitoring prompt
    /// (both the auto-offer on DualSense connect and the Settings toggle).
    static let rawHIDExplanation =
        "Glimmer will read your DualSense's raw input to access the Options, "
        + "Create and Mute buttons.\n\nmacOS will then ask for "
        + "\u{201C}Input Monitoring\u{201D} permission. Its dialog says "
        + "\u{201C}keystrokes\u{201D} because that's the same system permission, "
        + "but Glimmer only reads the controller, never your keyboard."

    /// Offer the raw-HID feature if a DualSense is connected and the user
    /// hasn't enabled it or been asked. Never interrupts a live stream.
    func maybeOfferRawHID() {
        guard !rawHIDControllerEnabled, !rawHIDPromptAnswered, !isStreaming, !showRawHIDPrompt else { return }
        let hasDualSense = GCController.controllers().contains { $0.productCategory == GCProductCategoryDualSense }
        if hasDualSense { showRawHIDPrompt = true }
    }

    /// "Turn On" from the auto-offer: turn it on and mark answered. We do NOT
    /// request the Input Monitoring permission or open System Settings here:
    ///   * `IOHIDRequestAccess` is SYNCHRONOUS and blocks the main thread for
    ///     ~2s while presenting/resolving the TCC prompt; on a live stream that
    ///     stalls the present path and trips the present-stall watchdog (which
    ///     disables the pacer). See DualSenseHID.start()'s note.
    ///   * `NSWorkspace.open(Privacy_ListenEvent)` flashes a System Settings
    ///     window - jarring mid-game.
    /// Both belong only behind an explicit user action in Settings (the
    /// Troubleshooting "Open Settings" button, `RawHIDControl.registerAndOpen`),
    /// off the main thread. Flipping the flag is enough: if the permission is
    /// already granted the raw-HID reader attaches silently via
    /// `ControllerForwarder` (mid-stream) / the input test; if it isn't, the
    /// Troubleshooting pane's permission card guides the user there on their own
    /// schedule. The proactive offer itself is `!isStreaming`-gated
    /// (`maybeOfferRawHID`), so this only runs from the launcher anyway - but we
    /// keep it side-effect-free so it can never block or pop a window.
    func enableRawHIDFromPrompt() {
        rawHIDControllerEnabled = true
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }

    /// "Don't Ask Again" from the auto-offer: never offer proactively again.
    func declineRawHIDPrompt() {
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }

    // MARK: Generic HID pads

    static let hidPermissionExplanation =
        "macOS doesn't recognise this controller on its own, so Glimmer reads it "
        + "directly.\n\nmacOS will ask for \u{201C}Input Monitoring\u{201D} "
        + "permission. Its dialog says \u{201C}keystrokes\u{201D} because that's "
        + "the same system permission, but Glimmer only reads the controller, "
        + "never your keyboard."

    /// Answers to the generic-pad offer; process lifetime is "until relaunch".
    static var hidPermissionOffers = HIDPermissionOffers()

    var hidPermissionPadName: String? { hidPermissionPad?.name }

    /// A generic pad attached without the permission. Offered from the launcher
    /// only; a pad seen mid-stream is offered when the stream ends.
    func hidPadNeedsPermission(_ pad: HIDGamepadDevice) {
        guard Self.hidPermissionOffers.shouldOffer(pad.hardwareID) else { return }
        hidPermissionPad = pad
        maybeOfferHIDPermission()
    }

    func maybeOfferHIDPermission() {
        guard !isStreaming, hidPermissionPad != nil, !HIDGamepadManager.accessGranted else { return }
        showHIDPermissionPrompt = true
    }

    /// "Continue": the system prompt blocks its thread for a moment, so it
    /// runs off main. A grant re-opens the pads; a refusal opens the pane.
    func continueHIDPermission() {
        answerHIDPermission(dontAskAgain: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            DispatchQueue.main.async {
                if granted { HIDGamepadManager.shared.reopenAll() } else { RawHIDControl.openInputMonitoring() }
            }
        }
    }

    /// "Not Now": skip this pad until relaunch.
    func dismissHIDPermission() { answerHIDPermission(dontAskAgain: false) }

    /// "Don't Ask Again": skip this pad for good.
    func declineHIDPermission() { answerHIDPermission(dontAskAgain: true) }

    private func answerHIDPermission(dontAskAgain: Bool) {
        if let pad = hidPermissionPad { Self.hidPermissionOffers.answer(pad.hardwareID, dontAskAgain: dontAskAgain) }
        showHIDPermissionPrompt = false
        hidPermissionPad = nil
    }
}

/// Which generic pads the Input Monitoring offer skips, by hardware ID: any
/// answer skips a pad until relaunch, and Don't Ask Again is kept in defaults.
struct HIDPermissionOffers {
    static let declinedKey = "hidPermissionDeclinedPads"
    var defaults = UserDefaults.standard
    private(set) var answered: Set<String> = []

    func shouldOffer(_ hardwareID: String) -> Bool {
        !answered.contains(hardwareID) && !declined.contains(hardwareID)
    }

    mutating func answer(_ hardwareID: String, dontAskAgain: Bool) {
        answered.insert(hardwareID)
        if dontAskAgain { defaults.set(declined.union([hardwareID]).sorted(), forKey: Self.declinedKey) }
    }

    private var declined: Set<String> { Set(defaults.stringArray(forKey: Self.declinedKey) ?? []) }
}
