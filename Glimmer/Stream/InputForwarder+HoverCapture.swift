//
//  InputForwarder+HoverCapture.swift
//
//  Window mode's grab rule: the pointer belongs to the game while it is OVER
//  the picture. No button, no click, no combo - the same bargain a VM window
//  or a full-screen game makes, and the one the owner asked for. Moving the
//  pointer onto the stream hides the cursor and switches to relative aim;
//  holding Esc, the pointer chord, or switching apps gives it back.
//
//  The whole subtlety is the RE-GRAB. An explicit release (a held Esc, the
//  chord) happens while the pointer is still physically over the window, so a
//  naive "capture whenever you are inside" would take it straight back and the
//  user could never get out. A suppression latch closes that: an explicit
//  release arms it, and only LEAVING the view or the window losing key status
//  disarms it. Cmd-Tabbing back into the stream therefore grabs again, which
//  is what returning to a game means.
//
//  Every rule here is a pure function of four bools so the state machine is
//  unit-tested rather than implied by a scatter of AppKit callbacks
//  (GlimmerTests/WindowPointerTests.swift). The InputForwarder extension below
//  is only the wiring: it reads live state, asks the table, and calls the
//  existing `capturePointer` / `releasePointer` paths.
//
//  Window mode only. Full screen captures for the whole session on key status
//  and has no free state to return to, so every entry point here returns
//  immediately on `isWindowMode` and the fullscreen path never reaches the
//  table at all.
//

import AppKit

/// Pure decision table for the hover grab and its suppression latch.
enum HoverCapture {

    /// The edges that move the latch. Five is the whole state machine: two
    /// from the tracking area, one from each way the pointer is handed back or
    /// taken, and one from key status.
    enum Event: Equatable {
        /// The pointer crossed into the stream view.
        case pointerEntered
        /// The pointer left the stream view (title bar, another window, the
        /// desktop). Only ever seen while the pointer is FREE - see
        /// `notePointerExitedStreamView`.
        case pointerExited
        /// The user asked for the pointer back on purpose: a held Esc or the
        /// pointer chord.
        case explicitRelease
        /// Capture engaged, by whatever route.
        case captureEngaged
        /// The window stopped being key (Cmd-Tab, another app stealing
        /// foreground, the launcher coming forward).
        case windowResignedKey
    }

    /// Should crossing into the stream view take the pointer?
    ///
    /// `isKeyWindow` is the gate that stops a pointer sweeping over an
    /// inactive stream window on its way to another app from silently
    /// disappearing into a background game. `isCaptured` makes a redundant
    /// enter a no-op rather than a second engage.
    static func shouldCaptureOnEnter(isKeyWindow: Bool, isSuppressed: Bool, isCaptured: Bool) -> Bool {
        isKeyWindow && !isSuppressed && !isCaptured
    }

    /// Should the window BECOMING key take the pointer? Same rule, plus the
    /// pointer actually being inside. This is the Cmd-Tab-back case: the
    /// pointer never moved, so no enter event will ever arrive and without
    /// this the stream would sit there with the pointer resting on it and no
    /// grab until the user jiggled the mouse.
    static func shouldCaptureOnKey(
        pointerIsInside: Bool, isKeyWindow: Bool, isSuppressed: Bool, isCaptured: Bool
    ) -> Bool {
        pointerIsInside
            && shouldCaptureOnEnter(
                isKeyWindow: isKeyWindow, isSuppressed: isSuppressed, isCaptured: isCaptured)
    }

    /// The latch's next value.
    ///
    /// `pointerEntered` deliberately leaves a suppressed latch ALONE. AppKit
    /// re-creates the tracking area on every resize (`updateTrackingAreas`)
    /// and synthesises an enter for a pointer already sitting inside it, so
    /// clearing on enter would mean nudging the window edge after a held Esc
    /// silently re-grabbed the pointer. Only a real departure or a lost
    /// window counts as "the user has moved on".
    static func suppression(_ suppressed: Bool, after event: Event) -> Bool {
        switch event {
        case .pointerEntered: suppressed
        case .pointerExited: false
        case .explicitRelease: true
        case .captureEngaged: false
        case .windowResignedKey: false
        }
    }
}

extension InputForwarder {

    /// The pointer crossed into the picture. The grab, if the table allows it.
    func notePointerEnteredStreamView() {
        guard isWindowMode else { return }
        noteHoverCaptureEvent(.pointerEntered)
        guard HoverCapture.shouldCaptureOnEnter(
            isKeyWindow: window?.isKeyWindow ?? false,
            isSuppressed: isHoverCaptureSuppressed,
            isCaptured: isMouseCaptured
        ) else { return }
        capturePointer(reason: "pointer over the window")
    }

    /// The pointer left the picture: the user has moved on, so a later return
    /// is allowed to grab again.
    ///
    /// Ignored while captured. Under associate-false the OS stops moving the
    /// on-screen cursor, so a captured pointer physically cannot leave the
    /// view - any exit arriving in that state is AppKit bookkeeping (a
    /// re-created tracking area, a window move out from under a frozen
    /// cursor), and honouring it would clear the latch a held Esc has not even
    /// set yet.
    func notePointerExitedStreamView() {
        guard isWindowMode, !isMouseCaptured else { return }
        noteHoverCaptureEvent(.pointerExited)
    }

    /// Grab now if the pointer is already resting on the picture. Called from
    /// the two moments where the window gains the input without the pointer
    /// moving: the windowed bring-up, and a Cmd-Tab back.
    func captureIfPointerIsOverTheStreamView(reason: String) {
        guard isWindowMode, let window, let view = inputView else { return }
        guard HoverCapture.shouldCaptureOnKey(
            pointerIsInside: Self.pointerIsInside(view, of: window),
            isKeyWindow: window.isKeyWindow,
            isSuppressed: isHoverCaptureSuppressed,
            isCaptured: isMouseCaptured
        ) else { return }
        capturePointer(reason: reason)
    }

    /// Move the latch. The one writer, so the transitions can only ever be the
    /// ones the pure table names. Inert in full screen, where there is no
    /// free state and nothing to suppress.
    func noteHoverCaptureEvent(_ event: HoverCapture.Event) {
        guard isWindowMode else { return }
        isHoverCaptureSuppressed = HoverCapture.suppression(isHoverCaptureSuppressed, after: event)
    }

    /// Is the pointer over the stream view right now?
    ///
    /// `mouseLocationOutsideOfEventStream` rather than the last event's
    /// location: both callers run on a notification, not on a mouse event, so
    /// there is no event to ask. It reports window coordinates even when the
    /// pointer is outside the window, which is exactly the "is it inside"
    /// question `bounds.contains` then answers.
    private static func pointerIsInside(_ view: NSView, of window: NSWindow) -> Bool {
        view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
