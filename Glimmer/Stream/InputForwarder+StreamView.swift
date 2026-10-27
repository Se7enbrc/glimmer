// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Stream responders share one chord matcher so local shortcuts agree across entry points.

import GlimmerEngine
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
        if consumeStopShortcut(event, entry: "keyDown") { return }
        if deferKeyboardEvent({ $0.streamView(view, handleKeyDown: event) }) { return }
        forwardKeyDown(event, in: view)
    }

    /// Stop is local and must remain available while text or PC modifier releases are pending.
    func consumeStopShortcut(_ event: NSEvent, entry: String) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chord = quitHotkeyProvider()
        guard let match = chord.matchKind(event: event, modifiers: mods) else { return false }
        if !event.isARepeat {
            Diag.info("Quit hotkey matched: entry=\(entry) match=\(match.rawValue) chord=\(chord.displayString) "
                + "windowMode=\(isWindowMode) generation=\(inputGeneration) miniPlayer=\(isMiniPlayer)", "Stream.Input")
            quitOrCancelConnect()
        }
        return true
    }

    private func forwardKeyDown(_ event: NSEvent, in view: StreamInputView) {
        InputTimingContext.begin(source: .keyboard, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        noteInputEvent(keyCode: event.keyCode)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if view.hasMarkedText(), !mods.isDisjoint(with: [.command, .control]) { view.cancelComposition() }
        releaseStaleModifiers(for: event)
        noteEscapeModifiersChanged(event.modifierFlags)

        // Client chords precede the Command gate so custom shortcuts work in either mode.
        if !event.isARepeat, statsHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Stats hotkey detected - invoking onStatsHotkey")
            onStatsHotkey?()
            return
        }

        // Without live telemetry a bookmark would do nothing, so let the PC use the chord.
        if !event.isARepeat, onBookmarkHotkey != nil,
           bookmarkHotkeyProvider().matches(event: event, modifiers: mods), bookmarkEnabled() {
            log.info("Bookmark hotkey detected - invoking onBookmarkHotkey")
            onBookmarkHotkey?()
            return
        }

        // The same chord frees or captures the pointer in every presentation.
        if !event.isARepeat,
           releasePointerHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Pointer hotkey detected - toggling capture")
            togglePointerCapture(reason: "pointer chord")
            return
        }

        // The mini player chord also returns to the full presentation from the panel.
        if !event.isARepeat, miniPlayerHotkeyProvider().matches(event: event, modifiers: mods) {
            log.info("Mini player hotkey detected - toggling")
            onMiniPlayerHotkey?()
            return
        }

        // Before the first connection, bare Escape cancels like the launcher.
        // Once live, Escape belongs to the PC, including during reconnects.
        if initialConnectPending, !event.isARepeat, Int(event.keyCode) == kVK_Escape,
           mods.isDisjoint(with: [.command, .option, .control, .shift]) {
            log.info("Esc before the stream went live - cancelling the connect")
            quitOrCancelConnect()
            return
        }
        // Paste types the Mac clipboard into the PC independently of keyboard layout.
        if !event.isARepeat, PasteText.chord.matches(event: event, modifiers: mods) {
            pasteClipboardAsText()
            return
        }
        // Composition owns Escape; a reconnect must still allow the pointer hold.
        if !view.hasMarkedText() { noteEscapeKeyDown(event) }

        // Unless ⌘ goes to the PC (opted in and the stream key) a ⌘ chord
        // is the Mac's and never forwarded. Repeats are dropped: the PC makes its own.
        if mods.contains(.command), !forwardsCommand { return }
        guard isReady, ownsKeyboard, flushPendingReleases() else { return }
        if !isMouseCaptured, view.handleTextInput(event) { return }
        sendPhysicalKeyDown(event, modifiers: mods)
    }

    private func sendPhysicalKeyDown(_ event: NSEvent, modifiers mods: NSEvent.ModifierFlags) {
        guard !event.isARepeat else { return }
        guard let key = keyMapping(Int(event.keyCode)) else {
            noteUnmappedKey(event.keyCode)
            return
        }
        if modifiersNeedResync, !syncModifiers(to: event.modifierFlags) { return }
        guard physicalKeys[event.keyCode] == nil else { return }
        guard inputCore.pressKey(key, modifiers: Int8(bitPattern: modifierByte(from: mods))) else { return }
        physicalKeys[event.keyCode] = key
        heldKeys.insert(key)
        updateReconciliationTimer()
    }

    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent) {
        if deferKeyboardEvent({ $0.streamView(view, handleKeyUp: event) }) { return }
        InputTimingContext.begin(source: .keyboard, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        if let key = physicalKeys[event.keyCode] { InputTimingContext.allowRelease(.key(key)) }
        noteInputEvent(keyCode: event.keyCode)
        guard !isDuplicateKeyUp(event) else { return }
        // Cancel a pending Esc hold FIRST, ahead of every gate below: a tap
        // must behave exactly as it did before the gesture existed, including
        // while the stream is mid-handshake and forwarding nothing.
        noteEscapeKeyUp(event)
        releaseStaleModifiers(for: event)
        releaseKey(event.keyCode, modifiers: Int8(bitPattern: modifierByte(from: event.modifierFlags)))
    }

    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent) {
        if deferKeyboardEvent({ $0.streamView(view, handleFlagsChanged: event) }) { return }
        missingModifierVKs.removeAll()
        defer { missingModifierVKs.removeAll() }
        InputTimingContext.begin(source: .keyboard, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        InputTimingContext.allowModifierReleases()
        noteInputEvent()
        noteEscapeModifiersChanged(event.modifierFlags)
        let capsLock = event.modifierFlags.contains(.capsLock)
        let capsChanged = capsLock != lastCapsLock
        lastCapsLock = capsLock
        guard isReady, ownsKeyboard else { return }
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
    @discardableResult
    private func syncModifiers(to flags: NSEvent.ModifierFlags) -> Bool {
        let downNow = ModifierSides.held(in: flags, includeCommand: forwardsCommand)
        let modByte = Int8(bitPattern: modifierByte(from: flags))
        for vk in heldModifierVKs.subtracting(downNow).sorted() { sendModifier(vk, down: false, modByte: modByte) }
        heldModifierVKs.formIntersection(downNow)
        modifiersNeedResync = true
        guard flushPendingReleases() else { return false }
        for vk in downNow.subtracting(heldModifierVKs).sorted() {
            guard sendModifier(vk, down: true, modByte: modByte) else { return false }
            heldModifierVKs.insert(vk)
        }
        modifiersNeedResync = false
        updateReconciliationTimer()
        return true
    }

    /// An interrupted client chord can lose its modifier-up. Recover before
    /// forwarding the next key, including repeats, without latching posted flags.
    private func releaseStaleModifiers(for event: NSEvent) {
        let released = ModifierSides.released(from: heldModifierVKs, in: event.modifierFlags,
                                              includeCommand: forwardsCommand)
        let modByte = Int8(bitPattern: modifierByte(from: event.modifierFlags))
        for vk in released.sorted() { sendModifier(vk, down: false, modByte: modByte) }
        heldModifierVKs.subtract(released)
    }

    /// Before the stream is live, leaving is the launcher's cancel, so the
    /// connect ends as cancelled rather than failed.
    private func quitOrCancelConnect() {
        if initialConnectPending, let onCancelConnect { onCancelConnect() } else { onQuitHotkey?() }
    }

    @discardableResult
    func sendModifier(_ vk: Int16, down: Bool, modByte: Int8) -> Bool {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        let key = VKScanCode(vk: vk)
        if !down {
            releases.release(.key(key), modifiers: modByte)
            return flushPendingReleases()
        }
        guard isReady, ownsKeyboard, flushPendingReleases() else { return false }
        releases.hold(.key(key))
        let rc = backend?.sendKeyboard(keyCode: key.wireCode, action: Int8(StreamProtocol.KEY_ACTION_DOWN),
                                       modifiers: modByte, flags: 0) ?? -2
        record("LiSendKeyboardEvent2(modifier)", rc)
        return rc == 0
    }

    /// One notice per unmapped key per session, so a key that does nothing on
    /// the PC can be diagnosed from the log.
    private func noteUnmappedKey(_ keyCode: UInt16) {
        guard loggedUnmappedKeyCodes.insert(keyCode).inserted else { return }
        Diag.notice("input: an unmapped key was not sent", "Stream")
    }

    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent) {
        InputTimingContext.begin(source: .mouse, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        noteInputEvent()
        guard isReady, forwardsMouseEvents else { return }

        // Absolute positions bypass relative coalescing, Cruise and residuals;
        // applying a velocity curve here would break the picture's 1:1 mapping.
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
                guard view.acceptsMotion(queued) else { return }
                InputTimingContext.coalesced(timestamp: queued.timestamp)
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
        inputCore.sendRelativePointer(dx: accumDx, dy: accumDy)

        // Don't spam absolute position on every motion event - that's a
        // mode the host enters separately for Desktop apps. Most games want
        // relative-only and absolute updates compete with the relative
        // deltas, causing jitter. The mouseDown handlers below send a
        // single absolute position so click locations are correct.

        // Cursor visibility belongs to StreamWindow and the input view.
    }

    func streamView(_ view: StreamInputView, handleMouseDown event: NSEvent) {
        if view.hasMarkedText() { view.cancelComposition() }
        InputTimingContext.begin(source: .mouse, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        noteInputEvent()
        guard isReady, forwardsMouseEvents, flushPendingReleases() else { return }
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
        physicalMouseButtons[event.buttonNumber] = hostButton
        updatePhysicalMouseButton(hostButton, pressed: true)
        updateReconciliationTimer()
    }

    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent) {
        InputTimingContext.begin(source: .mouse, timestamp: event.timestamp)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        InputTimingContext.allowRelease(.mouse(button(for: event)))
        noteInputEvent()
        let hostButton = button(for: event)
        guard releases.held.contains(.mouse(hostButton)) else { return }
        // A drag releases at its final position even when the last motion was coalesced.
        if isReady, forwardsMouseEvents { sendAbsolutePointer(for: event, in: view) }
        physicalMouseButtons[event.buttonNumber] = nil
        if !physicalMouseButtons.values.contains(hostButton) { releaseMouse(hostButton) }
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
        InputTimingContext.begin(source: .mouse, timestamp: event.timestamp, handler: DispatchTime.now().uptimeNanoseconds)
        defer { InputTimingContext.end() }
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        noteInputEvent()
        guard isReady, forwardsMouseEvents else { return }
        let precise = event.hasPreciseScrollingDeltas
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
        let sent = inputCore.sendScroll(x: Double(event.scrollingDeltaX), y: Double(event.scrollingDeltaY),
                                        precise: precise, ended: ended)
        // Trace: what macOS delivered and what went out, on the frame trace's clock.
        if let tracker = FrameTimingTracker.shared {
            let nowMs = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
            tracker.traceWriter.append(
                "{\"session\":\"\(tracker.sessionId)\",\"event\":\"input_scroll\","
                + "\"precise\":\(precise),"
                + "\"dy\":\(TelemetryRenderer.jsonNumber(Double(event.scrollingDeltaY))),"
                + "\"dx\":\(TelemetryRenderer.jsonNumber(Double(event.scrollingDeltaX))),"
                + "\"units_y\":\(sent.unitsY),\"sent_y\":\(sent.sentY),\"sent_x\":\(sent.sentX),"
                + "\"phase\":\(event.phase.rawValue),\"momentum\":\(event.momentumPhase.rawValue),"
                + "\"t_ms\":\(TelemetryRenderer.jsonNumber(nowMs))}")
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
// One match function handles every chord-style hotkey we intercept.

extension HotkeyChord {
    enum MatchKind: String {
        case character
        case keyPositionFallback = "key-position-fallback"
    }

    func matches(event: NSEvent, modifiers mods: NSEvent.ModifierFlags) -> Bool {
        matchKind(event: event, modifiers: mods) != nil
    }

    func matchKind(event: NSEvent, modifiers mods: NSEvent.ModifierFlags) -> MatchKind? {
        if (ctrl && !mods.contains(.control)) || (!ctrl && mods.contains(.control)) { return nil }
        if (alt && !mods.contains(.option))    || (!alt && mods.contains(.option)) { return nil }
        if (shift && !mods.contains(.shift))   || (!shift && mods.contains(.shift)) { return nil }
        if (cmd && !mods.contains(.command))   || (!cmd && mods.contains(.command)) { return nil }
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if typed == keyChar.lowercased() { return .character }
        // A non-Latin layout types a local letter (й for Q), so match the key's
        // US position instead, as moonlight does. Latin layouts keep theirs.
        guard !typed.allSatisfy(\.isASCII),
              let vk = vkScanCode(forCarbonKeyCode: Int(event.keyCode))?.vk,
              (0x30...0x39).contains(vk) || (0x41...0x5A).contains(vk),
              String(Character(Unicode.Scalar(UInt8(vk)))).lowercased() == keyChar.lowercased() else { return nil }
        return .keyPositionFallback
    }
}

// `vkScanCode(forCarbonKeyCode:)` lives in KeyboardScanMap.swift.
