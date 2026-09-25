//
//  ControllerForwarder.swift
//
//  GameController framework integration: wireless discovery, slot allocation,
//  arrival announcements, the GCController → moonlight type/flag derivation, and
//  the install/heal of the per-frame value-changed handlers.
//
//  Originally inline in InputForwarder.swift; split out so the C-bridge core
//  (mouse/keyboard capture lifecycle) and the gamepad path live in separate
//  files. Stored state (`attachedControllers`, `gamepadMask`,
//  `connectObserver`, `disconnectObserver`) lives on `InputForwarder` proper
//  so the extension has somewhere to put per-instance bookkeeping. Methods
//  in this file rely on default `internal` access to those stored properties.
//
//  Split further by topic, for the same length reason: the per-frame state push
//  those handlers run (and the button bitmask it builds) in
//  ControllerForwarder+StatePush.swift, the touchpad surface → host touch events
//  in ControllerForwarder+Touchpad.swift, the quit chord + its hold-to-quit
//  dwell in ControllerForwarder+QuitChord.swift.
//

import AppKit
import GameController

extension InputForwarder {

    // MARK: - Per-controller state

    /// What an arrival tells the PC about a pad: LI_CTYPE_*, button flags, LI_CCAP_* bits.
    struct ControllerArrival: Equatable {
        let type: UInt8
        let supportedButtons: UInt32
        let caps: UInt16
    }

    struct AttachedController {
        let slot: UInt8           // 0..15, used as `controllerNumber`
        let arrival: ControllerArrival
        weak var controller: GCController?
        /// True if this is a DualSense and we `retain()`ed the raw-HID reader
        /// for it (so detach can `release()` it).
        let retainedHID: Bool
    }

    // MARK: - Lifecycle

