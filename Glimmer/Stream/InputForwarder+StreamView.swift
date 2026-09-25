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
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Quit hotkey, key-down only and never forwarded. Checked before the
        // ⌘ gate so a custom chord with ⌘ still quits while ⌘ is the Mac's.
        if !event.isARepeat, quitHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Quit hotkey detected - leaving the stream")
            quitOrCancelConnect()
            return
        }

        // Stats-overlay hotkey. Same intercept story as the quit hotkey:
        // ordered BEFORE the sys-keys gate so a non-Cmd default (⌃⌥S) is
        // honoured regardless of `captureSysKeys`, and a Cmd-bearing custom
        // chord still works when the user has explicitly opted in to capture.
        // Consumed - never forwarded to the host.
        if !event.isARepeat, statsHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Stats hotkey detected - invoking onStatsHotkey")
            onStatsHotkey?()
            return
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
        if !event.isARepeat, onBookmarkHotkey != nil,
           bookmarkHotkeyProvider().matches(event: event, modifiers: mods), TelemetryGate.isEnabled {
            log.info("Bookmark hotkey detected - invoking onBookmarkHotkey")
            onBookmarkHotkey?()
            return
        }

        // Pointer chord - WINDOW MODE ONLY, and a TOGGLE: it captures a free
        // pointer and frees a captured one, so the combo is never a dead key
        // and a user who learned it keeps it. Same client-only intercept as
        // quit/stats, and ordered BEFORE the sys-keys gate for the same
        // reason. In full screen capture follows key status and there is
        // nothing to toggle, so the chord is never intercepted there and
        // reaches the host like any key.
        if !event.isARepeat, isWindowMode,
           releasePointerHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Pointer hotkey detected - toggling capture")
            togglePointerCapture(reason: "pointer chord")
            return
        }

        // Mini player chord: the same client-only intercept as quit/stats,
        // and the way back to the full presentation from inside the panel.
        if !event.isARepeat, miniPlayerHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Mini player hotkey detected - toggling")
            onMiniPlayerHotkey?()
            return
        }

        // Until the first connection is live the invisible stream window holds
        // key focus, so a bare Esc cancels the connect as the launcher's would.
        // From then on Esc is game input, reconnects included.
        if initialConnectPending, !event.isARepeat, Int(event.keyCode) == kVK_Escape,
           mods.isDisjoint(with: [.command, .option, .control, .shift]) {
            log.info("Esc before the stream went live - cancelling the connect")
            quitOrCancelConnect()
            return
        }

        // Paste chord (moonlight's ⌃⌥⇧V): types the Mac clipboard into the PC.
        if !event.isARepeat, PasteText.chord.matches(event: event, modifiers: mods) {
            pasteClipboardAsText()
            return
        }

        // Hold Esc to free the pointer (window mode, captured only). NOT
        // consumed and never returns early: Esc is a game input, so the tap
        // that opens a menu must forward on this very event with no added
        // latency. Only a ~1s hold releases; see InputForwarder+EscapeHold.
        noteEscapeKeyDown(event)

        // Unless ⌘ goes to the game (opted in and the pointer held) a ⌘ chord
        // is the Mac's and never forwarded. Repeats are dropped: the PC makes its own.
        if mods.contains(.command), !forwardsCommand { return }
        guard !event.isARepeat, isReady else { return }
        guard let key = vkScanCode(forCarbonKeyCode: Int(event.keyCode)) else {
            noteUnmappedKey(event.keyCode)
            return
        }
        if modifiersNeedResync { syncModifiers(to: event.modifierFlags) }
        let rc = backend?.sendKeyboard(
            keyCode: key.wireCode,
            action: Int8(StreamProtocol.KEY_ACTION_DOWN),
            modifiers: Int8(bitPattern: modifierByte(from: mods)),
            flags: key.flags
        ) ?? -2
        record("LiSendKeyboardEvent2(down)", rc)
        heldKeys.insert(key)
    }

    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent) {
        guard !isDuplicateKeyUp(event) else { return }
        // Cancel a pending Esc hold FIRST, ahead of every gate below: a tap
        // must behave exactly as it did before the gesture existed, including
        // while the stream is mid-handshake and forwarding nothing.
        noteEscapeKeyUp(event)
        // Only a key the host holds gets an up: a down under the ⌘ gate never
        // went out, and one released on focus loss or a reconnect already did.
        guard isReady, let key = vkScanCode(forCarbonKeyCode: Int(event.keyCode)),
              heldKeys.remove(key) != nil else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let rc = backend?.sendKeyboard(
            keyCode: key.wireCode,
            action: Int8(StreamProtocol.KEY_ACTION_UP),
            modifiers: Int8(bitPattern: modifierByte(from: mods)),
            flags: key.flags
        ) ?? -2
        record("LiSendKeyboardEvent2(up)", rc)
    }

    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent) {
        let capsLock = event.modifierFlags.contains(.capsLock)
        let capsChanged = capsLock != lastCapsLock
        lastCapsLock = capsLock
        guard isReady else { return }
        syncModifiers(to: event.modifierFlags)
        // Windows toggles Caps Lock on each press, so a Mac toggle is one full
        // press and release, and nothing is left held on the PC.
        if capsChanged {
            let modByte = Int8(bitPattern: modifierByte(from: event.modifierFlags))
            sendModifier(0x14, down: true, modByte: modByte) // VK_CAPITAL
            sendModifier(0x14, down: false, modByte: modByte)
        }
    }

    /// Send the modifier sides that changed since the host was last told, so
    /// a Shift held through a reconnect, sleep or screen lock reaches the PC.
    /// Each SIDE is its own entry; ⌘ only counts while `forwardsCommand`.
    private func syncModifiers(to flags: NSEvent.ModifierFlags) {
        let downNow = ModifierSides.held(in: flags, includeCommand: forwardsCommand)
        let modByte = Int8(bitPattern: modifierByte(from: flags))
        for vk in heldModifierVKs.subtracting(downNow).sorted() { sendModifier(vk, down: false, modByte: modByte) }
        for vk in downNow.subtracting(heldModifierVKs).sorted() { sendModifier(vk, down: true, modByte: modByte) }
        heldModifierVKs = downNow
        modifiersNeedResync = false
    }

    /// Before the stream is live, leaving is the launcher's cancel, so the
    /// connect ends as cancelled rather than failed.
    private func quitOrCancelConnect() {
        if initialConnectPending, let onCancelConnect { onCancelConnect() } else { onQuitHotkey?() }
    }

    func sendModifier(_ vk: Int16, down: Bool, modByte: Int8) {
        let action: Int8 = down ? Int8(StreamProtocol.KEY_ACTION_DOWN) : Int8(StreamProtocol.KEY_ACTION_UP)
        let rc = backend?.sendKeyboard(
            keyCode: VKScanCode(vk: vk).wireCode,
            action: action, modifiers: modByte, flags: 0) ?? -2
        record("LiSendKeyboardEvent2(modifier)", rc)
    }

    /// One notice per unmapped key per session, so a key that does nothing on
    /// the PC can be diagnosed from the log.
    private func noteUnmappedKey(_ keyCode: UInt16) {
        guard loggedUnmappedKeyCodes.insert(keyCode).inserted else { return }
        Diag.notice("input: key code \(keyCode) has no PC mapping and was not sent", "Stream")
    }

    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent) {
        guard isReady, forwardsMouseEvents else { return }

        // WINDOW MODE with the pointer free: the host cursor tracks this Mac's
        // cursor 1:1, so send WHERE the pointer is rather than how far it
        // moved. Everything below - the coalescing drain, the drag-delta
        // compensation, Cruise, the sub-pixel residual - exists to make
        // RELATIVE aim feel right and would actively break a 1:1 mapping, so
        // the absolute path returns before any of it. Drags route through this
        // handler too, so a held button tracks the same way. Constant `false`
        // in full screen: nothing here changes for the fullscreen path.
        if sendsAbsolutePointer {
            sendAbsolutePointer(for: event, in: view)
            return
        }

        // Coalescing matches moonlight-qt's single acceleration decision per
        // batch. Stop at the queue's first non-motion event so input order
        // stays intact across clicks and key presses.
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
        MouseMotionDrain.drain(
            peek: { window?.nextEvent(matching: .any, until: .distantPast,
                                      inMode: .eventTracking, dequeue: false) },
            dequeue: { window?.nextEvent(matching: MouseMotionDrain.mask, until: .distantPast,
                                         inMode: .eventTracking, dequeue: true) },
            consume: { queued in
                let delta = mouseDelta(from: queued)
                accumDx += delta.dx
                accumDy += delta.dy
                batchTimestamp = queued.timestamp
            }
        )

        // DRAG-DELTA compensation, only while raw aim has linearised the pointer:
        // that mode damps dragged deltas vs free motion (owner-measured, macOS 27).
        // With acceleration untouched, drags already match moves. 1.0 disables.
        let isDragBatch = event.type != .mouseMoved
        if isDragBatch && savedLinearScaling != nil {
            let scale = cruiseTuning.dragDeltaScale
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
        if cruiseGMax > 1.0 {
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
                                         vKnee: cruiseTuning.vKnee, vFull: cruiseTuning.vFull)
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
        // Send only what fits the wire's Int16 and keep the rest in the residual,
        // so an oversized batch never loses the overflow to the clamp.
        let outDx = Int16(clamping: Int(mouseResidualX.rounded(.towardZero)))
        let outDy = Int16(clamping: Int(mouseResidualY.rounded(.towardZero)))
        if outDx != 0 || outDy != 0 {
            mouseResidualX -= Double(outDx)
            mouseResidualY -= Double(outDy)
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
        guard isReady, forwardsMouseEvents else { return }
        // Mini player: the click is the grab, and it still reaches the host
        // so the button under the pointer is pressed, not just aimed at.
        if isMiniPlayer, !isMouseCaptured { capturePointer(reason: "click on the mini player") }
        // A click in a window reaches the HOST - that is the whole point of
        // absolute mode, and the reason click-to-capture is gone. Send the
        // position first so the host's cursor is under the click before the
        // button lands, even if the last motion event was coalesced away.
        // No-op in full screen and while captured.
        sendAbsolutePointer(for: event, in: view)
        let hostButton = button(for: event)
        let rc = backend?.sendMouseButton(
            action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: hostButton) ?? -2
        record("LiSendMouseButtonEvent(press)", rc)
        heldMouseButtons.insert(hostButton)
    }

    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent) {
        guard isReady, forwardsMouseEvents else { return }
        let hostButton = button(for: event)
        // Window mode: never send a release for a press the host has already
        // been told about. `releasePointer` raises held buttons first, so a
        // button held through a capture release would otherwise double-release
        // when the physical up arrives.
        if isWindowMode, !heldMouseButtons.contains(hostButton) { return }
        // Land the release where the pointer actually ended up - a drag that
        // moved between down and up must not release at the down position.
        sendAbsolutePointer(for: event, in: view)
        let rc = backend?.sendMouseButton(
            action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: hostButton) ?? -2
        record("LiSendMouseButtonEvent(release)", rc)
        heldMouseButtons.remove(hostButton)
    }

    /// Window mode's grab: the pointer crossing onto the picture takes it, no
    /// click and nothing to press. Deliberately NOT gated on `isReady` - the
    /// grab is about who owns the mouse, not about whether frames are flowing,
    /// and a stream still handshaking must not hand the pointer to the Mac
    /// mid-connect only to snatch it back. The rule itself (and its inertness
    /// in full screen) lives in InputForwarder+HoverCapture.swift.
    func streamViewPointerDidEnter(_ view: StreamInputView) {
        notePointerEnteredStreamView()
    }

    /// The pointer left the picture. Only interesting as the thing that clears
    /// a release latch, so a return can grab again.
    func streamViewPointerDidExit(_ view: StreamInputView) {
        notePointerExitedStreamView()
    }

    func streamView(_ view: StreamInputView, handleScroll event: NSEvent) {
        guard isReady, forwardsMouseEvents else { return }
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
        //
        // Whole notches for precise devices: a trackpad arrives as 40-100 unit
        // slices, which a game dividing by WHEEL_DELTA (120) reads as zero. A
        // mouse wheel's units go out unchanged, as moonlight sends them.
        let precise = event.hasPreciseScrollingDeltas
        let lineScale = precise ? 0.1 : 1.0
        let y = Int((Double(event.scrollingDeltaY) * lineScale * 120).rounded())
        let sendY = Int16(clamping: scrollQuantizer.consumeVertical(y, precise: precise))
        if sendY != 0 {
            let rc = backend?.sendScroll(sendY) ?? -2
            record("LiSendHighResScrollEvent", rc)
        }
        let x = Int((Double(event.scrollingDeltaX) * lineScale * 120).rounded())
        let sendX = Int16(clamping: scrollQuantizer.consumeHorizontal(x, precise: precise))
        if sendX != 0 {
            let rc = backend?.sendHScroll(sendX) ?? -2
            record("LiSendHighResHScrollEvent", rc)
        }
        // Trace: what macOS delivered and what went out, on the frame trace's clock.
        if let tracker = FrameTimingTracker.shared {
            let nowMs = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
            tracker.traceWriter.append(
                "{\"session\":\"\(tracker.sessionId)\",\"event\":\"input_scroll\","
                + "\"precise\":\(precise),"
                + "\"dy\":\(TelemetryRenderer.jsonNumber(Double(event.scrollingDeltaY))),"
                + "\"dx\":\(TelemetryRenderer.jsonNumber(Double(event.scrollingDeltaX))),"
                + "\"units_y\":\(y),\"sent_y\":\(sendY),\"sent_x\":\(sendX),"
                + "\"phase\":\(event.phase.rawValue),\"momentum\":\(event.momentumPhase.rawValue),"
                + "\"t_ms\":\(TelemetryRenderer.jsonNumber(nowMs))}")
        }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            scrollQuantizer.reset()
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

enum MouseMotionDrain {
    static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    static func drain(peek: () -> NSEvent?, dequeue: () -> NSEvent?, consume: (NSEvent) -> Void) {
        while let head = peek(), mask.contains(NSEvent.EventTypeMask(type: head.type)),
              let event = dequeue() {
            consume(event)
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
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if typed == keyChar.lowercased() { return true }
        // A non-Latin layout types a local letter (й for Q), so match the key's
        // US position instead, as moonlight does. Latin layouts keep theirs.
        guard !typed.allSatisfy(\.isASCII),
              let vk = vkScanCode(forCarbonKeyCode: Int(event.keyCode))?.vk,
              (0x30...0x39).contains(vk) || (0x41...0x5A).contains(vk) else { return false }
        return String(Character(Unicode.Scalar(UInt8(vk)))).lowercased() == keyChar.lowercased()
    }
}

// `vkScanCode(forCarbonKeyCode:)` lives in KeyboardScanMap.swift.
