//
//  StreamWindow+Fade.swift
//
//  The stream window's two OPACITY TRANSITIONS and the teardown the
//  fade-out completes: the first-frame fade-in, the menu-bar/Dock
//  presentation-options handoff that is deliberately deferred until the
//  window is opaque (the "bare-desktop flash"), and close() with its final
//  post-fade teardown. Split out of StreamWindow.swift (pure move) to keep
//  each unit under the length limit; see that file for the window's stored
//  state and the AVSampleBufferDisplayLayer rationale, and
//  StreamWindow+Show.swift for the bring-up this pairs with.
//
//  Both fades honor Reduce Motion by snapping instead of ramping - a
//  large-surface opacity animation is exactly what that setting asks us to
//  drop - and both keep the presentation-options change on the OPAQUE side
//  of the transition. MainActor throughout (AppKit).
//

import AppKit
import AVFoundation
import QuartzCore

extension StreamWindow {

    /// Animate the window from invisible (alphaValue 0) to fully visible
    /// over 350ms using the same ease-in-out timing macOS uses for app
    /// activation. Called by the session owner when VideoDecoder produces
    /// its first decoded frame. Idempotent - only runs once per show()
    /// (guarded by `awaitingFirstFrameFadeIn`), so mid-stream re-fires of
    /// the first-frame event (resolution change, decoder flush) don't
    /// re-animate an already-visible window.
    public func fadeInOnFirstFrame() {
        guard awaitingFirstFrameFadeIn else { return }
        awaitingFirstFrameFadeIn = false
        // The window is at level `mainMenuWindow + 1` (notch path) or in a
        // fullscreen Space (safe-area path), so as alphaValue ramps 0 → 1
        // it visually covers the menu bar (level 24) and the Dock (level
        // ~20). We DEFER hiding them via `NSApp.presentationOptions` until
        // AFTER the fade completes: setting those flags is instant in the
        // compositor, so doing it at fade-start leaves a one-vsync window
        // where the bars are gone but the window is still at ~0 alpha -
        // that's the "bare-desktop flash" the user was seeing. Post-fade
        // the flags become a no-op user-side because the now-opaque
        // window is already covering everything they hide.
        let win = window
        let cover = coversNotch
        // Under Reduce Motion, snap to visible instead of the 350ms fade -
        // the fade is exactly the kind of large-surface opacity ramp the
        // setting exists to suppress. We still defer presentationOptions to
        // after alpha is set so the menu bar / Dock never visibly vanish
        // against a transparent window (the "bare-desktop flash").
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 1.0
            applyPresentationOptions(coversNotch: cover)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().alphaValue = 1.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated { self.applyPresentationOptions(coversNotch: cover) }
        })
    }

    /// Hide/auto-hide the menu bar + Dock once the stream window is opaque.
    /// Extracted from `fadeInOnFirstFrame` so the fade completion handler
    /// captures no non-Sendable closure - the handler runs on the main run
    /// loop, so MainActor isolation is sound.
    private func applyPresentationOptions(coversNotch cover: Bool) {
        // Window mode never touches the app's presentation options - the menu
        // bar and Dock stay, that's the point of a window. (`show()` skipped
        // saving them too, so close() has nothing to restore.)
        guard displayMode == .fullScreen else { return }
        if cover {
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        } else {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
    }

    /// Tear the stream window down cleanly. Safe to call more than once.
    public func close() {
        guard !didClose else { return }
        didClose = true

        // 1. Display-layer flush is DEFERRED to the fade completion (step 5).
        //    Flushing here (removingDisplayedImage) blanks the layer before the
        //    fade runs, so the user only ever sees an already-empty window fade
        //    out - imperceptible. Keeping the last decoded frame on screen
        //    until the fade finishes makes the fade-out land on the actual
        //    stream content, mirroring the first-frame fade-in.

        // 2. Restore the cursor. `setCursorHidden(false)` is idempotent and
        //    drives the counted CGDisplay latch strictly off `didHideCursor`,
        //    so this brings the count back to exactly 0 - never negative. The
        //    old unconditional belt-and-braces `NSCursor.unhide()` is gone:
        //    with the latch capped at 1 by the single-owner helper it could
        //    only ever over-show and corrupt the count, which is the very
        //    failure mode (cursor left invisible / over-visible) we're fixing.
        setCursorHidden(false)

        // Drop the key-status observers so we don't get a delayed
        // become/resign callback after the window has been torn down.
        for token in keyObservers {
            NotificationCenter.default.removeObserver(token)
        }
        keyObservers.removeAll()
        // Workspace observers live on NSWorkspace's own notification center -
        // remove them from THAT center, not the default one.
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsnc.removeObserver(token)
        }
        workspaceObservers.removeAll()
        // Path B's one-shot didEnterFullScreen token: consumed by its own
        // closure on the happy path, but a session that ends before AppKit
        // posts the enter notification leaves it registered - sweep it here.
        if let token = enterFullScreenObserver {
            NotificationCenter.default.removeObserver(token)
            enterFullScreenObserver = nil
        }
        // Path B's Space-exit observers (StreamWindow+Windowed.swift) - the
        // toggleFullScreen in step 4 below would otherwise fire them against
        // a closing window. `didClose` already gates them; sweeping is the
        // clean cut.
        for token in spaceExitObservers {
            NotificationCenter.default.removeObserver(token)
        }
        spaceExitObservers.removeAll()
        // Window mode: persist the frame under its autosave name and release
        // the name, so the next session's window can claim it (see
        // StreamWindow+Windowed.swift).
        if displayMode == .window { finishWindowedFrameAutosave() }

        // 3. Restore the app's presentation options BEFORE orderOut'ing the
        //    window. Order matters: if we orderOut first, the user briefly
        //    sees their desktop with the menu bar/Dock still hidden as
        //    AppKit catches up - a flash of "what happened to my menu bar".
        //    Restoring first means by the time the window disappears, the
        //    chrome is already back.
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
            previousPresentationOptions = nil
        }

        // 4. Exit the Space-based fullscreen. If the window never made it
        //    into fullscreen (early failure path), this is a no-op.
        //    `toggleFullScreen` runs an async animation; orderOut + activate
        //    after the exit notification fires would be cleaner, but the
        //    in-flight orderOut below still works in practice because AppKit
        //    queues the orderOut after the exit-fullscreen Space animation.
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        // 5. Drop first responder, fade out, orderOut. Fading instead of a
        //    hard orderOut gives the user a 250ms acknowledgement that the
        //    stream ended - without the fade the window snaps off and the
        //    launcher snaps in, which reads as a crash. Apple's first-party
        //    fullscreen surfaces (Apple TV's playback window, QuickTime's
        //    presentation mode) all fade on exit.
        window.makeFirstResponder(nil)
        let win = window

        // Under Reduce Motion, snap instead of the 250ms opacity ramp - same
        // policy as the first-frame fade-in (a large-surface opacity animation
        // is exactly what Reduce Motion asks us to drop).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 0.0
            finishClose()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated { self.finishClose() }
        })
    }

    /// Final teardown step, run once the close fade has finished (or
    /// immediately under Reduce Motion). Extracted from `close()` so the fade
    /// completion handler captures no non-Sendable closure - it runs on the
    /// main run loop, so MainActor isolation is sound.
    ///
    /// Hands off to the launcher only AFTER the stream has faded out. Doing it
    /// synchronously (during the fade) brings the launcher in front of the
    /// still-fading stream window, which masks the fade entirely and reads as a
    /// hard cut. Deferring it makes the exit a real fade-out, mirroring the
    /// first-frame fade-in. `NSApp.activate()` is the macOS 14+ replacement for
    /// `activate(ignoringOtherApps:)`.
    private func finishClose() {
        // Now that the window is invisible, drop the last frame + hide it.
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        window.orderOut(nil)
        // Reset alphaValue so a future show() of this window isn't
        // invisible (defensive - close() is currently the last call).
        window.alphaValue = 1.0
        NSApp.activate()
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Glimmer" }) {
            main.makeKeyAndOrderFront(nil)
        }
    }
}
