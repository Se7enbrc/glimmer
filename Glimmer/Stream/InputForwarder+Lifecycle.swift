//
//  InputForwarder+Lifecycle.swift
//
//  Session lifecycle for the input path: installing the `StreamInputView` into
//  the stream window, promoting it to first responder once the window is
//  actually key, tearing the whole thing down, and flipping the ready gate the
//  native backend's `connectionStarted` callback drives. Split from
//  InputForwarder.swift - same idiom as the ControllerForwarder split, to keep
//  that file under the length limit; the per-event forwarding (keys, modifiers,
//  mouse capture) stays there and in InputForwarder+Capture/+StreamView.swift.
//
//  Split cost (the ControllerForwarder.swift note, applied here): stored
//  properties can't live in an extension, so the state these four touch stays on
//  `InputForwarder` and relies on default `internal` access - including
//  `isReady`, whose setter widened from `private(set)` to `internal(set)`
//  because `detach()` and `setReady(_:)` write it from this file.
//

import AppKit

extension InputForwarder {

    /// Install the input view on the given window and start forwarding.
    /// Call from MainActor after the window's contentView has been set.
    ///
    /// IMPORTANT: this method only puts the view in the hierarchy. It does
    /// NOT make it first responder - that has to wait until the window is
    /// actually on screen AND key. A borderless KeyableWindow can be on
    /// screen, orderedFront, and *still* not be key if NSApp wasn't active
    /// at makeKeyAndOrderFront time; any makeFirstResponder we call before
    /// the window is key is silently dropped. The caller (StreamWindow.show()
    /// via its onDidBecomeReadyForInput hook) invokes `installFirstResponder()`
    /// at the correct moment.
    public func attach(to window: NSWindow) {
        self.window = window

        // Wrap (or replace) the existing contentView with a StreamInputView so
        // we can intercept events at the responder level. We keep the old
        // contentView as a subview so the AVSampleBufferDisplayLayer hosted
        // on it keeps receiving and presenting enqueued sample buffers.
        let frame = window.contentView?.bounds ?? window.frame
        let view = StreamInputView(frame: frame)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.delegate = self

        if let existing = window.contentView {
            // Re-parent the existing contentView (which hosts the Metal layer)
            // under our input view so video keeps rendering. The Metal layer
            // sits on `existing`, not on our view - so we don't need to move
            // the layer itself, just adopt the view hierarchy.
            existing.translatesAutoresizingMaskIntoConstraints = true
            existing.autoresizingMask = [.width, .height]
            existing.frame = view.bounds
            view.addSubview(existing)
        }
        window.contentView = view
        self.inputView = view
        window.acceptsMouseMovedEvents = true

        log.info("InputForwarder attached to window; first-responder install deferred until window is key")
    }

    /// Apply first-responder to our StreamInputView. Called by StreamWindow
    /// once the window is on screen and key. Idempotent - calling it more
    /// than once is a no-op past the first successful install.
    public func installFirstResponder() {
        guard let window = self.window, let view = self.inputView else {
            log.error("installFirstResponder called with no window/view attached")
            return
        }
        // Verify preconditions before we ask AppKit to do anything. Each of
        // these is a known way for makeFirstResponder to silently fail; logging
        // them gives us a paper trail if a future macOS release changes the
        // rules out from under us.
        if !window.isKeyWindow {
            log.error("Window is not key at first-responder install - keyDown will not be delivered")
        }
        if view.window !== window {
            log.error("StreamInputView is not in the target window's hierarchy")
        }
        if !NSApp.isActive {
            log.error("NSApp is not active at first-responder install - system will not route key events to us")
        }
        let ok = window.makeFirstResponder(view)
        let responder = String(describing: window.firstResponder)
        log.info("makeFirstResponder(StreamInputView) returned \(ok, privacy: .public); first responder = \(responder, privacy: .public)")

        // Engage captured mouse mode + gesture suppression now that the
        // window is the input target. We track key/resignKey transitions
        // so Cmd-Tabbing away releases the cursor and reattaches cleanly
        // when the user comes back. This is the macOS-side equivalent of
        // SDL_SetRelativeMouseMode(true) - see the file-top comment.
        installFocusObservers(for: window)
        installGestureSuppressionMonitor()
        if window.isKeyWindow, !isWindowMode {
            enterCapturedMode()
        }
        // Window mode grabs the pointer by hover, and the bring-up made the
        // window key BEFORE the observers above existed - so the didBecomeKey
        // that would have grabbed has already been and gone. A stream opened
        // under a stationary pointer would otherwise stay ungrabbed until it
        // moved. Inert in full screen and when the pointer is elsewhere.
        captureIfPointerIsOverTheStreamView(reason: "stream window opened under the pointer")
    }

    public func detach() {
        // Raise every held key/button/modifier so a mid-press teardown can't
        // leave the host with phantom-held input.
        raiseAllHeldInputs(reason: "stream teardown")

        // Disengage relative-aim mode + remove gesture defaults.
        // `exitCapturedMode()` RE-ASSOCIATES the cursor
        // (CGAssociateMouseAndMouseCursorPosition(true)) - the guaranteed `true`
        // that pairs with the `false` from enterCapturedMode, so stream teardown
        // always hands a normal OS-controlled pointer back. Cursor VISIBILITY is
        // owned by StreamWindow: its close() / resign-key path shows the cursor
        // via `setCursorHidden(false)`, so the user is never left with an
        // invisible cursor after teardown.
        exitCapturedMode()
        // An Esc hold can be mid-dwell at teardown. No-op in full screen,
        // where nothing ever arms it.
        cancelEscapeHold()
        // A forwarder outlives one session's window (the session re-attaches
        // on a reconnect), so a latch armed by the last held Esc must not
        // survive into the next stream and swallow its first hover grab.
        isHoverCaptureSuppressed = false
        removeGestureSuppressionMonitor()
        removeDiagnosticMonitors()
        removeFocusObservers()

        inputView?.delegate = nil
        inputView = nil
        window = nil
        isReady = false

        // A quit-chord hold can be mid-dwell at teardown (the dwell firing is
        // itself one way the session ends) - cancel it so the timer can't
        // invoke onQuitHotkey against a session that's already stopping.
        cancelQuitChordDwell()

        // Balance per-controller acquisitions (DualSenseHID retain, the
        // Battery/Motion/Haptics singleton slots) and drop the controller
        // bookkeeping - the measured session-teardown leak; see
        // releaseAttachedControllers() in ControllerForwarder.swift.
        releaseAttachedControllers()
    }

    /// Called by StreamSession when the connection's `connectionStarted`
    /// callback fires. Inputs queued before this point are dropped (the C
    /// queue is closed and would just return -2).
    public func setReady(_ ready: Bool) {
        let was = isReady
        isReady = ready
        if ready != was {
            log.info("Input forwarding ready=\(ready, privacy: .public)")
            if ready {
                // Re-send arrival events for any already-attached controllers
                // so the host learns about them now that the stream is up.
                for state in attachedControllers.values {
                    sendArrival(state)
                }
                // H6: arrival's bundled fallback re-zeroes each pad, so on a
                // SILENT reconnect/wake the host reads held triggers/sticks as
                // neutral until the user twitches (valueChangedHandler only fires
                // on CHANGE). Re-read + re-forward live held state right after the
                // arrivals (idempotent; covers reconnects that keep the window key
                // and so never hit the didBecomeKey resync).
                resyncControllers()
                installDiagnosticMonitors()
            } else {
                removeDiagnosticMonitors()
            }
        }
    }
}
