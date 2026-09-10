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

extension AppModel {

    /// Shared up-front explanation shown before macOS's Input Monitoring prompt
    /// (both the auto-offer on DualSense connect and the Settings toggle).
    static let rawHIDExplanation =
        "Glimmer will read your DualSense's raw input to access the Options, "
        + "Create/Share, and Mute buttons.\n\nmacOS will then ask for "
        + "\u{201C}Input Monitoring\u{201D} permission. Its dialog says "
        + "\u{201C}keystrokes\u{201D} because that's the same system permission "
        + "- but Glimmer only reads the controller, never your keyboard."

    /// Offer the raw-HID feature if a DualSense is connected and the user
    /// hasn't enabled it or been asked. Never interrupts a live stream.
    func maybeOfferRawHID() {
        guard !rawHIDControllerEnabled, !rawHIDPromptAnswered, !isStreaming, !showRawHIDPrompt else { return }
        let hasDualSense = GCController.controllers().contains { $0.productCategory == GCProductCategoryDualSense }
        if hasDualSense { showRawHIDPrompt = true }
    }

    /// "Enable" from the auto-offer: turn it on and mark answered. We do NOT
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

    /// "Cancel" from the auto-offer: don't ask again proactively.
    func declineRawHIDPrompt() {
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }
}
