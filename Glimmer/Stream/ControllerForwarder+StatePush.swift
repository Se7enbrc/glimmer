// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// GameController owns full snapshots; raw HID contributes centre-button edges without repeating touch.

import AppKit
import Foundation
import GameController

extension InputForwarder {

    var forwardsControllerEvents: Bool {
        isReady && (isMiniPlayer || window?.isKeyWindow != false)
    }

    func updateControllerBackgroundEvents() {
        ControllerBackgroundEvents.setEnabled(isMiniPlayer && isReady, for: controllerBackgroundEventsID)
        ControllerHaptics.shared.setBackgroundPlayEnabled(isMiniPlayer && isReady,
                                                          for: controllerBackgroundEventsID)
        for state in attachedControllers.values {
            ControllerMotion.shared.setInputEnabled(
                forwardsControllerEvents && controllerMouseStates[state.slot]?.isMouse != true, slot: state.slot)
        }
    }

    // MARK: - Per-frame state push

    /// Only GameController snapshots own the surface, so centre-button edges cannot double-feed touch.
    func sendGamepadUpdate(pad: GCExtendedGamepad, slot: UInt8,
                           touchpadUpdate: (@MainActor () -> Void)? = nil) {
        guard pushControllerState(pad: pad, slot: slot) else { return }
        if let touchpadUpdate { touchpadUpdate() } else { forwardTouchpad(pad: pad, slot: slot) }
    }

    /// Raw-HID centre and shoulder edges re-run the chord check when GameController is late or silent.
    /// Axes still come from GameController; the batcher merges them without repeating surface events.
    func sendCenterButtonUpdate(pad: GCExtendedGamepad, slot: UInt8) {
        let pushed = pushControllerState(pad: pad, slot: slot)
        // Keep the rate-limited partial-hold breadcrumb: it identifies which centre button never registered.
        guard pushed, controllerMouseStates[slot]?.isMouse != true, quitChordUsesCentreButtons() else { return }
        let hid = dualSenseButtons(pad: pad)
        if hid.options || hid.create {
            quitChordBreadcrumb(.partial, "partial hold on slot \(slot)", pad: pad)
        }
    }

    /// Only the GameController frame owns touchpad forwarding, so centre-button edges cannot double-feed it.
    /// Returns false when input is gated or the quit chord is held; mouse mode still needs the surface.
    @discardableResult
    private func pushControllerState(pad: GCExtendedGamepad, slot: UInt8) -> Bool {
        guard forwardsControllerEvents else { return false }
        let buttons = pressedButtonFlags(pad: pad)

        // The chord ends the stream only after the hold dwell (ControllerForwarder+QuitChord.swift),
        // so an in-game overlap can't. Frames holding it stay off the PC, or the game would act on
        // those buttons for the whole hold.
        let analog = controllerAnalog(pad)
        let chordHeld = matchesControllerQuitChord(pad: pad, buttons: buttons)
        let isMouse = routeControllerMouse(slot: slot, buttons: buttons, analog: analog, chordHeld: chordHeld)
        if chordHeld {
            armQuitChordDwell(pad: pad, slot: slot)
            // No frame is enqueued, so its stamp must not age into the next push.
            _ = InputDeliverStamp.shared.take(slot: Int(slot))
            return false
        }
        // Released before the dwell elapsed (or never held): an in-game
        // button coincidence, not a quit. Only the arming pad's frames may
        // cancel - another pad's traffic says nothing about the holder.
        if quitChordDwellSlot == slot {
            cancelQuitChordDwell(reason: "released before the dwell elapsed", pad: pad)
        }

        guard !isMouse else {
            _ = InputDeliverStamp.shared.take(slot: Int(slot))
            return true
        }
        let mapped = ControllerButtonLayout.apply(
            buttons, useNintendoLabels: useNintendoLabels && nintendoControllerTypes[slot] != nil)
        let rc = backend?.sendMultiController(
            num: Int16(slot), mask: Int16(bitPattern: gamepadMask), buttons: mapped, analog: analog
        ) ?? -2
        record("LiSendMultiControllerEvent", rc)
        return true
    }

    private func controllerAnalog(_ pad: GCExtendedGamepad) -> GamepadAnalog {
        let lt = UInt8((pad.leftTrigger.value * 255).rounded().clamped(to: 0...255))
        let rt = UInt8((pad.rightTrigger.value * 255).rounded().clamped(to: 0...255))
        let lx = Int16((pad.leftThumbstick.xAxis.value * 32767).rounded().clamped(to: -32768...32767))
        let ly = Int16((pad.leftThumbstick.yAxis.value * 32767).rounded().clamped(to: -32768...32767))
        let rx = Int16((pad.rightThumbstick.xAxis.value * 32767).rounded().clamped(to: -32768...32767))
        let ry = Int16((pad.rightThumbstick.yAxis.value * 32767).rounded().clamped(to: -32768...32767))
        return GamepadAnalog(leftTrigger: lt, rightTrigger: rt, leftStickX: lx, leftStickY: ly,
                             rightStickX: rx, rightStickY: ry)
    }

