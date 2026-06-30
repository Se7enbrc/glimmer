//
//  ControllerForwarder.swift
//
//  GameController framework integration: wireless discovery, slot allocation,
//  arrival announcements, and per-frame value-changed handlers that translate
//  GCExtendedGamepad state into `LiSendMultiControllerEvent` calls.
//
//  Originally inline in InputForwarder.swift; split out so the C-bridge core
//  (mouse/keyboard capture lifecycle) and the gamepad path live in separate
//  files. Stored state (`attachedControllers`, `gamepadMask`,
//  `connectObserver`, `disconnectObserver`) lives on `InputForwarder` proper
//  so the extension has somewhere to put per-instance bookkeeping. Methods
//  in this file rely on default `internal` access to those stored properties.
//

import AppKit
import GameController

extension InputForwarder {

    // MARK: - Per-controller state

    struct AttachedController {
        let slot: UInt8           // 0..15, used as `controllerNumber`
        let kind: UInt8           // LI_CTYPE_*
        let capabilities: UInt16  // LI_CCAP_* bitset
        let supportedButtonFlags: UInt32
        weak var controller: GCController?
        /// True if this is a DualSense and we `retain()`ed the raw-HID reader
        /// for it (so detach can `release()` it).
        let retainedHID: Bool
    }

    // MARK: - Lifecycle

    func setupGamepadObservers() {
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
                            self.gamepadMask &= ~(UInt16(1) << state.slot)
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
        // Allocate the lowest free slot 0..15. moonlight-common-c supports up
        // to 16 controllers on Sunshine hosts, up to 4 on GFE. A 17th pad is
        // REFUSED outright: falling back to slot 0 would silently double-map
        // it (two handlers interleaving full states into one controllerNumber,
        // plus a haptics register tearing down the legitimate pad's engines).
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
        var caps: UInt16 = UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) | UInt16(StreamProtocol.LI_CCAP_RUMBLE)
        // Trigger rumble is gated on the probed hardware (unlike body rumble,
        // advertised unconditionally): advertising it for a pad without
        // trigger localities would invite host traffic we can only drop.
        if let localities = gamepad.haptics?.supportedLocalities,
           localities.contains(.leftTrigger), localities.contains(.rightTrigger) {
            caps |= UInt16(StreamProtocol.LI_CCAP_TRIGGER_RUMBLE)
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

        // Build supportedButtonFlags by checking which inputs the controller
        // actually exposes. This is the same logic moonlight-qt uses to give
        // the host a hint about what kind of virtual controller to emulate.
        let buttons = supportedButtonMask(for: gamepad)

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
        if isDualSense, !useHID, quitChordNeedsRawHIDCenterButtons(),
           !Self.warnedQuitChordNeedsRawHID {
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

        let state = AttachedController(
            slot: slot, kind: kind, capabilities: caps,
            supportedButtonFlags: buttons, controller: gamepad,
            retainedHID: useHID
        )
        attachedControllers[ObjectIdentifier(gamepad)] = state

        // Make this slot addressable by inbound host rumble (control 0x010b):
        // we advertise LI_CCAP_RUMBLE unconditionally above, so the actuator
        // must be able to resolve every slot we hand out. Unconditional on
        // purpose - ControllerHaptics degrades quietly if the pad turns out to
        // expose no haptics, and registration alone never spins a motor.
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
            sendArrival(state)
        }
    }

    func detach(gamepad: GCController) {
        guard let state = attachedControllers.removeValue(forKey: ObjectIdentifier(gamepad)) else { return }
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
            DualSenseHID.shared.onChange = nil
            DualSenseHID.shared.release()
        }
        // If this pad armed the in-flight quit-chord dwell, the hold can no
        // longer complete - cancel rather than let the timer re-read a
        // disconnected profile.
        if quitChordDwellSlot == state.slot { cancelQuitChordDwell() }
        log.info("Gamepad detached: slot=\(state.slot) remaining mask=0x\(String(self.gamepadMask, radix: 16), privacy: .public)")
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

