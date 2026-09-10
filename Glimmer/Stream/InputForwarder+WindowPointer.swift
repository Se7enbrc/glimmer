//
//  InputForwarder+WindowPointer.swift
//
//  Window mode's pointer model. Capture (relative aim, cursor hidden,
//  associate-false) is grabbed by the pointer simply being OVER the picture,
//  the way a VM window or a game does it, and left again with a held Esc, the
//  pointer chord, or Cmd-Tab. The grab rule itself and its suppression latch
//  are in InputForwarder+HoverCapture.swift.
//
//  Outside capture the pointer is a NORMAL Mac pointer: visible, owned by the
//  OS, and mirrored onto the host as ABSOLUTE positions so the two cursors sit
//  on top of each other. That state is transient now (the pointer is free only
//  while it is off the picture, or the window is not key, or a release latch
//  is holding the grab off) but it is the honest thing to send there.
//
//  Everything here is gated on `isWindowMode`, which only a window-mode
//  session (or a Path-B Space exit landing in window mode) turns on. Full
//  screen keeps its always-on relative capture - entered on key, released on
//  resign - and never reaches the absolute path. The engagement mechanics
//  themselves (associate-false, coalescing, acceleration) are unchanged and
//  shared: `enterCapturedMode()` / `exitCapturedMode()` in
//  InputForwarder+Capture.swift. Cursor VISIBILITY is never touched here; the
//  capture edge is reported to StreamWindow, which owns the one hide/show
//  latch.
//

import AppKit

extension InputForwarder {

    /// Whether mouse events reach the host right now.
    ///
    /// Full screen: always - capture there tracks key status and the window
    /// orders out when it resigns, so the view only receives events while it
    /// owns the input.
    ///
    /// Window mode: only while the window is KEY. A window keeps its tracking
    /// area alive with `.activeAlways` (the stream needs mouseMoved without a
    /// button held), so without this gate a pointer sweeping over an inactive
    /// stream window on the way to another app would drag the host's cursor
    /// around behind the user's back.
    var forwardsMouseEvents: Bool {
        guard isWindowMode else { return true }
        return window?.isKeyWindow ?? false
    }

    /// Whether pointer motion should be sent as an absolute POSITION rather
    /// than a relative delta: window mode with the pointer free. Constant
    /// `false` in full screen, so the relative path there is untouched.
    var sendsAbsolutePointer: Bool { isWindowMode && !isMouseCaptured }

    /// Switch pointer policy mid-session. Used by the Path-B Space exit that
    /// lands a fullscreen session in a window: the always-on capture is
    /// released (association restored, cursor shown via the reported edge) and
    /// the pointer goes back to being a normal Mac pointer. Idempotent.
    func setWindowMode(_ enabled: Bool) {
        guard isWindowMode != enabled else { return }
        isWindowMode = enabled
        if enabled {
            exitCapturedMode()
            log.info("Pointer policy: relative capture while the pointer is over the window")
        } else {
            // Leaving window mode retires the latch with the rule it belongs
            // to: full screen never reads it, and a later return to a window
            // must not inherit a stale "do not grab" from the last release.
            isHoverCaptureSuppressed = false
            log.info("Pointer policy: always-on relative capture (full screen)")
        }
    }

    /// The pointer chord (⌃⌥R). A toggle, so the combo is never a dead key:
    /// it grabs a free pointer and frees a grabbed one. It is the way to
    /// re-grab without leaving and re-entering the window, and the way to
    /// release without reaching for Esc.
    func togglePointerCapture(reason: String) {
        guard isWindowMode else { return }
        if isMouseCaptured {
            releasePointer(reason: reason)
        } else {
            capturePointer(reason: reason)
        }
    }

