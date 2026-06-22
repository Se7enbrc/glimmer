//
//  ControllerForwarder+QuitChord.swift
//
//  Controller-side quit-chord matching, the hold-to-quit dwell, and the
//  shared held-buttons reader. Topic split from ControllerForwarder.swift
//  (file-length budget): the chord predicate, the dwell that makes the
//  "Hold to leave the stream" label honest, and the button-set helper are one
//  self-contained unit consumed by pushControllerState
//  (ControllerForwarder.swift) and the Settings capture sheet. Internal (not
//  private) is the split's access cost - the InputForwarder stored-property
//  note in ControllerForwarder.swift's header.
//

import GameController

extension InputForwarder {

    /// Returns true when the configured `ControllerQuitChord` is fully
    /// held on this gamepad. Treats triggers as digital (any pull ≥ 50%
    /// counts as a press) so the user doesn't have to slam them to fire
    /// the chord.
    func matchesControllerQuitChord(pad: GCExtendedGamepad) -> Bool {
        let chord = controllerQuitChordProvider()
        switch chord {
        case .none:
            return false
        case .startSelectL1R1:
            // Moonlight default: Start (Options ≡) + Select (Create/Share) +
            // both shoulders. On a DualSense the center buttons come from the
            // raw-HID reader (GameController drops them); on Xbox/MFi they come
            // from GameController. OR both so the chord works on either.
            let hid = DualSenseHID.shared.buttons
            let start = pad.buttonMenu.isPressed || hid.options
            let select = (pad.buttonOptions?.isPressed ?? false) || hid.create
            return start && select
                && pad.leftShoulder.isPressed && pad.rightShoulder.isPressed
        case .l1r1:
            return pad.leftShoulder.isPressed && pad.rightShoulder.isPressed
        case .l1r1l2r2:
            return pad.leftShoulder.isPressed && pad.rightShoulder.isPressed
                && pad.leftTrigger.value >= 0.5 && pad.rightTrigger.value >= 0.5
        case .l3r3:
            return (pad.leftThumbstickButton?.isPressed ?? false)
                && (pad.rightThumbstickButton?.isPressed ?? false)
        case .custom:
            let custom = customControllerChordProvider()
            return !custom.isEmpty && custom.isSubset(of: heldControllerButtons(pad: pad))
        }
    }

    /// One-time guard for the raw-HID-needed warning below.
    nonisolated(unsafe) static var warnedQuitChordNeedsRawHID = false

    /// True iff the configured quit chord depends on a DualSense centre button
    /// GameController DROPS (Create / Mute) - so it cannot fire on a DualSense
    /// without the raw-HID reader. Options has a `buttonMenu` fallback and PS a
    /// `buttonHome` one (both GameController-native), and every other chord button
    /// is GameController-native too - only Create (`buttonOptions`, dropped) and
    /// Mute (no GC element at all) are raw-HID-only. Used to surface the silent
    /// "quit chord never fires on DualSense because raw-HID is off" failure.
    func quitChordNeedsRawHIDCenterButtons() -> Bool {
        switch controllerQuitChordProvider() {
        case .startSelectL1R1:
            return true   // "select" maps to Create, which GameController drops on DualSense
        case .custom:
            return !customControllerChordProvider().isDisjoint(with: [.create, .mute])
        case .none, .l1r1, .l1r1l2r2, .l3r3:
            return false
        }
    }

    // MARK: - Hold-to-quit dwell

    /// How long the chord must stay FULLY held before the stream ends. The
    /// Settings picker is labeled "Hold to leave the stream" and its footnote
    /// says "Hold these buttons simultaneously..." - the mechanism has to honour
    /// that promise. Without a dwell the chord fired on the FIRST coincident
    /// frame, so with the .l1r1 option any in-game moment where both
    /// shoulders happened to be pressed together killed the session with zero
    /// grace. 400ms is far longer than a combat-coincidence chord survives
    /// (those release within a frame or two) and short enough that a
    /// deliberate hold still feels immediate.
    static let quitChordDwellSeconds: Double = 0.4

