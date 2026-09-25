//
//  ControllerForwarder+StatePush.swift
//
//  The PER-FRAME state push: the two entry points that carry a gamepad frame to
//  the host (the GameController `valueChangedHandler` full-state forward and the
//  raw-HID centre-button side-channel), the shared builder they both run, and
//  the table-driven button bitmask. Split from ControllerForwarder.swift - same
//  idiom as the ControllerForwarder+QuitChord split, to keep that file under the
//  length limit; the attach/detach/arrival lifecycle stays there. Stored state
//  (`gamepadMask`, the quit-chord dwell fields) lives on `InputForwarder`
//  proper, so the methods here rely on default `internal` access to it.
//

import Foundation
import GameController

extension InputForwarder {

    // MARK: - Per-frame state push

    /// FULL-state push from the GameController valueChangedHandler - the SINGLE
    /// source of truth for sticks/triggers/face buttons/touchpad. Pushes the
    /// merged multiController state AND forwards the touchpad surface.
    func sendGamepadUpdate(pad: GCExtendedGamepad, slot: UInt8) {
        guard pushControllerState(pad: pad, slot: slot) else { return }
        // Forward the touchpad surface (finger contacts) as host touch events.
        // ONLY from this GameController path - touchpad data comes through
        // GameController, so the raw-HID center-button path must NOT re-run this
        // (it would emit redundant touch pass-through events, an amplifier).
        forwardTouchpad(pad: pad, slot: slot)
    }

    /// Raw-HID side-channel update: fired ONLY when a decoded DualSense bit
    /// changed - a center button (Options/Create/PS/Mute) or, for the quit chord,
    /// a shoulder (DualSenseHID gates onChange on a real bit change). GameController
    /// never delivers the center buttons and does NOT fire its valueChangedHandler
    /// for them, so this push is necessary to carry a center-button edge to the
    /// host - but it does NOT re-forward the touchpad (that stays on the
    /// GameController path) and the InputBatcher coalesces it with the latest
    /// GC-sourced axes for the slot, so it is not a double-feed of stick/axis
    /// state. A shoulder edge here re-pushes the same GC-sourced state (the host
    /// L1/R1 still come from GameController); its purpose is to re-run the chord
    /// check so a chord completed by a shoulder arms even if GameController's
    /// frame for it is late or withheld.
    func sendCenterButtonUpdate(pad: GCExtendedGamepad, slot: UInt8) {
        let pushed = pushControllerState(pad: pad, slot: slot)
        // Partial-hold breadcrumb: a centre button is down, the chord needs
        // centre buttons, and the chord did NOT match on this edge (a match
        // returns false from the push, having armed the dwell). This is the
        // line that makes "I held all four and nothing happened" diagnosable:
        // it names which of the four never registered. Edge-only + rate-limited.
        guard pushed, quitChordUsesCentreButtons() else { return }
        let hid = dualSenseButtons(pad: pad)
        if hid.options || hid.create {
            quitChordBreadcrumb(.partial, "partial hold on slot \(slot)", pad: pad)
        }
    }

    /// Build + push the current multiController state for `slot`. Returns false if
    /// the push was short-circuited (not ready, or the quit chord fired). The
    /// touchpad surface is NOT forwarded here - callers that own the GameController
    /// frame do that separately.
    @discardableResult
    private func pushControllerState(pad: GCExtendedGamepad, slot: UInt8) -> Bool {
        guard isReady else { return false }
        let buttons = pressedButtonFlags(pad: pad)

        // The chord ends the stream only after the hold dwell (ControllerForwarder+QuitChord.swift),
        // so an in-game overlap can't. Frames holding it stay off the PC, or the game would act on
        // those buttons for the whole hold.
        if matchesControllerQuitChord(pad: pad, buttons: buttons) {
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

        let lt = UInt8((pad.leftTrigger.value  * 255).rounded().clamped(to: 0...255))
        let rt = UInt8((pad.rightTrigger.value * 255).rounded().clamped(to: 0...255))
        let lx = Int16((pad.leftThumbstick.xAxis.value  * 32767).rounded().clamped(to: -32768...32767))
        let ly = Int16((pad.leftThumbstick.yAxis.value  * 32767).rounded().clamped(to: -32768...32767))
        let rx = Int16((pad.rightThumbstick.xAxis.value * 32767).rounded().clamped(to: -32768...32767))
        let ry = Int16((pad.rightThumbstick.yAxis.value * 32767).rounded().clamped(to: -32768...32767))

        let rc = backend?.sendMultiController(
            num: Int16(slot),
            mask: Int16(bitPattern: gamepadMask),
            buttons: buttons,
            analog: GamepadAnalog(leftTrigger: lt, rightTrigger: rt,
                                  leftStickX: lx, leftStickY: ly,
                                  rightStickX: rx, rightStickY: ry)
        ) ?? -2
        record("LiSendMultiControllerEvent", rc)
        return true
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

    /// GameController stops delivering once the app is in the background, so a held stick or
    /// trigger would stay held on the PC. resyncControllers restores live state on refocus;
    /// generic HID pads keep delivering, so they are left alone.
    func neutralizeControllers() {
        guard isReady else { return }
        for state in attachedControllers.values {
            let rc = backend?.sendMultiController(
                num: Int16(state.slot), mask: Int16(bitPattern: gamepadMask),
                buttons: 0, analog: Self.neutralControllerAnalog
            ) ?? -2
            record("LiSendMultiControllerEvent(focus loss)", rc)
        }
        if !attachedControllers.isEmpty {
            Diag.info("input: released \(attachedControllers.count) controller(s) on focus loss", "Stream")
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
