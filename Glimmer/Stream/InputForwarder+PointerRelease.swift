//
//  InputForwarder+PointerRelease.swift
//
//  Window-mode pointer capture: click-to-grab, chord-to-release. Full screen
//  keeps its always-on capture (enter on key, exit on resign) untouched - every
//  entry point here is gated on `pointerCaptureOnClick`, which only the
//  window-mode session (or a Path-B Space exit landing in window mode) turns
//  on. The engagement mechanics themselves (associate-false, coalescing,
//  acceleration) are unchanged and shared: `enterCapturedMode()` /
//  `exitCapturedMode()` in InputForwarder+Capture.swift. Cursor VISIBILITY is
//  never touched here; the capture edge is reported to StreamWindow, which owns
//  the one hide/show latch.
//

import AppKit

extension InputForwarder {

    /// Whether mouse events reach the host right now. Full screen: always
    /// (capture there tracks key status, and the view only receives events
    /// while key). Window mode: only while the pointer is captured - a
    /// released pointer belongs to this Mac.
    var forwardsMouseEvents: Bool { !pointerCaptureOnClick || isMouseCaptured }

    /// Switch capture policy mid-session. Used by the Path-B Space exit that
    /// lands a fullscreen session in a window: the always-on capture is
    /// released (association restored, cursor shown via the reported edge) and
    /// the next click grabs it again. Idempotent.
    func setPointerCaptureOnClick(_ enabled: Bool) {
        guard pointerCaptureOnClick != enabled else { return }
        pointerCaptureOnClick = enabled
        if enabled {
            exitCapturedMode()
            log.info("Pointer capture policy: click-to-grab (window mode)")
        } else {
            log.info("Pointer capture policy: always-on (full screen)")
        }
    }

    /// The grab click. Only while the window is key - a click that is ALSO
    /// activating the window arrives before key status settles, and capturing
    /// then would hide the cursor over a window that can't yet receive input.
    /// The becomeKey that follows does not auto-capture in this mode, so the
    /// user's next click grabs cleanly.
    func capturePointerFromClick() {
        guard let window, window.isKeyWindow else { return }
        enterCapturedMode()
    }

    /// The release chord (and any future release path). Releases the mouse
    /// buttons the host believes are held FIRST - the physical up will land on
    /// whatever the freed pointer touches next, so without this a button held
    /// through the chord stays pressed on the host - then disengages. Keys
    /// are deliberately NOT raised: the keyboard keeps forwarding while the
    /// window is key, so a held W keeps walking, as the user expects.
    func releasePointer(reason: String) {
        raiseHeldMouseButtons(reason: reason)
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
}
