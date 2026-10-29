// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Free pointers map onto the picture; relative capture shares its existing
// association, linear scaling and cursor-ownership paths in every presentation.

import GlimmerEngine
import AppKit

extension InputForwarder {

    /// Native fullscreen tracking can outlive focus through a Space transition.
    /// Relative aim requires capture; a key window also permits a free pointer.
    var forwardsMouseEvents: Bool {
        guard let window, window.isKeyWindow, !window.ignoresMouseEvents else { return false }
        return sendsAbsolutePointer || isMouseCaptured
    }

    /// A free pointer mirrors the picture whenever the current policy permits it.
    var sendsAbsolutePointer: Bool {
        Self.usesAbsolutePointer(windowed: isWindowMode, captured: isMouseCaptured,
                                          fullscreenRelative: fullscreenRelativePointer)
    }

    nonisolated static func usesAbsolutePointer(windowed: Bool, captured: Bool, fullscreenRelative: Bool) -> Bool {
        !captured && (windowed || !fullscreenRelative)
    }

    /// A presentation change restores its pointer policy without retaining a stale hover latch.
    func setWindowMode(_ enabled: Bool) {
        guard isWindowMode != enabled else { return }
        isWindowMode = enabled
        defer { updateSystemKeyCapture() }
        if enabled {
            exitCapturedMode()
            log.info("Pointer policy: relative capture while the pointer is over the window")
        } else {
            // Leaving window mode retires the latch with the rule it belongs
            // to: full screen never reads it, and a later return to a window
            // must not inherit a stale "do not grab" from the last release.
            isHoverCaptureSuppressed = false
            if fullscreenRelativePointer {
                enterCapturedMode()
            } else {
                exitCapturedMode()
            }
            log.info("Pointer policy: full screen, relative=\(self.fullscreenRelativePointer, privacy: .public)")
        }
    }

    /// The mini player never grabs on hover: a click takes the pointer and a
    /// held Esc or the chord gives it back. Entering releases a held grab so
    /// the user can go and do something else; the view accepts the activating
    /// click so one click on an inactive panel lands in the game.
    func setMiniPlayer(_ enabled: Bool) {
        guard isMiniPlayer != enabled else { return }
        isMiniPlayer = enabled
        updateControllerBackgroundEvents()
        if enabled {
            resyncControllers()
        } else if window?.isKeyWindow == false {
            cancelQuitChordDwell(reason: "mini player ended in the background")
            neutralizeControllers()
        }
        inputView?.acceptsActivatingClick = enabled
        if enabled, isMouseCaptured { releasePointer(reason: "mini player") }
        log.info("Pointer policy: \(enabled ? "click to capture (mini player)" : "capture while over the window", privacy: .public)")
    }

    /// Fullscreen remembers the toggle across focus loss; window mode keeps its hover latch.
    func togglePointerCapture(reason: String) {
        guard let window, window.isKeyWindow, !window.ignoresMouseEvents else { return }
        if !isWindowMode { fullscreenRelativePointer = !isMouseCaptured }
        if isMouseCaptured {
            releasePointer(reason: reason)
        } else {
            capturePointer(reason: reason)
        }
        onPointerModeToggled?(isMouseCaptured)
    }

    /// Background windows must never take the pointer from the active Mac app.
    func capturePointer(reason: String) {
        guard !isMouseCaptured, let window, window.isKeyWindow else { return }
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
        let count = heldMouseButtons.count
        for button in heldMouseButtons { releaseMouse(button) }
        if count > 0 { Diag.notice("input: released \(count) held mouse button(s) on \(reason)", "Stream") }
    }

    /// Align the PC before relative aim takes over, including capture without an event.
    /// This intentionally bypasses the free-pointer gate used by motion and clicks.
    func syncHostPointerToCurrentLocation() {
        guard isReady, let window, let view = inputView else { return }
        let viewPoint = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard view.bounds.contains(viewPoint) else { return }
        inputCore.sendAbsolutePointer(viewPoint: viewPoint, viewSize: view.bounds.size,
                                      streamPixelSize: streamPixelSize, captureSync: true)
    }

    func sendAbsolutePointer(for event: NSEvent, in view: NSView) {
        guard isReady, sendsAbsolutePointer else { return }
        inputCore.sendAbsolutePointer(viewPoint: view.convert(event.locationInWindow, from: nil),
                                      viewSize: view.bounds.size, streamPixelSize: streamPixelSize, captureSync: false)
    }
}
