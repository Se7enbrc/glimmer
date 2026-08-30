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

    /// Returns true when the configured `ControllerQuitChord` is fully held on
    /// this gamepad. ONE definition of "held" for every chord and every button:
    /// `heldControllerButtons`, which ORs GameController with the DualSense
    /// raw-HID bits for each button the raw report carries - the centre buttons
    /// AND both shoulders. The previous predicate spliced raw-HID Options/Create
    /// onto GameController's L1/R1, two sources that disagree in time and that
    /// GameController can withhold around a bound system gesture, so a chord the
    /// user was physically holding could read as not-held. Triggers are digital
    /// here (any pull ≥ 50% counts) so the user doesn't have to slam them.
    func matchesControllerQuitChord(pad: GCExtendedGamepad) -> Bool {
        let chord = controllerQuitChordProvider()
        guard chord != .none else { return false }   // no set to build on the hot path
        return Self.chordSatisfied(chord, custom: customControllerChordProvider(),
                                   held: heldControllerButtons(pad: pad))
    }

    /// The pure chord predicate: every button of `chord` is in `held`. Static
    /// and nonisolated so the unit tests exercise every preset without a
    /// GCController. `.none` never matches, and `.custom` never matches an
    /// empty recording - an empty set is vacuously a subset of anything, which
    /// would quit the stream on the first frame.
    nonisolated static func chordSatisfied(_ chord: ControllerQuitChord,
                                           custom: Set<ControllerButton>,
                                           held: Set<ControllerButton>) -> Bool {
        let required: Set<ControllerButton>
        switch chord {
        case .none:
            return false
        case .startSelectL1R1:
            // Moonlight default: Start (Options ≡ / Xbox Menu) + Select
            // (Create/Share / Xbox View) + both shoulders.
            required = [.options, .create, .l1, .r1]
        case .l1r1:
            required = [.l1, .r1]
        case .l1r1l2r2:
            required = [.l1, .r1, .l2, .r2]
        case .l3r3:
            required = [.l3, .r3]
        case .custom:
            required = custom
        }
        return !required.isEmpty && required.isSubset(of: held)
    }

    /// One-time guard for the raw-HID-needed warning below.
    nonisolated(unsafe) static var warnedQuitChordNeedsRawHID = false

    /// True iff the configured quit chord depends on a DualSense centre button
    /// GameController DROPS (Create / Mute) - so it cannot fire on a DualSense
    /// without the raw-HID reader. Options has a `buttonMenu` fallback and PS a
    /// `buttonHome` one (both GameController-native), and every other chord button
    /// is GameController-native too - only Create (`buttonOptions`, bound to a
    /// macOS system gesture that withholds it) and Mute (no GC element at all)
    /// are raw-HID-only. Used to surface the silent "quit chord never fires on
    /// DualSense because raw-HID is off" failure.
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

    /// True iff the configured chord contains any centre button - the gate for
    /// the partial-hold breadcrumb, so a chord like L3 + R3 never logs a line
    /// for an ordinary Options press that opens a game menu.
    func quitChordUsesCentreButtons() -> Bool {
        switch controllerQuitChordProvider() {
        case .startSelectL1R1:
            return true
        case .custom:
            return !customControllerChordProvider().isDisjoint(with: [.options, .create, .ps, .mute])
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
        quitChordBreadcrumb(.armed, "held on slot \(slot) - dwell armed "
            + "(\(Int(Self.quitChordDwellSeconds * 1000))ms)", pad: pad)
        // Task inherits MainActor isolation from this context, so touching the
        // forwarder's stored state after the sleep is sound. `pad` is weak: a
        // disconnect mid-dwell must not extend the profile's lifetime (and
        // detach(gamepad:) cancels the dwell for the arming slot anyway).
        quitChordDwellTask = Task { [weak self, weak pad] in
            try? await Task.sleep(nanoseconds: UInt64(Self.quitChordDwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Clear the slot BEFORE any other early return: a bail-out that
            // left the finished task stored would wedge the arm guard above
            // for the rest of the session (only a non-matching frame from the
            // arming slot clears it, and a deliberate hold produces none).
            self.quitChordDwellTask = nil
            self.quitChordDwellSlot = nil
            // Re-verify against the live profile at expiry: isPressed/value
            // read current hardware state, so a release that produced no
            // further value-changed frame still reads released here. isReady
            // guards the shutdown race - detach() cancels this task, but a
            // teardown that races the wakeup must not quit a dead session.
            guard let pad, self.isReady else { return }
            guard self.matchesControllerQuitChord(pad: pad) else {
                self.quitChordBreadcrumb(.cycle, "not held at dwell expiry (slot \(slot)) - not quitting", pad: pad)
                return
            }
            Diag.notice("controller quit chord held - ending stream", "Controller")
            self.onQuitHotkey?()
        }
    }

    /// Cancel an in-flight dwell (chord released early, arming pad detached,
    /// or session teardown). Safe to call with none pending. `reason` (with
    /// the pad when one is still around) leaves the diagnosable breadcrumb;
    /// teardown passes nothing - the session end is its own log line.
    func cancelQuitChordDwell(reason: String? = nil, pad: GCExtendedGamepad? = nil) {
        guard let task = quitChordDwellTask else {
            quitChordDwellSlot = nil
            return
        }
        task.cancel()
        quitChordDwellTask = nil
        quitChordDwellSlot = nil
        if let reason { quitChordBreadcrumb(.cycle, "cancelled - \(reason)", pad: pad) }
    }

    // MARK: - Breadcrumbs

    /// Rate-limit bookkeeping for the quit-chord breadcrumbs. Stored on
    /// InputForwarder (`quitChordCrumbs`) because extensions can't add
    /// stored properties.
    struct QuitChordBreadcrumbState {
        var lastArmAt: TimeInterval = 0
        var lastPartialAt: TimeInterval = 0
        /// True while the current arm→cancel/expiry cycle is being logged:
        /// the arm line is the rate-limited one, and its cancel/expiry
        /// partner always follows it, so a logged cycle is never left without
        /// its outcome and a suppressed one adds no orphan lines.
        var cycleLogged = false
    }

    enum QuitChordBreadcrumbKind {
        case armed     // rate-limited: one per second
        case cycle     // follows an armed line that was logged
        case partial   // rate-limited: one per second
    }

    /// Minimum spacing between rate-limited breadcrumbs. A button bouncing on
    /// the chord boundary would otherwise arm/cancel at frame rate.
    static let quitChordBreadcrumbIntervalSeconds: TimeInterval = 1.0

    /// Diag NOTICE (so it reaches the session file - os_log info never does,
    /// which is why the last chord failure was undiagnosable from a shipped
    /// log). Carries the held set as the chord predicate sees it AND the two
    /// raw views behind it, so a partial hold reads straight off the line:
    /// "held=Options + L1 + R1" with hid[cre=false] says Create never
    /// registered; hid[l1=true] with gc[l1=false] says GameController withheld
    /// a shoulder. Only ever called on transitions (arm, cancel, expiry, a
    /// centre-button edge), never per frame; the held-set build is the cost.
    func quitChordBreadcrumb(_ kind: QuitChordBreadcrumbKind, _ what: String, pad: GCExtendedGamepad?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .armed:
            let allowed = now - quitChordCrumbs.lastArmAt >= Self.quitChordBreadcrumbIntervalSeconds
            quitChordCrumbs.cycleLogged = allowed
            guard allowed else { return }
            quitChordCrumbs.lastArmAt = now
        case .cycle:
            guard quitChordCrumbs.cycleLogged else { return }
            quitChordCrumbs.cycleLogged = false
        case .partial:
            guard now - quitChordCrumbs.lastPartialAt >= Self.quitChordBreadcrumbIntervalSeconds else { return }
            quitChordCrumbs.lastPartialAt = now
        }
        let hid = DualSenseHID.shared.buttons
        var detail = "chord=\(controllerQuitChordProvider().rawValue) "
            + "hid[opt=\(hid.options) cre=\(hid.create) l1=\(hid.l1) r1=\(hid.r1)]"
        if let pad {
            let held = heldControllerButtons(pad: pad)
            detail += " gc[menu=\(pad.buttonMenu.isPressed) opt=\(pad.buttonOptions?.isPressed ?? false) "
                + "l1=\(pad.leftShoulder.isPressed) r1=\(pad.rightShoulder.isPressed)] "
                + "held=\(held.isEmpty ? "none" : ControllerButton.describe(held))"
        }
        Diag.notice("controller quit chord \(what): \(detail)", "Controller")
    }
}

/// The set of buttons currently held on a gamepad, used both to match the
/// quit chord (ControllerForwarder) and to drive the Settings capture sheet.
/// Reads GameController plus the DualSense raw-HID bits - the centre buttons
/// GameController never delivers and the two shoulders the same report byte
/// carries (see `DualSenseExtraButtons` for why the shoulders ride along).
/// Free function (not an InputForwarder method) so the Settings capture sheet,
/// which has no live stream, can call it too.
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
        (hid.l1 || pad.leftShoulder.isPressed, .l1),
        (hid.r1 || pad.rightShoulder.isPressed, .r1),
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