    func setupGamepadObservers() {
        dualSenseRouting.syncControllers()
        setupHIDGamepads()
        // Notification (and the GCController it carries) are non-Sendable,
        // so we cannot capture them across a MainActor hop directly. The
        // closures we hand to NotificationCenter are `@Sendable`, and the
        // compiler treats their body as task-isolated even though we asked
        // for delivery on `queue: .main`. The pragmatic, safe pattern:
        // observer body runs on main queue (we pinned it), so we can
        // assume MainActor and look the controller up via the framework's
        // own `GCController.controllers()` registry - which IS the source
        // of truth and is documented as main-thread-only access.
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Newly-connected controller is the last one in the registry
                // we haven't yet attached. Walk and pick up any unknowns -
                // this also recovers from a missed observer fire.
                for controller in GCController.controllers()
                where self.attachedControllers[ObjectIdentifier(controller)] == nil {
                    self.attach(gamepad: controller)
                }
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Remove any tracked controllers no longer in the registry.
                let live = Set(GCController.controllers().map(ObjectIdentifier.init))
                for id in self.attachedControllers.keys where !live.contains(id) {
                    if let state = self.attachedControllers[id], let pad = state.controller {
                        self.detach(gamepad: pad)
                    } else {
                        // Controller already deallocated; just clear bookkeeping.
                        if let state = self.attachedControllers.removeValue(forKey: id) {
                            self.dualSenseRouting.syncControllers()
                            self.dualSenseRouting.unregister(slot: state.slot)
                            if state.retainedHID { DualSenseHID.shared.release() }
                            self.gamepadMask &= ~(UInt16(1) << state.slot)
                            if self.isReady { self.sendControllerRemoval(slot: state.slot) }
                            // The pad object (and its motors) died with the
                            // deallocation - still release the haptics,
                            // motion and battery slots so a future attach
                            // starts clean.
                            ControllerHaptics.shared.unregister(slot: state.slot)
                            ControllerMotion.shared.unregister(slot: state.slot)
                            ControllerBattery.shared.unregister(slot: state.slot)
                        }
                    }
                }
            }
        }
        GCController.startWirelessControllerDiscovery {}

        // Attach controllers ALREADY connected when the stream wires up.
        // GCControllerDidConnect does NOT replay for pads connected before we
        // start observing, so without this an already-paired controller is
        // never attached → never forwarded (the stream sees no controller at
        // all). The connect observer above only covers pads that arrive later.
        for controller in GCController.controllers()
        where attachedControllers[ObjectIdentifier(controller)] == nil {
            attach(gamepad: controller)
        }
    }

    func attach(gamepad: GCController) {
        dualSenseRouting.syncControllers()
        // Lowest free slot 0..15, Sunshine's 16-pad limit (MAX_GAMEPADS). A 17th pad is REFUSED: slot 0 would
        // double-map it, two handlers interleaving full states into one controllerNumber and a haptics
        // register tearing down the legitimate pad's engines.
        guard let slot = (0..<UInt8(16)).first(where: { (gamepadMask & (1 << $0)) == 0 }) else {
            Diag.notice("controller attach refused: all 16 slots occupied "
                + "(\(gamepad.vendorName ?? "Unknown"))", "Controller")
            return
        }
        gamepadMask |= UInt16(1) << slot

        // Light the controller's player-number LEDs to match its slot - the one
        // native touch the pad was missing. GameController owns this on macOS (it
        // drives the DualSense's player dots, the Xbox quadrant, etc.), so we use
        // the official playerIndex rather than poking raw-HID LED bytes and
        // fighting gamecontrollerd. Only indices 1-4 exist; a 5th+ pad (slot >= 4,
        // Sunshine-only territory) stays unset and keeps the system default.
        gamepad.playerIndex = GCControllerPlayerIndex(rawValue: Int(slot)) ?? .indexUnset

        // Determine controller type from GameController metadata. macOS doesn't
        // expose a clean type enum, so we infer from product category strings.
        let kind = controllerType(for: gamepad)
        var caps = UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS)
        // ControllerHaptics plays rumble through `haptics` alone, so a pad without it
        // gets none; trigger rumble also needs both trigger localities.
        if let localities = gamepad.haptics?.supportedLocalities {
            caps |= UInt16(StreamProtocol.LI_CCAP_RUMBLE)
            if localities.contains(.leftTrigger), localities.contains(.rightTrigger) {
                caps |= UInt16(StreamProtocol.LI_CCAP_TRIGGER_RUMBLE)
            }
        }
        // Motion caps come from the sampler's per-sensor probe (accel/gyro
        // gated separately), which also maps the slot for the host's 0x5501
        // enable. Registration alone starts no sensors.
        caps |= ControllerMotion.shared.register(slot: slot, controller: gamepad)
        // Battery likewise: the monitor's probe returns the bit only when the
        // pad exposes a GCDeviceBattery, and maps the slot for the ~30s
        // report cadence. Registration alone sends nothing.
        caps |= ControllerBattery.shared.register(slot: slot, controller: gamepad)
        if gamepad.light != nil {
            caps |= UInt16(StreamProtocol.LI_CCAP_RGB_LED)
        }
        // DualSense / DualShock expose a touchpad surface + click through
        // GameController. Advertise LI_CCAP_TOUCHPAD so the host knows it can
        // expect LiSendControllerTouchEvent2 fingers from this slot. (One
        // physical touchpad tracking two fingers - NOT LI_CCAP_DUAL_TOUCHPAD,
        // which is for controllers with two separate pads.)
        if let ex = gamepad.extendedGamepad, touchpadElements(of: ex) != nil {
            caps |= UInt16(StreamProtocol.LI_CCAP_TOUCHPAD)
        }

        // Create/Share (`buttonOptions`) is bound to a macOS system gesture -
        // measured on macOS 26 for the DualSense (isBoundToSystemGesture == true;
        // the WWDC21 contract is double-press = screenshot, long-press = start or
        // stop a ReplayKit recording). "Bound" means GameController runs the
        // recognizer FIRST and withholds the press from the app, and the Moonlight
        // quit chord is by definition a long-press of Create: the hold never
        // reached us through GameController AND asked macOS to start a screen
        // recording. A streaming client has exactly one consumer for that button,
        // the host, so disable the gesture: the press is delivered immediately and
        // macOS stays out of it.
        if let create = gamepad.extendedGamepad?.buttonOptions, create.isBoundToSystemGesture {
            create.preferredSystemGestureState = .disabled
            Diag.info("controller \(slot): Create/Share was bound to a macOS system gesture - "
                + "disabled so the press reaches the stream", "Controller")
        }
        // Home (PS): macOS 27 honors this only when the user picks Defer to app in
        // System Settings › Game Controllers, so the default Game Overlay stays and
        // Defer sends Guide to the PC.
        if #available(macOS 27, *) {
            gamepad.physicalInputProfile.buttons[GCInputButtonHome]?.preferredSystemGestureState = .disabled
        }

        // DualSense + the user opted in: start the raw-HID side-channel so the
        // Options / Create / Mute buttons GameController hides become available
        // (see DualSenseHID). Gated on the opt-in so the Input Monitoring
        // prompt never fires unless the feature is on.
        let isDualSense = gamepad.extendedGamepad is GCDualSenseGamepad
        let useHID = isDualSense && DualSenseHID.isEnabled
        // OBSERVABILITY: a DualSense with raw-HID OFF can't read its Create/Mute
        // centre buttons, so a quit chord that needs them silently never fires
        // (the diagnosed regression - invisible because the open state only logged
        // at INFO). Surface it once, plainly, so the fix is obvious.
        if isDualSense, !useHID, !Self.warnedQuitChordNeedsRawHID,
           Self.needsRawHIDCenterButtons(chord: controllerQuitChordProvider(),
                                         custom: customControllerChordProvider()) {
            Self.warnedQuitChordNeedsRawHID = true
            Diag.notice("Quit chord needs DualSense centre buttons (Create/Mute) that require "
                + "raw-HID, but raw-HID controller support is OFF - the chord will NOT fire on "
                + "this DualSense. Enable 'Extra DualSense buttons' in Settings → Input (and grant Input "
                + "Monitoring), or pick a chord that uses GameController-native buttons.",
                "Controller")
        }
        if useHID {
            // Retain the raw-HID reader (Options/Create/Mute centre buttons +
            // battery). The onChange handler that turns a centre-button edge into
            // a host push is installed by installInputHandlers(for:) below - one
            // place installs BOTH the GameController and raw-HID handlers so a
            // focus-regain resync can re-install (heal) them together.
            DualSenseHID.shared.retain()
        }

        // Build supportedButtonFlags by checking which inputs the controller
        // actually exposes. This is the same logic moonlight-qt uses to give
        // the host a hint about what kind of virtual controller to emulate.
        let buttons = supportedButtonMask(for: gamepad, forwardsMute: useHID)

        let state = AttachedController(
            slot: slot, arrival: ControllerArrival(type: kind, supportedButtons: buttons, caps: caps),
            controller: gamepad, retainedHID: useHID
        )
        attachedControllers[ObjectIdentifier(gamepad)] = state
        dualSenseRouting.register(slot: slot, controller: ObjectIdentifier(gamepad))

        // Make the slot addressable by the PC's rumble and light bar events. Registration
        // alone never spins a motor, and a pad without haptics simply drops rumble.
        ControllerHaptics.shared.register(slot: slot, controller: gamepad)

        // Controller metadata is non-sensitive; build the detail once and log
        // it .public rather than annotating every interpolation inline.
        let detail = "Gamepad attached: \(gamepad.vendorName ?? "Unknown") "
            + "slot=\(slot) mask=0x\(String(gamepadMask, radix: 16)) caps=0x\(String(caps, radix: 16))"
        log.info("\(detail, privacy: .public)")
        // The Diag line carries type/caps/buttons hex too: the os_log copy
        // above is volatile (unified log), so until these reached the durable
        // session file, a postmortem could not PROVE which caps went out -
        // e.g. Xbox 0x47 (trigger rumble probed) vs 0x43. Cost an
        // investigation once; never again.
        Diag.info("controller attached: \(gamepad.vendorName ?? "Unknown") (slot \(slot)"
            + "\(useHID ? ", raw-HID" : "")) type=0x\(String(kind, radix: 16)) "
            + "caps=0x\(String(caps, radix: 16)) buttons=0x\(String(buttons, radix: 16))",
            "Controller")

        // Install the live input handlers (GameController valueChangedHandler +
        // the raw-HID centre-button onChange). Factored into installInputHandlers
        // so resyncControllers() can RE-install them on every focus regain: the
        // Settings chord-capture sheet grabs both single-slot handlers to record a
        // chord and nils them on dismiss, which otherwise left controller input
        // dead until a stream restart. See installInputHandlers.
        installInputHandlers(for: state)

        // If the stream is already up, announce arrival immediately;
        // otherwise it'll go out when `setReady(true)` is called.
        if isReady {
            sendArrival(slot: slot, state.arrival)
        }
    }

    func detach(gamepad: GCController) {
        guard let state = attachedControllers.removeValue(forKey: ObjectIdentifier(gamepad)) else { return }
        dualSenseRouting.disconnectController(ObjectIdentifier(gamepad))
        dualSenseRouting.unregister(slot: state.slot)
        gamepadMask &= ~(UInt16(1) << state.slot)
        touchpadStates[state.slot] = nil
        // Stop this pad's rumble engines AND motion sampling: a disconnect
        // mid-rumble must never leave motors buzzing, mid-gyro must not strand
        // the host on a stale rotation (the sampler sends the gyro null).
        // Battery is plain bookkeeping - the detach event retires the pad.
        ControllerHaptics.shared.unregister(slot: state.slot)
        ControllerMotion.shared.unregister(slot: state.slot)
        ControllerBattery.shared.unregister(slot: state.slot)
        if state.retainedHID {
            DualSenseHID.shared.release()
        }
        // If this pad armed the in-flight quit-chord dwell, the hold can no
        // longer complete - cancel rather than let the timer re-read a
        // disconnected profile.
        if quitChordDwellSlot == state.slot { cancelQuitChordDwell(reason: "arming pad detached") }
        let remainingMask = String(gamepadMask, radix: 16)
        log.info("Gamepad detached: slot=\(state.slot) remaining mask=0x\(remainingMask, privacy: .public)")
        // DETACH-CONTEXT breadcrumb (NOTICE - a detach is rare and is exactly
        // the postmortem anchor the file sink must keep): last-input and
        // last-rumble ages auto-classify the disconnect cause that previously
        // took a three-file join - idle auto-sleep reads minutes/minutes (input
        // tens of minutes idle, rumble frozen), a mid-rumble radio drop reads
        // seconds/sub-second (rumble active at detach). Ages are process-global
        // session stamps (any pad + kbd/mouse for input), the same sources the
        // telemetry rows carry.
        let counters = TelemetryCounters.shared
        let inputAge = counters.timeSinceLastInputMs().map { String(Int($0)) } ?? "none"
        let rumbleAge = counters.rumbleActivity.ageMs().map { String(Int($0)) } ?? "none"
        Diag.notice("controller detached (slot \(state.slot)): "
            + "last_input_age_ms=\(inputAge) last_rumble_age_ms=\(rumbleAge) "
            + "rumble_events_total=\(counters.rumbleEventTotal.value)", "Controller")

        if isReady { sendControllerRemoval(slot: state.slot) }
    }

    /// Session-teardown twin of `detach(gamepad:)`, called from
    /// `InputForwarder.detach()`. detach(gamepad:) balances per-controller
    /// acquisitions for pads that physically disconnect MID-session, but its
    /// trigger - the GCControllerDidDisconnect observer - dies with this
    /// forwarder, so session teardown is the LAST place those can ever be
    /// released for pads still connected when the stream ends. Without this
    /// walk (the measured leak): the DualSenseHID retain from attach() was
    /// never balanced, so the IOHIDManager stayed open and scheduled on the
    /// MAIN run loop decoding every BT input report for the rest of the
    /// process with no stream up (one extra stranded retain per session),
    /// Input Monitoring stayed engaged app-wide, and - because the live raw
    /// reader keeps the pad in enhanced-report mode - GCController.battery
    /// read nil, so the NEXT session's battery probe silently declined and
    /// LI_CCAP_BATTERY_STATE stopped being advertised. The Battery/Motion/
    /// Haptics registries are process singletons with the same session-
    /// scoped-unregister mismatch: stale Pad slots kept the shared 30s
    /// battery poll timer firing no-op wakeups until app quit. Mirrors
    /// detach(gamepad:) minus the host-facing detach event - StreamSession
    /// .stop() runs this after stopConnection(), so there is no live
    /// connection to tell.
    func releaseAttachedControllers() {
        // A pad connecting while stop waits on the PC must not retake the HID
        // retain and haptics, motion, or battery slots this walk releases.
        removeGamepadObservers()
        releaseHIDControllers()
        for state in attachedControllers.values {
            state.controller?.extendedGamepad?.valueChangedHandler = nil
            dualSenseRouting.unregister(slot: state.slot)
            ControllerHaptics.shared.unregister(slot: state.slot)
            ControllerMotion.shared.unregister(slot: state.slot)
            ControllerBattery.shared.unregister(slot: state.slot)
            if state.retainedHID {
                DualSenseHID.shared.onChange = nil
                DualSenseHID.shared.release()
            }
        }
        attachedControllers.removeAll()
        touchpadStates.removeAll()
        gamepadMask = 0
        announcedControllers.removeAll()
    }

    func removeGamepadObservers() {
        let center = NotificationCenter.default
        if let observer = connectObserver { center.removeObserver(observer); connectObserver = nil }
        if let observer = disconnectObserver { center.removeObserver(observer); disconnectObserver = nil }
    }

    func sendArrival(slot: UInt8, _ arrival: ControllerArrival) {
        let rc = backend?.sendControllerArrival(
            num: slot, mask: gamepadMask, type: arrival.type,
            supportedButtons: arrival.supportedButtons, caps: arrival.caps
        ) ?? -2
        record("LiSendControllerArrivalEvent", rc)
        announcedControllers[slot] = arrival
        // Durable per-session witness of what the PC was told; record() only
        // reaches os_log. Arrivals replay once per pad per stream, so bounded.
        Diag.info("controller \(slot) arrival sent: "
            + "caps=0x\(String(arrival.caps, radix: 16)) rc=\(rc)", "Controller")
        // The battery baseline rides right behind the arrival, which also
        // re-arms the uplink at every stream start.
        ControllerBattery.shared.announce(slot: slot, backend: backend)
    }

    /// An empty event with the slot's bit cleared, which Sunshine takes as the pad leaving.
    func sendControllerRemoval(slot: UInt8) {
        let rc = backend?.sendMultiController(
            num: Int16(slot), mask: Int16(bitPattern: gamepadMask & ~(UInt16(1) << slot)), buttons: 0,
            analog: Self.neutralControllerAnalog
        ) ?? -2
        record("LiSendMultiControllerEvent(removal)", rc)
    }

    /// Every stream start: retire each slot the PC may still hold whose pad left or changed,
    /// then replay each arrival and re-push held state, which the arrival's fallback event zeroed.
    /// Removals go first so the first arrival's flush carries them ahead of any new pad.
    func announceControllers() {
        var current: [UInt8: ControllerArrival] = [:]
        for state in attachedControllers.values { current[state.slot] = state.arrival }
        for state in attachedHIDControllers.values { current[state.slot] = state.arrival }
        for slot in Self.staleControllerSlots(announced: announcedControllers, current: current) {
            sendControllerRemoval(slot: slot)
            announcedControllers[slot] = nil
        }
        for state in attachedControllers.values { sendArrival(slot: state.slot, state.arrival) }
        for state in attachedHIDControllers.values {
            sendArrival(slot: state.slot, state.arrival)
            pushHID(state.device)
        }
        resyncControllers()
    }

    /// Announced slots whose pad is gone or no longer matches. Sunshine keeps a paired
    /// client's pads across a reconnect and ignores an arrival for a slot it holds.
    static func staleControllerSlots(announced: [UInt8: ControllerArrival],
                                     current: [UInt8: ControllerArrival]) -> [UInt8] {
        announced.filter { current[$0.key] != $0.value }.keys.sorted()
    }

    // MARK: - GCController -> moonlight type/flag derivation

    func controllerType(for gamepad: GCController) -> UInt8 {
        let category = gamepad.productCategory
        switch category {
        case GCProductCategoryXboxOne, GCProductCategoryMFi:
            return UInt8(StreamProtocol.LI_CTYPE_XBOX)
        case GCProductCategoryDualShock4, GCProductCategoryDualSense:
            return UInt8(StreamProtocol.LI_CTYPE_PS)
        case GCProductCategoryHID:
            return UInt8(StreamProtocol.LI_CTYPE_UNKNOWN)
        default:
            // GCProductCategorySwitchPro / JoyCon / etc. fall here on
            // older SDKs that don't expose a constant for them.
            if category.localizedCaseInsensitiveContains("switch") ||
               category.localizedCaseInsensitiveContains("joycon") {
                return UInt8(StreamProtocol.LI_CTYPE_NINTENDO)
            }
            return UInt8(StreamProtocol.LI_CTYPE_UNKNOWN)
        }
    }

    /// `forwardsMute`: a DualSense whose raw-HID reader is live, so its Mute reaches the PC.
    func supportedButtonMask(for gamepad: GCController, forwardsMute: Bool) -> UInt32 {
        guard let ex = gamepad.extendedGamepad else { return 0 }
        var b: Int32 = 0
        // Always-present face/shoulder/dpad/menu on extended gamepads.
        b |= StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG | StreamProtocol.Y_FLAG
        b |= StreamProtocol.UP_FLAG | StreamProtocol.DOWN_FLAG | StreamProtocol.LEFT_FLAG | StreamProtocol.RIGHT_FLAG
        b |= StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        b |= StreamProtocol.PLAY_FLAG // buttonMenu is non-optional on GCExtendedGamepad
        if ex.leftThumbstickButton  != nil { b |= StreamProtocol.LS_CLK_FLAG }
        if ex.rightThumbstickButton != nil { b |= StreamProtocol.RS_CLK_FLAG }
        if ex.buttonOptions != nil { b |= StreamProtocol.BACK_FLAG }
        if ex.buttonHome    != nil { b |= StreamProtocol.SPECIAL_FLAG }
        if touchpadElements(of: ex) != nil { b |= StreamProtocol.TOUCHPAD_FLAG }
        // Xbox Share (a GCXboxGamepad probe) and DualSense Mute both ride MISC_FLAG,
        // the spare button moonlight-qt maps Share to (see pressedButtonFlags).
        if xboxShareButton(of: ex) != nil || forwardsMute { b |= StreamProtocol.MISC_FLAG }
        return UInt32(bitPattern: b)
    }

    /// The DualSense / DualShock touchpad surfaces + click button for a
    /// gamepad profile, or nil if it has no touchpad. Both PlayStation
    /// profiles (`GCDualSenseGamepad`, `GCDualShockGamepad`) are concrete
    /// subclasses of `GCExtendedGamepad`, so a downcast on the profile we
    /// already hold is the cleanest probe. `touchpadPrimary`/`touchpadSecondary`
    /// are the two finger contacts on the single physical pad.
    func touchpadElements(of ex: GCExtendedGamepad)
        -> (primary: GCControllerDirectionPad, secondary: GCControllerDirectionPad, button: GCControllerButtonInput)? {
        if let ds = ex as? GCDualSenseGamepad {
            return (ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton)
        }
        if let ds4 = ex as? GCDualShockGamepad {
            return (ds4.touchpadPrimary, ds4.touchpadSecondary, ds4.touchpadButton)
        }
        return nil
    }

    /// The Xbox Series Share/Capture button for a gamepad profile, or nil if it
    /// has none. Like the touchpad probe, a downcast on the profile we already
    /// hold: only `GCXboxGamepad` exposes `buttonShare`, and only on macOS 12+,
    /// so older SDKs / other pads return nil.
    func xboxShareButton(of ex: GCExtendedGamepad) -> GCControllerButtonInput? {
        guard #available(macOS 12.0, *), let xb = ex as? GCXboxGamepad else { return nil }
        return xb.buttonShare
    }

    // MARK: - Input handler install / heal

    /// (Re)install the live input handlers for an attached controller: the
    /// GameController `valueChangedHandler` (the single full-state forward) and,
    /// for a raw-HID DualSense, `DualSenseHID.shared.onChange` (the centre-button
    /// edge GameController never delivers). Idempotent, so it doubles as a HEAL:
    /// the Settings chord-capture sheet (ChordCaptureSheet.engage/disengage) takes
    /// over both single-slot handlers to record a chord and sets them to `nil` on
    /// dismiss - which, with a stream live, left the forwarder's input path dead
    /// until a session restart re-ran attach(). resyncControllers() calls this on
    /// every focus regain, so returning to the stream restores input with no
    /// restart.
    func installInputHandlers(for state: AttachedController) {
        guard let gamepad = state.controller else { return }
        let slot = state.slot
        let routesHID = state.retainedHID
        // GameController invokes this on the main queue; assume MainActor so
        // Swift 6 strict concurrency is satisfied.
        gamepad.extendedGamepad?.valueChangedHandler = { [weak self] (pad, _) in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The batcher takes this handler-entry stamp for its deliver leg.
                // Only stamp while ready, or the next push reads stale latency.
                if self.isReady {
                    InputDeliverStamp.shared.stamp(slot: Int(slot), nanos: DispatchTime.now().uptimeNanoseconds)
                }
                if routesHID { self.dualSenseRouting.gc(pad: pad) }
                self.sendGamepadUpdate(pad: pad, slot: slot)
            }
        }
        // Raw-HID centre buttons (Options/Create/Mute): GameController never fires
        // valueChangedHandler for them, so this onChange is the only path that
        // carries a centre-button edge (e.g. the Moonlight-default chord's Create)
        // to the host. DualSenseHID gates onChange on a real bit change; the push
        // does NOT re-forward the touchpad (that stays on the GameController path,
        // the single full-state source - no double-feed).
        if state.retainedHID {
            DualSenseHID.shared.onChange = { [weak self] device in
                guard let self, let id = self.dualSenseRouting.controller(for: device),
                      let attached = self.attachedControllers[id],
                      let ex = attached.controller?.extendedGamepad else { return }
                self.sendCenterButtonUpdate(pad: ex, slot: attached.slot)
            }
        }
    }

    // MARK: - Focus resync

    /// Re-send every attached controller's current state to the host. Called
    /// when the stream window regains key focus, so a stick held across a focus
    /// loss snaps back to live state immediately. (The overlay battery read
    /// that used to live here moved to ControllerBattery.swift, with the
    /// host-facing battery uplink.)
    func resyncControllers() {
        guard isReady else { return }
        for state in attachedControllers.values {
            // Re-install handlers FIRST: a component that grabbed the single-slot
            // valueChangedHandler / DualSenseHID.onChange while we were not key -
            // the Settings chord-capture sheet - may have nil'd ours, leaving
            // controller input dead. Healing here means returning focus to the
            // stream restores live input without a session restart. Then push
            // current state so a held stick/button snaps to live immediately.
            installInputHandlers(for: state)
            guard let pad = state.controller?.extendedGamepad else { continue }
            sendGamepadUpdate(pad: pad, slot: state.slot)
        }
    }

    // (matchesControllerQuitChord and the shared heldControllerButtons reader
    // live in ControllerForwarder+QuitChord.swift; sendGamepadUpdate /
    // sendCenterButtonUpdate - the handlers installed above - in
    // ControllerForwarder+StatePush.swift, and forwardTouchpad in
    // ControllerForwarder+Touchpad.swift - the topic split.)
}
