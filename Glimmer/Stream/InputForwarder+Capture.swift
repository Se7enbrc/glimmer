// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  InputForwarder+Capture.swift
//
//  Mouse capture + gesture suppression (focus observers, the gesture-suppression
//  monitor) and the diagnostic event tap used to identify spurious zoom/gesture
//  triggers. Split out of InputForwarder.swift to keep each unit focused; see
//  that file for the forwarder's stored state.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GameController
import os.log

extension InputForwarder {

    // MARK: - Mouse capture & gesture suppression

    // Capture owns cursor association and event coalescing. StreamWindow owns
    // cursor visibility; focus loss restores the system pointer and held input.

    func installFocusObservers(for window: NSWindow) {
        // Tear down any prior observers so re-entry is safe.
        removeFocusObservers()
        let nc = NotificationCenter.default
        didBecomeKeyObserver = nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isWindowMode == false {
                    self?.enterCapturedMode()
                }
                // Window mode grabs on hover, and a Cmd-Tab back moves no
                // pointer - so no enter event will ever arrive for a pointer
                // already resting on the picture. Without this the stream
                // would sit under the mouse, focused and ungrabbed, until the
                // user jiggled it. Inert in full screen (the line above owns
                // that path) and when the pointer is elsewhere on screen.
                self?.captureIfPointerIsOverTheStreamView(reason: "window became key under the pointer")
                // Snap all controller axes/buttons to live state on refocus -
                // GCController's value-changed handler doesn't re-fire for an
                // input held across the focus loss, so without this a stick
                // held while Cmd-Tabbing back reads as centered until nudged.
                self?.resyncControllers()
            }
        }
        didResignKeyObserver = nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowResignedKey()
            }
        }
    }

    func windowResignedKey() {
        inputGeneration &+= 1
        // The physical key-up goes to the newly focused app, so release held
        // input here. Esc's key-up may be lost too, making its timer unsafe.
        raiseAllHeldInputs(reason: "focus loss")
        if !isMiniPlayer {
            cancelQuitChordDwell(reason: "focus loss")
            neutralizeControllers()
        }
        exitCapturedMode()
        cancelEscapeHold()
        // Focus loss clears suppression so returning under the pointer captures again.
        noteHoverCaptureEvent(.windowResignedKey)
    }

    func removeFocusObservers() {
        let nc = NotificationCenter.default
        if let observer = didBecomeKeyObserver { nc.removeObserver(observer); didBecomeKeyObserver = nil }
        if let observer = didResignKeyObserver { nc.removeObserver(observer); didResignKeyObserver = nil }
    }

    /// Disassociate the cursor for relative aim only while this attached view
    /// owns key focus. Late focus callbacks must not capture after detach.
    func enterCapturedMode() {
        guard !isMouseCaptured, let window, let inputView,
              inputView.window === window, window.isKeyWindow,
              !window.ignoresMouseEvents else { return }
        mouseResidualX = 0
        mouseResidualY = 0
        // Reset the Cruise inter-batch clock AND the windowed-velocity accums
        // so the first post-focus motion reads a stale dt (>0.1s) and forces
        // gain==1.0 - never a spurious or carried-over boost on resume.
        lastMoveTimestamp = 0
        cruiseDistAccum = 0
        cruiseTimeAccum = 0
        // CGEvent deltas continue while the system pointer stays in place.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        inputView.resetMotion()
        // Collect uncoalesced motion for the forwarder's ordered batch drain;
        // restore the previous AppKit setting when capture ends.
        if savedMouseCoalescing == nil {
            savedMouseCoalescing = NSEvent.isMouseCoalescingEnabled
        }
        NSEvent.isMouseCoalescingEnabled = false
        // Raw aim (opt-in): macOS linear scaling drops the velocity curve but
        // keeps Tracking Speed. Saved + restored like coalescing above, with a
        // crash-safety sentinel (MouseAccelerationControl). nil = nothing to undo.
        if savedLinearScaling == nil, MouseAccelerationControl.isEnabled {
            savedLinearScaling = MouseAccelerationControl.engageLinear()
            if let prior = savedLinearScaling {
                log.info("Mouse capture: linear pointer scaling on (was \(prior))")
            }
        }
        isMouseCaptured = true
        if captureSysKeys { GlobalHotKeys.setDisabled(true) }
        log.info("""
            Mouse capture: relative aim engaged (associate-false; coalescing off; \
            cursor disassociated, visibility owned by StreamWindow)
            """)
        // Window mode only: report the edge so the window hides the cursor.
        if isWindowMode { onPointerCaptureChanged?(true) }
    }

    /// Restore cursor association and the settings capture changed on focus loss
    /// or detach. StreamWindow separately owns the display hide and cursor image.
    func exitCapturedMode() {
        guard isMouseCaptured else { return }
        isMouseCaptured = false
        inputView?.resumeMotion()
        releaseCommandSides()
        // Re-associate: hand cursor control back to the OS so the pointer tracks
        // the device again wherever the user goes after leaving the stream.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        GlobalHotKeys.setDisabled(false)
        // Restore the system's prior mouse-coalescing setting (the `true` that
        // pairs with the `false` from enterCapturedMode) so we don't leak our
        // override into other apps after the stream ends. Clear the saved value
        // so the next engage re-reads the (possibly changed) global default.
        if let prior = savedMouseCoalescing {
            NSEvent.isMouseCoalescingEnabled = prior
            savedMouseCoalescing = nil
        }
        // Put the user's linear-scaling flag back (pairs with engageLinear and
        // clears the sentinel). nil = we never overrode it.
        if let prior = savedLinearScaling {
            MouseAccelerationControl.restore(prior)
            savedLinearScaling = nil
            log.info("Mouse capture: linear pointer scaling restored to \(prior)")
        }
        log.info("""
            Mouse capture: relative aim disengaged (associate-true; coalescing restored; \
            cursor re-associated, visibility owned by StreamWindow)
            """)
        // Window mode only: report the edge so the window shows the cursor.
        if isWindowMode { onPointerCaptureChanged?(false) }
    }

    func installGestureSuppressionMonitor() {
        guard gestureSuppressionMonitor == nil else { return }
        // Zoom-inducing gestures only. A broader mask (`.gesture`,
        // `.beginGesture`, `.endGesture`, `.pressure`) catches raw
        // trackpad pan/scroll data on laptops with no external mouse -
        // killing cursor + scroll because the OS synthesises mouseMoved
        // events from that gesture stream. Truly-zoom-triggering types:
        //   .magnify        - two-finger pinch (live)
        //   .smartMagnify   - two-finger double-tap "smart zoom"
        //   .swipe          - three-finger swipe (legacy)
        //   .rotate         - two-finger rotate (no game meaning over a stream)
        let mask: NSEvent.EventTypeMask = [
            .magnify, .smartMagnify, .swipe, .rotate
        ]
        gestureSuppressionMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // Only swallow when our stream window is the event target.
            // Otherwise a notification-centre or popover gesture would
            // get eaten too.
            guard let self, let window = self.window,
                  event.window === window, window.isKeyWindow else {
                return event
            }
            let eventType = event.type.rawValue
            let eventPhase = event.phase.rawValue
            self.log.debug("Suppressed gesture type=\(eventType, privacy: .public) phase=\(eventPhase, privacy: .public)")
            return nil
        }
    }

    func removeGestureSuppressionMonitor() {
        if let monitor = gestureSuppressionMonitor {
            NSEvent.removeMonitor(monitor)
            gestureSuppressionMonitor = nil
        }
    }

    // MARK: - Diagnostic event tap (stage 1: identify the zoom trigger)
    //
    // The bug we're chasing: macOS zooms into the stream during intense
    // gameplay input. Ctrl+scroll has been ruled out. We don't yet know which event
    // type fires immediately before zoom - could be a gesture phase event,
    // a systemDefined media-key subtype, a hover-text trigger, the
    // accessibility-zoom chord (⌥⌘8 / ⌥⌘= / ⌥⌘-), or pointer-shake.
    //
    // This monitor logs every event AppKit delivers to our process during
    // a streaming session at .info level so the user can reproduce the
    // zoom once, paste the log slice, and we'll see exactly what fired in
    // the milliseconds before the zoom appeared.
    //
    // Rate-limiting: gestural input can produce >120Hz event streams
    // (.scrollWheel especially). We cap at 100 events/sec by sampling 1-in-N
    // when the rate exceeds the cap, so a long burst doesn't drown the log.
    //
    // Future: escalation path if the diagnostic shows zoom firing from a
    // WindowServer-level event we can't observe at the AppKit layer. The
    // replacement is a CGEventTap installed at
    // `kCGAnnotatedSessionEventTap` (session-scoped, doesn't require
    // root), subsuming BOTH this diagnostic monitor and the gesture
    // suppression monitor:
    //   1. Installs in installFirstResponder() after the existing monitors.
    //   2. Filters with mask `CGEventMask` covering kCGEventScrollWheel,
    //      kCGEventGesture, kCGEventTabletPointer, kCGEventOtherMouseUp/Down,
    //      kCGEventTabletProximity, and synthetic 29 (NSEvent.systemDefined).
    //   3. Returns `nil` from the callback for events whose
    //      `CGEventGetIntegerValueField(.eventTargetUnixProcessID)` matches
    //      our PID OR which carry the zoom subtype, consuming them.
    //   4. Tears down in detach() via CGEventTapEnable(false) +
    //      CFMachPortInvalidate.
    // CGEventTap requires Accessibility permission (user prompts on first
    // run) - a UX cost we don't pay until the diagnostic confirms we need
    // the tap.

    func installDiagnosticMonitors() {
        // Opt-in diagnostics only: a per-event log line is not a default cost.
        guard diagnosticLocalMonitor == nil, TelemetryGate.isEnabled else { return }

        // Constraint: this monitor must touch ONLY NSEvent primitives
        // documented as valid for every event type - type raw, modifier
        // mask, raw subtype-or-zero. Type-specific accessors
        // (`event.window`, `event.chars`, `scrollingDeltaX`,
        // `magnification`, etc.) throw on the wrong event type, and at
        // high event rates (e.g. click + 1-4 key spam under intense input) the OSLog
        // formatter dies mid-interpolation and takes keyboard delivery
        // with it. The body of `logDiagnosticEvent` below enforces this;
        // do not add an accessor that's documented as "returns valid
        // values only for events of type X" without gating on the type.
        // No key events: with a known layout, key codes are the typed text.
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
            .magnify, .smartMagnify, .swipe, .rotate,
            .gesture, .beginGesture, .endGesture,
            .pressure,
            .systemDefined, .appKitDefined, .applicationDefined,
            .tabletProximity,
            .directTouch
            // .mouseMoved / .*Dragged deliberately excluded - they fire at
            // ProMotion rates and we already handle motion in the regular
            // path. Logging them here would just flood the buffer.
        ]

        diagnosticLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.logDiagnosticEvent(event)
            return event   // pass-through; suppression is the other monitor's job
        }
        log.info("Diagnostic event monitor armed (safe mode) - logs every input event for zoom-trigger diagnosis")
    }

    func removeDiagnosticMonitors() {
        if let monitor = diagnosticLocalMonitor { NSEvent.removeMonitor(monitor); diagnosticLocalMonitor = nil }
        if let monitor = diagnosticGlobalMonitor { NSEvent.removeMonitor(monitor); diagnosticGlobalMonitor = nil }
        diagSampleWindowStart = 0
        diagSampleCount = 0
        diagSampleDivisor = 1
    }

    /// Crash-proof minimal version. Only touches NSEvent properties that
    /// are documented to return valid (possibly zero) values for every
    /// event type. Specifically NO `event.window`, no `charactersIgnoring-
    /// Modifiers`, no `scrollingDeltaX`, no `magnification` - all of those
    /// throw on the wrong event type and the OSLog formatter's lazy eval
    /// turns a single bad access into a process-killing crash mid-stream.
    func logDiagnosticEvent(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - diagSampleWindowStart >= 1.0 {
            diagSampleWindowStart = now
            diagSampleCount = 0
            diagSampleDivisor = 1
        }
        diagSampleCount += 1
        if diagSampleCount > 100 {
            diagSampleDivisor = max(diagSampleDivisor, diagSampleCount / 100)
            if diagSampleCount % diagSampleDivisor != 0 { return }
        }
        let type = event.type
        let typeRaw = type.rawValue
        let typeName = diagnosticEventTypeName(type)
        // subtype is only valid for system/appKit/application defined.
        let subtype: Int
        switch type {
        case .systemDefined, .appKitDefined, .applicationDefined:
            subtype = Int(event.subtype.rawValue)
        default:
            subtype = -1
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        // For scrollWheel events specifically, also log the magnitude so we
        // can tell real-user scroll input from micro-deltas (free-spin
        // wheels, tilt-wheel side-clicks, the host's own scroll-injection).
        // scrollingDeltaX/Y are safe for the scrollWheel type - they only
        // crash when read on non-scroll events. We gate on type explicitly.
        var scrollX: Double = 0
        var scrollY: Double = 0
        if type == .scrollWheel {
            scrollX = Double(event.scrollingDeltaX)
            scrollY = Double(event.scrollingDeltaY)
        }
        // Identify the event SOURCE - hardware HID device, third-party
        // injected (BetterMouse, MOS, Karabiner, LinearMouse, etc.), or
        // Apple's own software cursor. This is the only way to tell a
        // "real" wheel tick from a synthetic scroll injected by a userland
        // mouse driver. CGEvent.source.sourceStateID returns one of:
        //   .hidSystemState (0)        - hardware HID (mouse / trackpad)
        //   .combinedSessionState (1)  - combined session events
        //   .privateState (anything else) - userland-injected synthetic
        var srcID: String = "-"
        if type == .scrollWheel, let cg = event.cgEvent {
            // PID of the process that posted the event. 0 = OS, ours = us,
            // anything else = userland injection (BetterMouse, MOS, etc.).
            // The combination of PID + the eventSourceStateID field (a
            // separate token used by CGEventSourceCreate) is enough to
            // fingerprint third-party scroll injection.
            let pid = cg.getIntegerValueField(.eventSourceUnixProcessID)
            let stateID = cg.getIntegerValueField(.eventSourceStateID)
            srcID = "pid=\(pid)/state=\(stateID)"
        }
        log.info("""
            DiagEvent t=\(now, privacy: .public) type=\(typeRaw, privacy: .public)(\(typeName, privacy: .public)) \
            subtype=\(subtype, privacy: .public) mods=0x\(String(mods, radix: 16), privacy: .public) \
            dx=\(scrollX, privacy: .public) dy=\(scrollY, privacy: .public) src=\(srcID, privacy: .public)
            """)
    }

    /// Stable human-readable names for every NSEvent type we might log.
    /// Backed by a flat lookup table (not real branching) so the diagnostic
    /// formatter stays a simple data map rather than a giant switch.
    /// `.mouseCancelled` (macOS 26+) and any future-added cases are absent
    /// here and fall through to the raw-value fallback in
    /// `diagnosticEventTypeName(_:)` - keeping us exhaustive on the current
    /// SDK without churning the table every time AppKit gains an event type.
    private static let diagnosticEventTypeNames: [NSEvent.EventType: String] = [
        .leftMouseDown: "leftMouseDown",
        .leftMouseUp: "leftMouseUp",
        .rightMouseDown: "rightMouseDown",
        .rightMouseUp: "rightMouseUp",
        .mouseMoved: "mouseMoved",
        .leftMouseDragged: "leftMouseDragged",
        .rightMouseDragged: "rightMouseDragged",
        .mouseEntered: "mouseEntered",
        .mouseExited: "mouseExited",
        .keyDown: "keyDown",
        .keyUp: "keyUp",
        .flagsChanged: "flagsChanged",
        .appKitDefined: "appKitDefined",
        .systemDefined: "systemDefined",
        .applicationDefined: "applicationDefined",
        .periodic: "periodic",
        .cursorUpdate: "cursorUpdate",
        .scrollWheel: "scrollWheel",
        .tabletPoint: "tabletPoint",
        .tabletProximity: "tabletProximity",
        .otherMouseDown: "otherMouseDown",
        .otherMouseUp: "otherMouseUp",
        .otherMouseDragged: "otherMouseDragged",
        .gesture: "gesture",
        .magnify: "magnify",
        .swipe: "swipe",
        .rotate: "rotate",
        .beginGesture: "beginGesture",
        .endGesture: "endGesture",
        .smartMagnify: "smartMagnify",
        .quickLook: "quickLook",
        .pressure: "pressure",
        .directTouch: "directTouch",
        .changeMode: "changeMode"
    ]

    /// Human-readable name for an NSEvent type, for diagnostic log lines.
    /// Known types resolve through the flat lookup table above; anything not
    /// in it (e.g. `.mouseCancelled` on macOS 26+, future AppKit additions)
    /// falls back to its raw value, which is enough to identify the type.
    func diagnosticEventTypeName(_ type: NSEvent.EventType) -> String {
        Self.diagnosticEventTypeNames[type] ?? "type(\(type.rawValue))"
    }
}