    /// Enter relative capture. Only while the window is key - capturing while
    /// it is not would hide the cursor over a window that cannot receive
    /// input, so a pointer sweeping over a background stream window on its way
    /// somewhere else would vanish into a game the user is not looking at.
    func capturePointer(reason: String) {
        guard isWindowMode, !isMouseCaptured, let window, window.isKeyWindow else { return }
        log.info("Pointer capture requested (\(reason, privacy: .public))")
        // Clear the latch as the grab lands: it exists to keep a release from
        // being undone, and the pointer is captured again, so the question it
        // answers is settled.
        noteHoverCaptureEvent(.captureEngaged)
        // Tell the host where the pointer IS before relative aim takes over.
        // Deltas move the host's cursor from wherever it already sits, which
        // after a spell in absolute mode - or after a game moved its own
        // cursor while paused - is not where the user just pointed. The
        // reported symptom was a pause menu whose cursor sat somewhere other
        // than the pointer that grabbed it, so a click "over" a menu item
        // landed elsewhere. One absolute position closes that gap; from the
        // next event on it is deltas as before.
        syncHostPointerToCurrentLocation()
        enterCapturedMode()
    }

    /// Leave relative capture on purpose (a held Esc or the chord). Releases
    /// the mouse buttons the host believes are held FIRST - the physical up
    /// will land on whatever the freed pointer touches next, so without this a
    /// button held through the release stays pressed on the host - then
    /// disengages. Keys are deliberately NOT raised: the keyboard keeps
    /// forwarding while the window is key, so a held W keeps walking, as the
    /// user expects.
    ///
    /// Arms the hover-grab latch, because this release happens with the
    /// pointer still sitting on the picture: without it the very rule that
    /// grabbed the pointer would take it straight back and Esc would do
    /// nothing visible. Resign-key does NOT come through here - it releases via
    /// `exitCapturedMode` and deliberately clears the latch instead, so a
    /// Cmd-Tab back into the stream grabs again.
    func releasePointer(reason: String) {
        raiseHeldMouseButtons(reason: reason)
        cancelEscapeHold()
        noteHoverCaptureEvent(.explicitRelease)
        exitCapturedMode()
    }

    private func raiseHeldMouseButtons(reason: String) {
        guard isReady, !heldMouseButtons.isEmpty else { return }
        for button in heldMouseButtons {
            let rc = backend?.sendMouseButton(
                action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: button) ?? -2
            record("LiSendMouseButtonEvent(release-pointer)", rc)
        }
        Diag.notice("input: released \(heldMouseButtons.count) held mouse button(s) on \(reason)", "Stream")
        heldMouseButtons.removeAll()
    }

    /// Mirror this event's pointer position onto the host, in stream pixels.
    ///
    /// The uplink (`sendMousePosition` → InputBatcher's latest-only absolute
    /// slot → NV_ABS_MOUSE_MOVE_PACKET) has been implemented and unused; this
    /// is its only caller. Latest-only per batcher tick is exactly right for
    /// absolute positions: an intermediate point that a newer one supersedes
    /// carries no information, which is why there is no delta-coalescing drain
    /// on this path the way there is on the relative one.
    ///
    /// A no-op unless the pointer is free in a window, so every call site can
    /// invoke it unconditionally and full screen pays one bool for it.
    /// One absolute position for the pointer's CURRENT location, read from the
    /// window rather than an event so the two capture paths that have no event
    /// to hand (a hover grab, a Cmd-Tab back onto a resting pointer) can both
    /// use it. Deliberately NOT routed through `sendAbsolutePointer`: that one
    /// is gated on the pointer being free, which is exactly the state this is
    /// leaving. Window mode only, so full screen never emits an absolute event.
    func syncHostPointerToCurrentLocation() {
        guard isReady, isWindowMode, let window, let view = inputView else { return }
        let viewPoint = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard view.bounds.contains(viewPoint) else { return }
        guard let point = PointerMapping.streamPoint(
            viewPoint: viewPoint,
            viewSize: view.bounds.size,
            streamPixelSize: streamPixelSize
        ) else { return }
        let rc = backend?.sendMousePosition(
            x: point.x, y: point.y, refW: point.refW, refH: point.refH) ?? -2
        record("LiSendMousePositionEvent(capture-sync)", rc)
    }

    func sendAbsolutePointer(for event: NSEvent, in view: NSView) {
        guard isReady, sendsAbsolutePointer else { return }
        guard let point = PointerMapping.streamPoint(
            viewPoint: view.convert(event.locationInWindow, from: nil),
            viewSize: view.bounds.size,
            streamPixelSize: streamPixelSize
        ) else { return }
        let rc = backend?.sendMousePosition(
            x: point.x, y: point.y, refW: point.refW, refH: point.refH) ?? -2
        record("LiSendMousePositionEvent", rc)
    }
}
