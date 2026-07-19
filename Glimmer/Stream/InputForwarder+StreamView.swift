//
//  InputForwarder+StreamView.swift
//
//  The StreamInputViewDelegate conformance (keyboard/mouse/scroll event
//  handling that maps NSEvents to LiSend* uplink calls), plus the HotkeyChord
//  match test and small numeric helpers. Split out of InputForwarder.swift to
//  keep each unit focused.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GameController
import os.log

// MARK: - StreamInputViewDelegate

// StreamInputViewDelegate protocol + StreamInputView NSView subclass live in
// StreamInputView.swift. The delegate conformance is implemented directly
// below.

extension InputForwarder: StreamInputViewDelegate {
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Quit hotkey on key-down only. Don't forward. This check happens
        // BEFORE the sys-key capture gate so a Cmd-bearing quit hotkey (the
        // default ⌃⌘Q) keeps working even when capture is off - that's an
        // intentional Glimmer-level intercept, not a forward to the host.
        if !event.isARepeat, quitHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Quit hotkey detected - invoking onQuitHotkey")
            onQuitHotkey?()
            return true
        }

        // Stats-overlay hotkey. Same intercept story as the quit hotkey:
        // ordered BEFORE the sys-keys gate so a non-Cmd default (⌃⌥S) is
        // honoured regardless of `captureSysKeys`, and a Cmd-bearing custom
        // chord still works when the user has explicitly opted in to capture.
        // Consumed - never forwarded to the host.
        if !event.isARepeat, statsHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Stats hotkey detected - invoking onStatsHotkey")
            onStatsHotkey?()
            return true
        }

        // Telemetry-bookmark chord (signal 4 - "that felt bad"). CLIENT-ONLY:
        // consumed here and NEVER forwarded to the host, exactly like the
        // quit/stats intercepts above (and the exit-chord interception this
        // mirrors). Ordered BEFORE the sys-keys gate so the non-Cmd default (⌃B)
        // fires regardless of `captureSysKeys`. The handler writes a timestamped
        // jank marker into the telemetry.
        //
        // GATED on telemetry being ON: the chord is only intercepted (swallowed)
        // when there's a handler wired AND `TelemetryGate.isEnabled`. With
        // telemetry OFF - the default for normal play - recording the marker
        // would be a no-op (`telemetryExporter` is nil), so swallowing ⌃B would
        // just EAT a keystroke the host should have seen. Letting it fall through
        // to the normal forward path below means ⌃B reaches the host like any
        // other key when there's no live telemetry to bookmark into.
        if !event.isARepeat, onBookmarkHotkey != nil, TelemetryGate.isEnabled,
           bookmarkHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Bookmark hotkey detected - invoking onBookmarkHotkey")
            onBookmarkHotkey?()
            return true
        }

        // macOS Accessibility Zoom keyboard shortcuts. These are pure OS
        // chords with no in-game meaning - if the user accidentally hits one
        // mid-fight (especially ⌥⌘8, which is right next to ⌥⌘9 and ⌥⌘0 that
        // many games bind to ability slots), macOS slams a full-screen zoom
        // on top of the stream. Swallow them BEFORE the sys-keys gate so
        // they're consumed regardless of `captureSysKeys`. Returning `true`
        // from this delegate makes StreamInputView.keyDown skip the
        // `super.keyDown` call, which is what prevents macOS from seeing
        // the event and engaging the zoom - verified by reading
        // StreamInputView.keyDown above, which only walks the responder
        // chain via super when the delegate signals it didn't consume.
        //
        //   ⌥⌘8  - toggle Accessibility Zoom on/off
        //   ⌥⌘=  - zoom in (also ⌥⌘+ on layouts where = needs shift)
        //   ⌥⌘-  - zoom out
        let zoomChars: Set<String> = ["8", "=", "+", "-"]
        let isMacOSZoomChord = mods == [.command, .option]
            && zoomChars.contains(event.charactersIgnoringModifiers ?? "")
        if !event.isARepeat, isMacOSZoomChord {
            // SECURITY: do not log the character - even on this code path
            // (which only fires for ⌥⌘8/=/-/+), an attacker who can race a
            // key bind across this branch could observe arbitrary chars
            // in unified log otherwise. Log keyCode + mods, which are
            // positional and non-sensitive.
            let modsRaw = mods.rawValue
            let keyCode = event.keyCode
            log.info("Swallowed macOS Accessibility Zoom chord mods=\(modsRaw, privacy: .public) keyCode=\(keyCode, privacy: .public)")
            return true
        }

        // Sys-key capture gate. When the user has not opted into forwarding
        // Cmd combos, treat any Cmd-modified key-down as a macOS shortcut and
        // let it fall through to the responder chain. Returning `false` from
        // the delegate tells StreamInputView to call `super.keyDown` instead
        // of swallowing the event, which is what gives macOS a chance to run
        // ⌘-Tab / ⌘-Space / ⌘-H / ⌘-Q etc. natively.
        //
        // Implementation note: `event.isARepeat` events fire while the user
        // is holding a Cmd-letter combo. We let those fall through too - the
        // responder chain has its own auto-repeat semantics for system
        // shortcuts and we don't want to double-fire.
        if mods.contains(.command), !captureSysKeys {
            return false
        }

        // Ignore auto-repeated keys; the host generates its own repeats.
        guard !event.isARepeat, isReady else { return true }
        guard let vk = vkScanCode(forCarbonKeyCode: Int(event.keyCode)) else { return true }
        let wireCode = Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk))
        let rc = backend?.sendKeyboard(
            keyCode: wireCode,
            action: Int8(StreamProtocol.KEY_ACTION_DOWN),
            modifiers: Int8(bitPattern: modifierByte(from: mods)),
            flags: 0
        ) ?? -2
        record("LiSendKeyboardEvent2(down)", rc)
        heldKeys.insert(wireCode)
        return true
    }

    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent) {
        guard isReady else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Mirror the sys-key gate from handleKeyDown: if Cmd is held and
        // capture is off, the matching key-down was never forwarded, so
        // sending the key-up alone would leave the host's keyboard state
        // inconsistent (it would think the key was released without ever
        // having been pressed).
        if mods.contains(.command), !captureSysKeys {
            return
        }

        guard let vk = vkScanCode(forCarbonKeyCode: Int(event.keyCode)) else { return }
        let wireCode = Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk))
        let rc = backend?.sendKeyboard(
            keyCode: wireCode,
            action: Int8(StreamProtocol.KEY_ACTION_UP),
            modifiers: Int8(bitPattern: modifierByte(from: mods)),
            flags: 0
        ) ?? -2
        record("LiSendKeyboardEvent2(up)", rc)
        heldKeys.remove(wireCode)
    }

    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let changed = mods.symmetricDifference(lastModFlags)
        lastModFlags = mods
        guard isReady else { return }

        // Use the OS keyCode to figure out which side (L vs R) of the modifier
        // changed - Win VK has separate codes for LSHIFT (0xA0) and RSHIFT
        // (0xA1), and games sometimes care.
        let modByte = Int8(bitPattern: modifierByte(from: mods))
        let isDown: (NSEvent.ModifierFlags) -> Bool = { mods.contains($0) }

        // Translate the side-specific Carbon keyCode to its Win VK pair.
        let kc = Int(event.keyCode)
        let vkPairs: [(Int, NSEvent.ModifierFlags, Int16)] = [
            (kVK_Control, .control, 0xA2),  // VK_LCONTROL
            (kVK_RightControl, .control, 0xA3),  // VK_RCONTROL
            (kVK_Shift, .shift, 0xA0),  // VK_LSHIFT
            (kVK_RightShift, .shift, 0xA1),  // VK_RSHIFT
            (kVK_Option, .option, 0xA4),  // VK_LMENU
            (kVK_RightOption, .option, 0xA5),  // VK_RMENU
            (kVK_Command, .command, 0x5B),  // VK_LWIN
            (kVK_RightCommand, .command, 0x5C),  // VK_RWIN
            (kVK_CapsLock, .capsLock, 0x14) // VK_CAPITAL
        ]

        // Cmd is a macOS-specific modifier. When sys-key capture is off, we
        // don't want the host to ever see VK_LWIN / VK_RWIN - not even as a
        // bare modifier press - because that would still pop the host's
        // Start menu on key-up. Suppress both left and right Cmd here. Other
        // modifiers (Ctrl → CTRL, Shift → SHIFT, Option → ALT) ARE forwarded
        // because they're not macOS-owned in the same way: most apps treat
        // ⌃/⌥/⇧ as game / app input modifiers, not as system shortcut keys.
        let suppressCmd = !captureSysKeys

        var forwarded = false
        for (codeKC, flag, vk) in vkPairs where kc == codeKC && changed.contains(flag) {
            if suppressCmd && flag == .command {
                forwarded = true   // pretend we did, to skip the fallback loop
                break
            }
            let action: Int8 = isDown(flag) ? Int8(StreamProtocol.KEY_ACTION_DOWN) : Int8(StreamProtocol.KEY_ACTION_UP)
            let rc = backend?.sendKeyboard(
                keyCode: Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)),
                action: action, modifiers: modByte, flags: 0) ?? -2
            record("LiSendKeyboardEvent2(modifier)", rc)
            forwarded = true
            break
        }
        if !forwarded {
            // Fallback when we can't identify the side from the keyCode (e.g.
            // synthetic flagsChanged from sticky-keys). Send the left-side VK
            // for each flag that flipped. Skip `.command` when capture is off.
            let fallback: [(NSEvent.ModifierFlags, Int16)] = [
                (.control, 0xA2), (.shift, 0xA0), (.option, 0xA4), (.command, 0x5B), (.capsLock, 0x14)
            ]
            for (flag, vk) in fallback where changed.contains(flag) {
                if suppressCmd && flag == .command { continue }
                let action: Int8 = isDown(flag) ? Int8(StreamProtocol.KEY_ACTION_DOWN) : Int8(StreamProtocol.KEY_ACTION_UP)
                let rc = backend?.sendKeyboard(
                    keyCode: Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)),
                    action: action, modifiers: modByte, flags: 0) ?? -2
                record("LiSendKeyboardEvent2(modifier fallback)", rc)
            }
        }
    }

    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent) {
        guard isReady else { return }

        // Coalesce queued mouseMoved events the way moonlight-qt does it
        // (SDL_PeepEvents drains all pending SDL_MOUSEMOTION events and
        // sums xrel/yrel into a single LiSendMouseMoveEvent). Without this
        // the host receives one mouse event per macOS NSEvent - at ~120Hz
        // on ProMotion that's ~120 acceleration decisions per second
        // applied to tiny deltas, which feels twitchy / over-accelerated
        // compared to moonlight-qt's behaviour (host accel applied once
        // per coalesced batch). NSEvent doesn't expose SDL_PeepEvents
        // directly, but `nextEvent(matching:until:inMode:dequeue:)` with
        // `until: .distantPast` gives us the same drain-the-queue idiom.
        let initialDeltas = mouseDelta(from: event)
        var accumDx = initialDeltas.dx
        var accumDy = initialDeltas.dy
        // Track the LAST coalesced event's timestamp: the deltas sum through the
        // drained events, so dt must span to the last of them - measuring to the
        // first event inflated the batch velocity whenever coalescing engaged.
        var batchTimestamp = event.timestamp
        // Drags route through this handler too (StreamInputView forwards all
        // *MouseDragged here) - include them in the coalesce mask so a drag
        // batches identically to free motion instead of one-event-per-NSEvent.
        let motionMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        while let queued = window?.nextEvent(matching: motionMask,
                                             until: Date.distantPast,
                                             inMode: .eventTracking,
                                             dequeue: true) {
            let delta = mouseDelta(from: queued)
            accumDx += delta.dx
            accumDy += delta.dy
            batchTimestamp = queued.timestamp
        }

        // DRAG-DELTA compensation (before Cruise, so the velocity gate sees the
        // corrected motion): macOS damps dragged deltas vs free motion for the
        // same hand speed (owner-verified matched-speed swipes, macOS 27 beta).
        // Scale button-held batches back to parity; 1.0 disables.
        let isDragBatch = event.type != .mouseMoved
        if isDragBatch {
            let scale = CruiseTraversal.dragDeltaScale
            if scale != 1.0 {
                accumDx *= scale
                accumDy *= scale
            }
        }

        // CRUISE traversal boost (InputForwarder+Cruise.swift). Velocity-gated,
        // resolution-derived gain on ONLY fast flicks - aim (sub-knee) is untouched.
        // Runs AFTER the Mac linearization, so it's the only client gain. dt is the
        // inter-batch interval; the gate reads a SHORT velocity EMA (per-batch
        // instantaneous v jitters ~±30%, flickering the gain through the ramp -
        // the mushy feel). A post-gap batch seeds the EMA to the raw v, so flick
        // onset carries zero added lag. Below the knee the gain is exactly 1.0
        // and accumDx/Dy are unchanged, so the residual path below runs
        // byte-for-byte as it does today.
        let now = batchTimestamp
        if CruiseTraversal.isEnabled, cruiseGMax > 1.0 {
            let dt = now - lastMoveTimestamp
            var velocity: Double = 0
            if dt > 0 && dt <= 0.1 {
                // WINDOWED velocity (~30ms exponential window of Σdist/Σtime):
                // immune to delivery-cadence variation by construction. A 1ms
                // device-rate batch adds tiny distance AND tiny time, so the
                // ratio can neither spike (the "crazy sensitive" incident) nor
                // understate (the dt-floor chop: per-batch dist/dt flapped 4x
                // as macOS alternated coalesced and per-event delivery). Needs
                // ≥4ms of accumulated window before the gate trusts it, so a
                // post-gap first batch stays identity.
                let decay = exp(-dt / 0.030)
                cruiseDistAccum = cruiseDistAccum * decay + hypot(accumDx, accumDy)
                cruiseTimeAccum = cruiseTimeAccum * decay + dt
                if cruiseTimeAccum >= 0.004 {
                    velocity = cruiseDistAccum / cruiseTimeAccum
                }
            } else {
                cruiseDistAccum = 0
                cruiseTimeAccum = 0
            }
            let g = CruiseTraversal.gain(velocity: velocity, dt: dt, gMax: cruiseGMax,
                                         vKnee: CruiseTraversal.vKnee, vFull: CruiseTraversal.vFull)
            // Cruise forensics (telemetry-on only): velocity + gain
            // distributions split MOVE vs DRAG - the data a drag-specific band
            // tune needs (menu drag-pans vs held-button aim share this path).
            if let tracker = FrameTimingTracker.shared, velocity > 0 {
                (isDragBatch ? tracker.cruiseVelocityDrag : tracker.cruiseVelocityMove)
                    .observe(velocity)
                if g > 1.0 {
                    (isDragBatch ? tracker.cruiseGainDrag : tracker.cruiseGainMove).observe(g)
                }
            }
            if g > 1.0 {
                accumDx *= g
                accumDy *= g
                TelemetryCounters.shared.cruiseBoostedBatchesTotal.increment()
                TelemetryCounters.shared.noteCruiseGain(g)
            } else if accumDx != 0 || accumDy != 0 {
                TelemetryCounters.shared.cruiseIdentityBatchesTotal.increment()
            }
        }
        lastMoveTimestamp = now

        // The CGEvent path returns integer pixel deltas, so the residual
        // accumulator normally stays at zero and we forward the value as-is.
        // It still carries any sub-pixel fraction forward for the rare
        // NSEvent.deltaX/Y fallback (an event with no CGEvent backing), so
        // slow trackpad motion under 1px/event isn't rounded away.
        mouseResidualX += accumDx
        mouseResidualY += accumDy  // macOS deltaY is down-positive - matches Windows VK input.
        let dxInt = Int(mouseResidualX.rounded(.towardZero))
        let dyInt = Int(mouseResidualY.rounded(.towardZero))
        if dxInt != 0 || dyInt != 0 {
            mouseResidualX -= Double(dxInt)
            mouseResidualY -= Double(dyInt)
            let outDx = Int16(clamping: dxInt)
            let outDy = Int16(clamping: dyInt)
            let rc = backend?.sendMouseMove(dx: outDx, dy: outDy) ?? -2
            record("LiSendMouseMoveEvent", rc)
        }

        // Don't spam absolute position on every motion event - that's a
        // mode the host enters separately for Desktop apps. Most games want
        // relative-only and absolute updates compete with the relative
        // deltas, causing jitter. The mouseDown handlers below send a
        // single absolute position so click locations are correct.

        // No warp-to-centre here. Under the SDL associate-false model
        // (enterCapturedMode) the OS does not move the system cursor at all, so
        // it can never reach a screen edge / hot corner - the per-motion
        // warpCursorIfNearEdge defense (and the edge→centre reconciliation delta
        // it leaked, the P0 mouse-snap bug) is gone by construction. Deltas read
        // off kCGMouseEventDeltaX/Y are pure relative HID; nothing post-warp can
        // be injected because nothing warps.

        // No per-motion cursor re-hide here. Steady-state invisibility over the
        // stream is owned by the transparent NSCursor in
        // `StreamInputView.cursorUpdate(with:)`, which AppKit re-invokes on every
        // pointer motion over the view - so after ANY OS-initiated re-show
        // (display/HDR/VRR reconfig, sleep-wake, HID attach) the very next motion
        // event re-applies the invisible image with ZERO flash. The old
        // net-neutral CGDisplayShowCursor→HideCursor reassert fired here on every
        // move and let the WindowServer (compositing on its own vsync, not our
        // runloop turn) sample the cursor in the gap between the paired calls -
        // that was the motion-correlated arrow flash. Deleted.
    }

    func streamView(_ view: StreamInputView, handleMouseDown event: NSEvent) {
        guard isReady else { return }
        let hostButton = button(for: event)
        let rc = backend?.sendMouseButton(
            action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: hostButton) ?? -2
        record("LiSendMouseButtonEvent(press)", rc)
        heldMouseButtons.insert(hostButton)
    }

    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent) {
        guard isReady else { return }
        let hostButton = button(for: event)
        let rc = backend?.sendMouseButton(
            action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: hostButton) ?? -2
        record("LiSendMouseButtonEvent(release)", rc)
        heldMouseButtons.remove(hostButton)
    }

    func streamView(_ view: StreamInputView, handleScroll event: NSEvent) {
        guard isReady else { return }
        // DEADZONE REMOVED. This handler
        // used to clamp each event's delta to ±1.0 line before the WHEEL_DELTA
        // scale - a per-event magnitude cap added
        // because a third-party mouse driver's button-pan flooded synthetic scroll events
        // that the host's camera-zoom mapping amplified into wild zooming.
        // That cap punished legitimate input:
        // macOS scroll acceleration reports a fast wheel spin as multi-line
        // deltas per event, which the clamp flattened to one line each - fast
        // scrolling crawled no matter how hard the wheel was spun. Scroll now
        // passes through at its reported magnitude.
        //
        // Unit normalisation (required for clean pass-through once the cap is
        // gone): wheel mice report scrollingDelta in LINES; precise devices
        // (trackpads, Magic Mouse, smooth-scroll drivers) report PIXELS,
        // which would overshoot ~10× fed raw into the line-based WHEEL_DELTA
        // scale. SDL's macOS backend (SDL_cocoamouse.m) converts precise
        // deltas at 0.1 pixels→lines - the exact values moonlight-qt's
        // non-Darwin path forwards as preciseY * 120 - so use the same
        // factor. Sub-half-unit results round to zero and are skipped (the
        // wire can't carry them; the next event in a momentum tail carries
        // fresh magnitude, so nothing accumulates wrongly).
        let lineScale = event.hasPreciseScrollingDeltas ? 0.1 : 1.0
        let y = Double(event.scrollingDeltaY) * lineScale
        if y != 0 {
            let amt = Int16(clamping: Int((y * 120).rounded()))
            if amt != 0 {
                let rc = backend?.sendScroll(amt) ?? -2
                record("LiSendHighResScrollEvent", rc)
            }
        }
        let x = Double(event.scrollingDeltaX) * lineScale
        if x != 0 {
            let amt = Int16(clamping: Int((x * 120).rounded()))
            if amt != 0 {
                let rc = backend?.sendHScroll(amt) ?? -2
                record("LiSendHighResHScrollEvent", rc)
            }
        }
    }

    private func button(for event: NSEvent) -> Int32 {
        switch event.type {
        case .leftMouseDown, .leftMouseUp:   return StreamProtocol.BUTTON_LEFT
        case .rightMouseDown, .rightMouseUp: return StreamProtocol.BUTTON_RIGHT
        case .otherMouseDown, .otherMouseUp:
            // NSEvent.buttonNumber: 0=L, 1=R, 2=middle, 3=back/X1, 4=forward/X2
            switch event.buttonNumber {
            case 2: return StreamProtocol.BUTTON_MIDDLE
            case 3: return StreamProtocol.BUTTON_X1
            case 4: return StreamProtocol.BUTTON_X2
            default: return StreamProtocol.BUTTON_MIDDLE
            }
        default: return StreamProtocol.BUTTON_LEFT
        }
    }
}

// MARK: - HotkeyChord matching
// HotkeyChord is defined in AppModel.swift - reused here so the user's
// chosen combos (quit, stats, ...) apply in-stream without a separate config
// path. One match function handles every chord-style hotkey we intercept.

extension HotkeyChord {
    func matches(event: NSEvent, modifiers mods: NSEvent.ModifierFlags) -> Bool {
        if (ctrl && !mods.contains(.control)) || (!ctrl && mods.contains(.control)) { return false }
        if (alt && !mods.contains(.option))    || (!alt && mods.contains(.option)) { return false }
        if (shift && !mods.contains(.shift))   || (!shift && mods.contains(.shift)) { return false }
        if (cmd && !mods.contains(.command))   || (!cmd && mods.contains(.command)) { return false }
        return event.charactersIgnoringModifiers?.lowercased() == keyChar.lowercased()
    }
}

// `vkScanCode(forCarbonKeyCode:)` lives in KeyboardScanMap.swift.