        if isReady {
            // Empty event with the slot bit cleared signals removal to the host.
            let rc = backend?.sendMultiController(
                num: Int16(state.slot), mask: Int16(bitPattern: gamepadMask), buttons: 0,
                analog: GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                      leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0)
            ) ?? -2
            record("LiSendMultiControllerEvent(detach)", rc)
        }
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
        for state in attachedControllers.values {
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
    }

    func sendArrival(_ state: AttachedController) {
        let rc = backend?.sendControllerArrival(
            num: state.slot,
            mask: gamepadMask,
            type: state.kind,
            supportedButtons: UInt32(state.supportedButtonFlags),
            caps: state.capabilities
        ) ?? -2
        record("LiSendControllerArrivalEvent", rc)
        // Durable per-session witness of WHAT we told the host and whether the
        // enqueue took (record() above logs failures to os_log only, and only
        // once per code). Arrivals replay once per pad per stream - bounded.
        Diag.info("controller \(state.slot) arrival sent: "
            + "caps=0x\(String(state.capabilities, radix: 16)) rc=\(rc)", "Controller")
        // Battery baseline rides right behind the arrival: the host learns
        // the pad exists, then what its battery holds (change reports follow
        // on the monitor's poll). Also (re)arms the uplink per session, since
        // setReady(true) replays arrivals at every stream start.
        ControllerBattery.shared.announce(slot: state.slot, backend: backend)
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

    func supportedButtonMask(for gamepad: GCController) -> UInt32 {
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
        // Xbox Series Share/Capture button. GameController surfaces it as
        // `GCXboxGamepad.buttonShare` (macOS 12+); GCExtendedGamepad has no
        // equivalent, so it's a downcast probe like the touchpad above. The
        // DualSense Mute already rides MISC_FLAG via the raw-HID path, and
        // moonlight-qt maps Xbox Share to the same misc/touchpad-button slot -
        // a spare host button no other pad button claims.
        if xboxShareButton(of: ex) != nil { b |= StreamProtocol.MISC_FLAG }
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

    /// Raw-HID side-channel update: fired ONLY when a DualSense center-button bit
    /// (Options/Create/PS/Mute) actually changed (DualSenseHID gates onChange on a
    /// real bit change). GameController never delivers those buttons and does NOT
    /// fire its valueChangedHandler for them, so this push is necessary to carry a
    /// center-button edge to the host - but it does NOT re-forward the touchpad
    /// (that stays on the GameController path) and the InputBatcher coalesces it
    /// with the latest GC-sourced axes for the slot, so it is not a double-feed of
    /// stick/axis state. This is the de-duplicated half of the old double-feed.
    func sendCenterButtonUpdate(pad: GCExtendedGamepad, slot: UInt8) {
        _ = pushControllerState(pad: pad, slot: slot)
    }

    /// Build + push the current multiController state for `slot`. Returns false if
    /// the push was short-circuited (not ready, or the quit chord fired). The
    /// touchpad surface is NOT forwarded here - callers that own the GameController
    /// frame do that separately.
    @discardableResult
    private func pushControllerState(pad: GCExtendedGamepad, slot: UInt8) -> Bool {
        guard isReady else { return false }

        // Controller-side quit chord - fires the same `onQuitHotkey` the
        // keyboard chord uses, but only after the chord stays held through
        // the dwell window (the Settings label promises "HOLD to leave the
        // stream"; firing on the first coincident frame meant any in-game
        // moment where the chord buttons momentarily overlapped - e.g. both
        // shoulders with the .l1r1 option - killed the session instantly).
        // Checked BEFORE building the bitmask we forward to the host so the
        // chord-holding frames don't get sent through (the host would
        // otherwise see L1+R1+L2+R2 in a game and act on it for the whole
        // hold). Dwell machinery: ControllerForwarder+QuitChord.swift.
        if matchesControllerQuitChord(pad: pad) {
            armQuitChordDwell(pad: pad, slot: slot)
            return false
        }
        // Released before the dwell elapsed (or never held): an in-game
        // button coincidence, not a quit. Only the arming pad's frames may
        // cancel - another pad's traffic says nothing about the holder.
        if quitChordDwellSlot == slot { cancelQuitChordDwell() }

        let buttons = pressedButtonFlags(pad: pad)

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
    private func pressedButtonFlags(pad: GCExtendedGamepad) -> Int32 {
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
            let hid = DualSenseHID.shared.buttons
            if hid.options { buttons |= StreamProtocol.PLAY_FLAG }
            if hid.create { buttons |= StreamProtocol.BACK_FLAG }
            if hid.ps { buttons |= StreamProtocol.SPECIAL_FLAG }
            if hid.mute { buttons |= StreamProtocol.MISC_FLAG }
        }
        return buttons
    }

    // MARK: - Touchpad surface forwarding

    /// One tracked finger contact on a controller touchpad.
    struct TouchpadFinger {
        var active = false
        var pointerId: UInt32 = 0
        var x: Float = 0   // last sent, host-space [0,1]
        var y: Float = 0
    }

    /// Per-slot touchpad finger state (primary + secondary contact).
    struct TouchpadState {
        var primary = TouchpadFinger()
        var secondary = TouchpadFinger()
    }

    /// Translate the DualSense/DualShock touchpad surface into host touch
    /// events. GameController reports each finger as a `GCControllerDirectionPad`
    /// that reads (0,0) when no finger is present and the contact position
    /// otherwise; we derive down/move/up transitions from that. Both fingers
    /// ride touchpad index 0 (one physical pad, two contacts), each with its
    /// own pointerId so the host can track them independently.
    ///
    /// EXPERIMENTAL: GameController exposes no explicit "finger down" flag, so
    /// "touching" is inferred from a non-zero position. A finger resting at the
    /// exact geometric centre is therefore indistinguishable from "lifted" -
    /// acceptable for taps/swipes (which move), a known edge for a dead-centre
    /// hold. Validate on-device.
    func forwardTouchpad(pad: GCExtendedGamepad, slot: UInt8) {
        guard let tp = touchpadElements(of: pad) else { return }
        var state = touchpadStates[slot] ?? TouchpadState()
        updateFinger(&state.primary, dpad: tp.primary, slot: slot)
        updateFinger(&state.secondary, dpad: tp.secondary, slot: slot)
        touchpadStates[slot] = state
    }

    private func updateFinger(_ finger: inout TouchpadFinger, dpad: GCControllerDirectionPad, slot: UInt8) {
        let rawX = dpad.xAxis.value
        let rawY = dpad.yAxis.value
        let touching = rawX != 0 || rawY != 0
        // GameController: x ∈ [-1,1] left→right, y ∈ [-1,1] bottom→top.
        // Host touch space: [0,1] with a top-left origin, so flip Y.
        let nx = (rawX + 1) / 2
        let ny = (1 - rawY) / 2

        if touching, !finger.active {
            finger.active = true
            finger.pointerId = nextTouchPointerId
            nextTouchPointerId &+= 1
            if nextTouchPointerId == 0 { nextTouchPointerId = 1 }
            finger.x = nx; finger.y = ny
            let rc = backend?.sendControllerTouch(
                num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN),
                touchpadIndex: 0, pointerId: finger.pointerId, x: nx, y: ny, pressure: 1.0) ?? -2
            record("LiSendControllerTouchEvent2(down)", rc)
        } else if touching, finger.active {
            if nx != finger.x || ny != finger.y {
                finger.x = nx; finger.y = ny
                let rc = backend?.sendControllerTouch(
                    num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_MOVE),
                    touchpadIndex: 0, pointerId: finger.pointerId, x: nx, y: ny, pressure: 1.0) ?? -2
                record("LiSendControllerTouchEvent2(move)", rc)
            }
        } else if !touching, finger.active {
            finger.active = false
            let rc = backend?.sendControllerTouch(
                num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_UP),
                touchpadIndex: 0, pointerId: finger.pointerId, x: finger.x, y: finger.y, pressure: 0.0) ?? -2
            record("LiSendControllerTouchEvent2(up)", rc)
        }
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
        // GameController invokes this on the main queue; assume MainActor so
        // Swift 6 strict concurrency is satisfied.
        gamepad.extendedGamepad?.valueChangedHandler = { [weak self] (pad, _) in
            // Stamp handler-entry FIRST (measurement-only): the batcher takes this
            // to observe the pre-hop main-thread deliver→enqueue leg. No work moves.
            InputDeliverStamp.shared.stamp(
                slot: Int(slot), nanos: DispatchTime.now().uptimeNanoseconds)
            MainActor.assumeIsolated {
                guard let self else { return }
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
            DualSenseHID.shared.onChange = { [weak self, weak gamepad] in
                guard let self, let ex = gamepad?.extendedGamepad else { return }
                self.sendCenterButtonUpdate(pad: ex, slot: slot)
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
    // live in ControllerForwarder+QuitChord.swift - the topic split.)
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