    /// The host button bitmask for a gamepad's current state. Table-driven so
    /// the full button map lives in one declarative place (and a flat fold
    /// keeps it off the cyclomatic-complexity radar that a 17-way if-chain
    /// trips). The DualSense/DualShock touchpad *click* rides here as
    /// TOUCHPAD_FLAG (Sunshine's touchpad button); the touchpad *surface* is
    /// forwarded separately as touch events.
    func pressedButtonFlags(pad: GCExtendedGamepad) -> Int32 {
        let mapping: [(Bool, Int32)] = [
            (pad.buttonA.isPressed, StreamProtocol.A_FLAG),
            (pad.buttonB.isPressed, StreamProtocol.B_FLAG),
            (pad.buttonX.isPressed, StreamProtocol.X_FLAG),
            (pad.buttonY.isPressed, StreamProtocol.Y_FLAG),
            (pad.dpad.up.isPressed, StreamProtocol.UP_FLAG),
            (pad.dpad.down.isPressed, StreamProtocol.DOWN_FLAG),
            (pad.dpad.left.isPressed, StreamProtocol.LEFT_FLAG),
            (pad.dpad.right.isPressed, StreamProtocol.RIGHT_FLAG),
            (pad.leftShoulder.isPressed, StreamProtocol.LB_FLAG),
            (pad.rightShoulder.isPressed, StreamProtocol.RB_FLAG),
            (pad.leftThumbstickButton?.isPressed == true, StreamProtocol.LS_CLK_FLAG),
            (pad.rightThumbstickButton?.isPressed == true, StreamProtocol.RS_CLK_FLAG),
            (pad.buttonOptions?.isPressed == true, StreamProtocol.BACK_FLAG),
            (pad.buttonMenu.isPressed, StreamProtocol.PLAY_FLAG),
            (pad.buttonHome?.isPressed == true, StreamProtocol.SPECIAL_FLAG),
            (touchpadElements(of: pad)?.button.isPressed == true, StreamProtocol.TOUCHPAD_FLAG),
            // Xbox Share/Capture → MISC_FLAG (the spare misc/touchpad-button
            // host slot; same slot the DualSense Mute uses below). nil/false on
            // any pad without an Xbox Share button, so the OR is additive.
            (xboxShareButton(of: pad)?.isPressed == true, StreamProtocol.MISC_FLAG)
        ]
        var buttons: Int32 = 0
        for (pressed, flag) in mapping where pressed { buttons |= flag }

        // DualSense Options / Create / PS / Mute come from the raw-HID
        // side-channel (GameController doesn't deliver them). The GC-mapped
        // buttonMenu/buttonOptions/buttonHome above stay false on a DualSense,
        // so this OR is purely additive (and the same flags work for Xbox via
        // GameController). Mapped to the host's semantics: Options → Start,
        // Create/Share → Back, PS → Guide, Mute → misc.
        if pad is GCDualSenseGamepad {
            let hid = dualSenseButtons(pad: pad)
            if hid.options { buttons |= StreamProtocol.PLAY_FLAG }
            if hid.create { buttons |= StreamProtocol.BACK_FLAG }
            if hid.ps { buttons |= StreamProtocol.SPECIAL_FLAG }
            if hid.mute { buttons |= StreamProtocol.MISC_FLAG }
        }
        return buttons
    }

    // MARK: - Focus loss

    /// The all-zero analog state a removal and a focus-loss release both send.
    static let neutralControllerAnalog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                                       leftStickX: 0, leftStickY: 0,
                                                       rightStickX: 0, rightStickY: 0)

    /// Release every pad when focus leaves ordinary playback; Mini Player keeps its controller ownership.
    func neutralizeControllers() {
        guard isReady else { return }
        releaseControllerTouches()
        suspendControllerMouse()
        for state in attachedControllers.values {
            ControllerMotion.shared.setInputEnabled(false, slot: state.slot)
        }
        let slots = attachedControllers.values.map(\.slot) + attachedHIDControllers.values.map(\.slot)
        for slot in slots {
            let rc = backend?.sendMultiController(
                num: Int16(slot), mask: Int16(bitPattern: gamepadMask),
                buttons: 0, analog: Self.neutralControllerAnalog
            ) ?? -2
            record("LiSendMultiControllerEvent(focus loss)", rc)
        }
        if !slots.isEmpty {
            Diag.info("input: released \(slots.count) controller(s) on focus loss", "Stream")
        }
    }
}

// MARK: - Local numeric helper

// File-local clamp helper. A fileprivate extension can't be shared across files,
// and promoting it to internal would leak the helper across the whole target, so
// each file that needs it keeps a tight local copy.
fileprivate extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
