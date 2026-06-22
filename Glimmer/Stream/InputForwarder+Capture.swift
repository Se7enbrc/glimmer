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
    //
    // SDL ASSOCIATE-FALSE CURSOR MODEL (P0 mouse-snap fix). This is
    // the SDL_SetRelativeMouseMode(true) recipe on macOS and is the airtight
    // root-cause fix for the in-game aim snapping to a screen edge/corner.
    //
    // Visibility is owned ENTIRELY by StreamWindow (hide via CGDisplayHideCursor,
    // single source of truth = StreamWindow.didHideCursor). The input layer here
    // owns relative-aim engagement (now including the associate-false latch),
    // gesture suppression, and never touches cursor VISIBILITY (that's
    // StreamWindow's).
    //
    // Why associate-false (and why the prior warp-to-centre model was the bug):
    //   * The previous "reconciled" model kept the cursor ASSOCIATED (the OS
    //     keeps physically moving it) and warped it back to centre when it
    //     neared a screen edge. An associate-TRUE warp posts a reconciling
    //     mouse-moved event whose kCGMouseEventDeltaX/Y carries the FULL
    //     edge→centre jump (up to ~1500px on a 3024-wide panel). There was NO
    //     post-warp suppression anywhere, so that reconciliation delta was read
    //     as pure HID motion and sent to the host → the in-game aim snapped to
    //     an edge/corner. Intermittent because it only leaked when a warp's
    //     reconciliation event landed in the motion pipeline.
    //   * Under associate-false the OS STOPS moving the on-screen cursor. There
    //     is therefore no edge to warp from, no warp at all, and no
    //     reconciliation delta to suppress - the entire bug CLASS is structurally
    //     gone. This is exactly what moonlight-qt/SDL do (SDL_cocoamouse).
    //   * The two reasons the prior associate-false attempt was abandoned no
    //     longer apply: (a) "the cursor freezes visibly" - it's hidden by
    //     CGDisplayHideCursor, so there is no visible pointer to freeze; the
    //     user only ever sees in-game aim driven by relative deltas. (b) "the OS
    //     stops reporting deltas" - that was true of NSEvent.deltaX/Y, but we
    //     read kCGMouseEventDeltaX/Y off the CGEvent layer (mouseDelta(from:)),
    //     which stays valid AND becomes pure accel-free HID under associate-false
    //     (the exact field SDL reads in relative mode).
    //   * Every associate-FALSE is paired with a guaranteed associate-TRUE on
    //     resign-key / teardown so Cmd-Tab and stream-end always restore a
    //     normal, OS-controlled pointer.
    //
    // Gesture suppression (unchanged, still needed under associate-false):
    //   * Trackpad gesture family (pinch/.magnify, smart-zoom/.smartMagnify,
    //     three-finger-swipe/.swipe, .rotate): the NSEvent local monitor below
    //     consumes them for our key stream window. Sufficient on its own -
    //     these dispatch through AppKit, so returning nil stops the default
    //     zoom/swipe handlers.
    //   * macOS Accessibility "Smart Zoom" keyboard chords (⌥⌘8/=/-): swallowed
    //     in streamView(_:handleKeyDown:) (InputForwarder+StreamView.swift).
    //   * Hot corners (Mission Control etc.): under associate-false the OS does
    //     not move the cursor, so it can never reach a corner - the warp's old
    //     job is gone entirely (warpCursorIfNearEdge deleted).
    //   * Ctrl+scroll Accessibility Zoom: this is interlocked at the
    //     WindowServer/SkyLight layer BELOW NSEvent dispatch, so neither the
    //     monitor above nor the chord swallow can cancel it. With the cursor
    //     associate-false the scroll still reaches us as a relative event; the
    //     documented non-freezing replacement remains the kCGAnnotatedSession-
    //     EventTap escalation scoped in the diagnostic-tap comment below (a
    //     session-scoped CGEventTap consuming control+scrollWheel for our PID,
    //     needs Accessibility permission). Not installed yet - gated behind the
    //     diagnostic.

    func installFocusObservers(for window: NSWindow) {
        // Tear down any prior observers so re-entry is safe.
        removeFocusObservers()
        let nc = NotificationCenter.default
        didBecomeKeyObserver = nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.enterCapturedMode()
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
                // Release cursor when the user Cmd-Tabs away or the system
                // grabs focus for a sheet. We do NOT raise keys here - the
                // window-resign path can be a transient (e.g. notification
                // banner) and we want held game keys to survive it. The
                // gate against orphan modifiers is in detach().
                self?.exitCapturedMode()
            }
        }
    }

    func removeFocusObservers() {
        let nc = NotificationCenter.default
        if let observer = didBecomeKeyObserver { nc.removeObserver(observer); didBecomeKeyObserver = nil }
        if let observer = didResignKeyObserver { nc.removeObserver(observer); didResignKeyObserver = nil }
    }

    /// Engage relative-aim mode (SDL_SetRelativeMouseMode(true) on macOS).
    /// DISASSOCIATES the cursor from the pointing device via
    /// `CGAssociateMouseAndMouseCursorPosition(false)` so the OS stops physically
    /// moving the on-screen cursor - which is what makes the in-game aim
    /// impossible to snap to an edge/corner (no cursor travel ⇒ no edge ⇒ no
    /// warp ⇒ no warp-reconciliation delta). The cursor is already invisible
    /// (StreamWindow owns `CGDisplayHideCursor`), so there is no visible pointer
    /// to "freeze". kCGMouseEventDeltaX/Y - the field `mouseDelta(from:)` reads -
    /// stays valid and becomes pure accel-free HID under associate-false (the
    /// exact field SDL reads in relative mode); only NSEvent.deltaX/Y goes silent,
    /// and we don't use it. Resets the sub-pixel residual so the first post-focus
    /// mouseMoved doesn't carry stale fractional pixels. Re-entrant.
    func enterCapturedMode() {
        guard !isMouseCaptured else { return }
        mouseResidualX = 0
        mouseResidualY = 0
        // Disassociate: the OS stops moving the system cursor; HID motion still
        // arrives as relative deltas on the CGEvent layer. The return value is
        // a CGError; on the (vanishingly unlikely) failure we still proceed -
        // the worst case degrades to the OS moving an already-hidden cursor, not
        // a crash, and the next focus cycle retries.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        // Turn OFF NSEvent mouse coalescing so AppKit delivers every raw HID
        // motion sample (on ProMotion ~120Hz, vs the ~60Hz coalesced default)
        // instead of merging them. The manual delta-summing coalescer in
        // streamView(_:handleMouseMoved:) sums these now-more-numerous events
        // into the same 1ms batch, so host acceleration still applies once per
        // batch (no twitchiness) - we just feed it finer-grained, more accurate
        // deltas. Save the prior global value so we restore it on disengage and
        // stay polite to the rest of the system. Only save once (first engage):
        // a re-entrant guard above already returns early, but the save is
        // idempotent-safe regardless.
        if savedMouseCoalescing == nil {
            savedMouseCoalescing = NSEvent.isMouseCoalescingEnabled
        }
        NSEvent.isMouseCoalescingEnabled = false
        // Linearize the system pointer acceleration so the relative deltas we
        // forward to the host are raw 1:1 - macOS otherwise runs even
        // associate-false HID motion through its acceleration curve, stacking the
        // Mac's curve on top of the game's own in-game sensitivity. Default-on;
        // opt out in Settings. Saved + restored like coalescing above, with a
        // UserDefaults crash-safety sentinel (see MouseAccelerationControl).
        // engageLinear() returns nil - leaving savedMouseAcceleration nil so
        // exitCapturedMode skips the restore - when the feature is off, the
        // read/write fails, or the user already runs linear (nothing of ours to
        // undo). The guard mirrors the coalescing save: only on the first engage.
        if savedMouseAcceleration == nil, MouseAccelerationControl.isEnabled {
            savedMouseAcceleration = MouseAccelerationControl.engageLinear()
            if let prior = savedMouseAcceleration {
                log.info("Mouse capture: pointer acceleration linearized (was \(prior), now \(MouseAccelerationControl.linear))")
            }
        }
        isMouseCaptured = true
        log.info("Mouse capture: relative aim engaged (associate-false; coalescing off; cursor disassociated, visibility owned by StreamWindow)")
    }

    /// Disengage relative-aim mode. RE-ASSOCIATES the cursor with the pointing
    /// device (`CGAssociateMouseAndMouseCursorPosition(true)`) so Cmd-Tab /
    /// teardown restores a normal, OS-controlled pointer. This is the guaranteed
    /// `true` that pairs with every `false` from `enterCapturedMode()` - it runs
    /// from the window's resign-key hook and from `detach()`. Visibility is owned
    /// by StreamWindow's resign-key / close path, so we deliberately do NOT show
    /// the cursor here; we only restore association.
    func exitCapturedMode() {
        guard isMouseCaptured else { return }
        isMouseCaptured = false
        // Re-associate: hand cursor control back to the OS so the pointer tracks
        // the device again wherever the user goes after leaving the stream.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        // Restore the system's prior mouse-coalescing setting (the `true` that
        // pairs with the `false` from enterCapturedMode) so we don't leak our
        // override into other apps after the stream ends. Clear the saved value
        // so the next engage re-reads the (possibly changed) global default.
        if let prior = savedMouseCoalescing {
            NSEvent.isMouseCoalescingEnabled = prior
            savedMouseCoalescing = nil
        }
        // Restore the pointer acceleration we linearized on engage (pairs with
        // engageLinear; also clears the crash-safety sentinel). nil = we never
        // overrode it (feature off / already linear / failed), so nothing to undo.
        if let prior = savedMouseAcceleration {
            MouseAccelerationControl.restore(prior)
            savedMouseAcceleration = nil
            log.info("Mouse capture: pointer acceleration restored to \(prior)")
        }
        log.info("Mouse capture: relative aim disengaged (associate-true; coalescing restored; cursor re-associated, visibility owned by StreamWindow)")
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
        guard diagnosticLocalMonitor == nil else { return }

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
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
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
        // keyCode is safe for keyDown/keyUp/flagsChanged. For everything
        // else NSEvent guarantees keyCode reads (it returns the value of
        // the underlying CGEvent's keycode field or 0).
        let kc = (type == .keyDown || type == .keyUp || type == .flagsChanged)
            ? Int(event.keyCode) : -1
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
        // swiftlint:disable:next line_length
        log.info("DiagEvent t=\(now, privacy: .public) type=\(typeRaw, privacy: .public)(\(typeName, privacy: .public)) subtype=\(subtype, privacy: .public) mods=0x\(String(mods, radix: 16), privacy: .public) kc=\(kc, privacy: .public) dx=\(scrollX, privacy: .public) dy=\(scrollY, privacy: .public) src=\(srcID, privacy: .public)")
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

// MARK: - System mouse pointer-acceleration control (relative-aim linearization)

/// Floors the global mouse pointer-acceleration to linear while the stream
/// window is focused, so the relative deltas InputForwarder forwards are raw 1:1
/// and only the host game's own sensitivity shapes aim. macOS otherwise runs
/// even associate-false HID motion through its acceleration curve (the
/// "accel-free under associate-false" assumption is optimistic - the curve is
/// applied before kCGMouseEventDeltaX/Y), stacking the Mac's curve on the host's.
/// This is the same save→override→restore discipline `enterCapturedMode()`
/// already uses for `NSEvent.isMouseCoalescingEnabled`.
///
/// CRASH-SAFETY: the override is a GLOBAL system setting, not process-local. If
/// Glimmer dies while focused (crash / SIGKILL) the in-memory saved value is
/// gone and the mouse would stay linear system-wide. So `engageLinear()` ALSO
/// persists the pre-override value to UserDefaults the instant it overrides;
/// `restoreOrphanedOverride()` (called once at launch, GlimmerApp) detects a
/// leftover and restores it - a crash can never strand the pointer in linear
/// mode past the next launch. The normal blur/teardown path clears the sentinel.
enum MouseAccelerationControl {
    /// Default-ON opt-out preference. Registered `true` in GlimmerApp so both
    /// this gate and the Settings `@AppStorage` toggle read on by default.
    static let enabledDefaultsKey = "disableMouseAccelWhileStreaming"
    /// Crash-safety sentinel: holds the pre-override acceleration WHILE the
    /// override is engaged; absent at rest (cleared on every clean restore).
    private static let pendingRestoreKey = "mouseAccelPendingRestore"
    /// The "disabled / linear" acceleration value (mirrors `com.apple.mouse.scaling -1`).
    static let linear = -1.0
    /// One-time latch so a failing/absent IOKit acceleration API logs a single
    /// NOTICE, not one per stream focus. Single-writer on the @MainActor capture path.
    nonisolated(unsafe) private static var loggedAPIUnavailable = false

    /// Whether the linearize-while-focused feature is on (default true).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    /// Engage linear mode. Returns the saved prior acceleration to hand back on
    /// disengage, or nil when there is nothing of ours to undo: the read failed,
    /// the user already runs linear (prior < 0), or the write was refused. Stamps
    /// the crash-safety sentinel only when it actually overrides.
    static func engageLinear() -> Double? {
        let prior = gl_get_mouse_acceleration()
        // < -1.5 = the (deprecated, private) IOKit acceleration API failed or is
        // gone on this OS (the read sentinel is -2.0). Degrade silently - the
        // stream is unaffected, the mouse just keeps the Mac's acceleration - but
        // log ONCE so a future-macOS regression is visible in the log.
        if prior < -1.5 {
            if !loggedAPIUnavailable {
                loggedAPIUnavailable = true
                Diag.notice("Mouse: pointer-acceleration API unavailable - raw-aim "
                    + "linearization disabled (stream unaffected)", "Input")
            }
            return nil
        }
        // prior in [-1, 0): the user already runs linear - nothing of ours to undo.
        guard prior >= 0 else { return nil }
        let defaults = UserDefaults.standard
        defaults.set(prior, forKey: pendingRestoreKey)
        guard gl_set_mouse_acceleration(linear) == 1 else {
            defaults.removeObject(forKey: pendingRestoreKey)
            return nil
        }
        return prior
    }

    /// Restore a previously-saved acceleration value and clear the sentinel.
    static func restore(_ value: Double) {
        _ = gl_set_mouse_acceleration(value)
        UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
    }

    /// Launch-time crash recovery: if a prior run died with the override engaged,
    /// the sentinel still holds the pre-override value - restore it now and clear
    /// it. No-op when the sentinel is absent (the clean, common case). The stored
    /// value is always a real >= 0 acceleration (engageLinear only writes it after
    /// guarding `prior >= 0`), so restoring it unconditionally is safe.
    static func restoreOrphanedOverride() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: pendingRestoreKey) != nil else { return }
        let saved = defaults.double(forKey: pendingRestoreKey)
        _ = gl_set_mouse_acceleration(saved)
        defaults.removeObject(forKey: pendingRestoreKey)
        Diag.notice("Mouse: restored orphaned pointer-acceleration override to \(saved) "
            + "(prior session ended while streaming)", "Launch")
    }
}
