// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

@MainActor
private enum HIDDiscoveryState {
    static var holders: Set<AppModel.HIDVisibilityHolder> = []
}

extension AppModel {

    /// What the DualSense offer says, before macOS's prompt or, once macOS has an answer,
    /// before System Settings.
    static func rawHIDExplanation(_ access: InputMonitoring.State) -> String {
        "Glimmer will read your DualSense's raw input to access the Options, "
            + "Create and Mute buttons.\n\n" + permissionNote(access)
    }

    /// The prompt says “keystrokes” because Input Monitoring is one permission for both.
    private static func permissionNote(_ access: InputMonitoring.State) -> String {
        access == .denied
            ? "Turn on Glimmer in System Settings › Privacy & Security › Input Monitoring. "
                + "Glimmer only reads the controller, never your keyboard."
            : "macOS will then ask for \u{201C}Input Monitoring\u{201D} permission. Its dialog says "
                + "\u{201C}keystrokes\u{201D} because that's the same system permission, "
                + "but Glimmer only reads the controller, never your keyboard."
    }

    /// Offer the raw-HID feature if a DualSense is connected and the user
    /// hasn't enabled it or been asked. Never interrupts a live stream.
    func maybeOfferRawHID() {
        guard !rawHIDControllerEnabled, !rawHIDPromptAnswered, !isStreaming, !showRawHIDPrompt else { return }
        let hasDualSense = GCController.controllers().contains { $0.productCategory == GCProductCategoryDualSense }
        if hasDualSense { showRawHIDPrompt = true }
    }

    /// "Turn On" from the auto-offer. The offer only shows in the launcher, never mid-stream,
    /// so asking here can't stall a stream; the request itself runs off main.
    func enableRawHIDFromPrompt() {
        rawHIDControllerEnabled = true
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
        InputMonitoring.ask()
    }

    /// "Don't Ask Again" from the auto-offer: never offer proactively again.
    func declineRawHIDPrompt() {
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }

    // MARK: Generic HID pads

    enum HIDVisibilityHolder: Hashable {
        case launcher, menuBar
    }

    /// Keep discovery alive only while a surface that lists or offers pads is shown.
    func setHIDDiscovery(_ shown: Bool, for holder: HIDVisibilityHolder) {
        if shown {
            if HIDDiscoveryState.holders.insert(holder).inserted { HIDGamepadManager.shared.retain(reading: false) }
        } else if HIDDiscoveryState.holders.remove(holder) != nil {
            HIDGamepadManager.shared.release(reading: false)
        }
    }

    static func hidPermissionExplanation(_ access: InputMonitoring.State) -> String {
        "macOS doesn't recognise this controller on its own, so Glimmer reads it "
            + "directly.\n\n" + permissionNote(access)
    }

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

    func continueHIDPermission() {
        answerHIDPermission(dontAskAgain: false)
        InputMonitoring.ask()
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