    /// Start (or keep) the dwell countdown for a fully-held chord on `slot`.
    /// GameController only fires the valueChangedHandler on CHANGES - a chord
    /// held perfectly still after the matching frame produces no further
    /// frames - so the dwell must complete on its own timer, re-reading the
    /// LIVE pad state at expiry rather than trusting the arming frame.
    func armQuitChordDwell(pad: GCExtendedGamepad, slot: UInt8) {
        guard quitChordDwellTask == nil else { return }   // already counting
        quitChordDwellSlot = slot
        log.info("Controller quit chord held - dwell started (\(Int(Self.quitChordDwellSeconds * 1000), privacy: .public)ms)")
        // Task inherits MainActor isolation from this context, so touching the
        // forwarder's stored state after the sleep is sound. `pad` is weak: a
        // disconnect mid-dwell must not extend the profile's lifetime (and
        // detach(gamepad:) cancels the dwell for the arming slot anyway).
        quitChordDwellTask = Task { [weak self, weak pad] in
            try? await Task.sleep(nanoseconds: UInt64(Self.quitChordDwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let pad else { return }
            self.quitChordDwellTask = nil
            self.quitChordDwellSlot = nil
            // Re-verify against the live profile at expiry: isPressed/value
            // read current hardware state, so a release that produced no
            // further value-changed frame still reads released here. isReady
            // guards the shutdown race - detach() cancels this task, but a
            // teardown that races the wakeup must not quit a dead session.
            guard self.isReady, self.matchesControllerQuitChord(pad: pad) else { return }
            self.log.info("Controller quit chord held through dwell - invoking onQuitHotkey")
            Diag.notice("controller quit chord held - ending stream", "Controller")
            self.onQuitHotkey?()
        }
    }

    /// Cancel an in-flight dwell (chord released early, arming pad detached,
    /// or session teardown). Safe to call with none pending.
    func cancelQuitChordDwell() {
        quitChordDwellTask?.cancel()
        quitChordDwellTask = nil
        quitChordDwellSlot = nil
    }
}

/// The set of buttons currently held on a gamepad, used both to match a
/// recorded `.custom` chord (ControllerForwarder) and to drive the Settings
/// capture sheet. Reads GameController plus the DualSense raw-HID
/// center buttons - the same sources `sendGamepadUpdate` forwards. Free
/// function (not an InputForwarder method) so the Settings capture sheet, which
/// has no live stream, can call it too.
func heldControllerButtons(pad: GCExtendedGamepad) -> Set<ControllerButton> {
    // Compute the composite (HID + GameController) bools first, then a flat
    // table-driven fold - keeps this off the cyclomatic-complexity radar a
    // 19-way if-chain would trip.
    let hid = DualSenseHID.shared.buttons
    let touchpadHeld = ((pad as? GCDualSenseGamepad)?.touchpadButton
        ?? (pad as? GCDualShockGamepad)?.touchpadButton)?.isPressed == true
    let optionsHeld = hid.options || pad.buttonMenu.isPressed
    let createHeld = hid.create || (pad.buttonOptions?.isPressed ?? false)
    let psHeld = hid.ps || (pad.buttonHome?.isPressed ?? false)
    let mapping: [(Bool, ControllerButton)] = [
        (pad.buttonA.isPressed, .faceDown),
        (pad.buttonB.isPressed, .faceRight),
        (pad.buttonX.isPressed, .faceLeft),
        (pad.buttonY.isPressed, .faceUp),
        (pad.dpad.up.isPressed, .dpadUp),
        (pad.dpad.down.isPressed, .dpadDown),
        (pad.dpad.left.isPressed, .dpadLeft),
        (pad.dpad.right.isPressed, .dpadRight),
        (pad.leftShoulder.isPressed, .l1),
        (pad.rightShoulder.isPressed, .r1),
        (pad.leftTrigger.value >= 0.5, .l2),
        (pad.rightTrigger.value >= 0.5, .r2),
        (pad.leftThumbstickButton?.isPressed == true, .l3),
        (pad.rightThumbstickButton?.isPressed == true, .r3),
        (touchpadHeld, .touchpad),
        (optionsHeld, .options),
        (createHeld, .create),
        (psHeld, .ps),
        (hid.mute, .mute)
    ]
    var held: Set<ControllerButton> = []
    for (pressed, button) in mapping where pressed { held.insert(button) }
    return held
}
