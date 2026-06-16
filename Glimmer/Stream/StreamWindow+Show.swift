//
//  StreamWindow+Show.swift
//
//  StreamWindow.show() — the borderless full-screen window bring-up: screen
//  placement, presentation-options/notch handling, space + activation policy,
//  cursor hiding, and the focus/space observers. Split out of StreamWindow.swift
//  to keep each unit focused; see that file for the window's stored state.
//

import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import os.log

extension StreamWindow {

    public func show() {
        // 1. Save the host app's current presentation options so we can put
        //    them back verbatim on close(). Pulling this from NSApp at
        //    show() time (rather than caching a constant) means we cooperate
        //    with anything else in the app that fiddles with presentation
        //    options between sessions.
        previousPresentationOptions = NSApp.presentationOptions

        // 2. Choose presentation options. NOT APPLIED HERE — they're
        //    applied in `fadeInOnFirstFrame()` so the menu bar / Dock stay
        //    visible during the C-handshake gap. Hiding them at show()
        //    time exposed the bare desktop (no menu bar, no
        //    Dock) for several hundred ms while the stream connected,
        //    which read as a letterbox flash. The choice of options
        //    themselves is unchanged; only the timing moved.
        //
        //    The candidates and why we picked what we picked:
        //
        //      .hideMenuBar           — totally hides the menu bar. Combined
        //                               with .hideDock this is the most
        //                               aggressive option. Downside: AppKit
        //                               can be funny about restoring state
        //                               cleanly if the app crashes mid-stream.
        //      .autoHideMenuBar       — menu bar slides away but reveals on
        //                               cursor-to-top. While the stream is up
        //                               the window is sized to the full
        //                               screen at `.normal` level; AppKit
        //                               does not surface the menu bar over a
        //                               frontmost window in this mode, so
        //                               the reveal-on-top behaviour does not
        //                               actually paint anything on the user.
        //                               This is what we use.
        //      .disableProcessSwitching — blocks Cmd-Tab from switching out.
        //                               We deliberately DON'T set this:
        //                               we want the user to be able to
        //                               Cmd-Tab away if they need to (e.g.
        //                               an urgent message). Cmd-Tab away
        //                               drops us behind the new active app,
        //                               which is the correct UX.
        //
        //    .autoHideDock is paired with .autoHideMenuBar because AppKit
        //    requires them to be set together (setting .autoHideMenuBar
        //    without auto-hiding the Dock raises NSInvalidArgumentException).
        //
        //    UPDATE: switched from .autoHideMenuBar → .hideMenuBar so the
        //    window actually owns the full panel area on notched MacBooks.
        //    `.autoHideMenuBar` keeps the 37pt menu-bar zone reserved (the
        //    bar slides in on cursor-to-top), which means our fullscreen
        //    frame is screen.frame.height = 1890 on a 14" MBP instead of
        //    the panel's true 1964. The bitstream we receive is 1964 tall;
        //    resizeAspect then letterboxes left/right ~57px. `.hideMenuBar`
        //    actually hides the bar entirely and lets the window cover the
        //    full physical panel including the notch zone — matching what
        //    SDL FULLSCREEN_DESKTOP gives moonlight-qt. There's no
        //    in-stream menu-bar-reveal in this mode, which we don't want
        //    during gaming anyway (the cursor is hidden + associate-false while
        //    relative aim is engaged).
        //    The safe-area opt-out is the `coversNotch` toggle below.
        // Sync the delegate's notch-coverage flag with the public toggle
        // so AppKit's willUseFullScreenContentSize: returns the right
        // size when the user clicks Stream. The presentation-options
        // application is deferred to `fadeInOnFirstFrame()` (see above).
        streamDelegate.coversNotch = coversNotch

        // 3. Bring the *app* to the foreground before we ask the *window* to
        //    become key. macOS will refuse key status to any window of a non-
        //    active app, which is exactly the trap we hit when the stream is
        //    launched from a SwiftUI button: the click activates the host
        //    window briefly, our borderless KeyableWindow comes up, and
        //    without an explicit activate the new window is "on screen but
        //    not key" — mouseMoved fires (it's hover, not focus), but
        //    keyDown does not.
        NSApp.activate()

        // 4. Cover the screen. We size to the current NSScreen.main frame so
        //    if the user dragged the main Glimmer window onto a non-primary
        //    display before clicking Stream, we cover *that* display rather
        //    than always landing on the system primary.
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            window.setFrame(screen.frame, display: true)
        }

        // 4b. PRE-EMPTIVELY warp the cursor to the screen center, ONCE, as a
        //     cosmetic pre-position before relative aim engages. This runs
        //     BEFORE the relative-delta pipeline and the associate-false latch
        //     are live (enterCapturedMode fires later via installFirstResponder
        //     / the becomeKey observer), so it cannot inject a motion delta to
        //     the host. Its only job is to place the (about-to-be-hidden,
        //     about-to-be-disassociated) cursor somewhere sane. The Y-convention
        //     is handled by the shared `StreamCursor.warpToCentre` helper (CGWarp
        //     wants Quartz top-left, not AppKit bottom-left; the helper also
        //     handles the non-primary/scaled-screen flip correctly).
        if let screen {
            StreamCursor.warpToCentre(of: screen)
        }
        // NOTE: the actual relative-aim engagement —
        // `CGAssociateMouseAndMouseCursorPosition(false)` — is done by
        // InputForwarder.enterCapturedMode() once the window is key, NOT here.
        // This is the SDL_SetRelativeMouseMode(true) recipe: the OS stops moving
        // the (already-hidden, see setCursorHidden below) cursor so it can never
        // reach a hot corner, and relative HID deltas are read off the CGEvent's
        // kCGMouseEventDeltaX/Y. The prior associate-false attempt failed only
        // because it was paired with NSEvent.deltaX/Y (which goes silent) and no
        // hide; both are fixed now. See the file-top notes in
        // InputForwarder+Capture.swift for the full contract.

        // 5. Two fullscreen paths, picked by `coversNotch`. This mirrors
        //    moonlight-qt's session.cpp:588 logic for handling notched
        //    MacBook displays, which in turn maps to SDL's
        //    `SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES` hint:
        //
        //    A) coversNotch == true  → SDL_HINT…=0  → borderless covering
        //       window at .mainMenu level + 1 (above the menu bar). NO
        //       Space-based fullscreen. The window owns the entire physical
        //       panel including the notch zone; the layer paints up to the
        //       physical notch cutout. HDR engages because we're the
        //       topmost layer-host on the display. moonlight-qt routes
        //       here when the user picks the full-native resolution.
        //
        //    B) coversNotch == false → SDL_HINT…=1  → Space-based
        //       fullscreen via toggleFullScreen. AppKit handles the Space
        //       creation and reserves the menu-bar / notch area as safe
        //       inset, so content lays out below the notch. Used when the
        //       user explicitly wants the safe-area framing.
        //
        //    Earlier the codebase hardcoded path B because we believed
        //    HDR engagement required Space-based fullscreen — that's only
        //    half-right. Borderless at .mainMenu level + the right
        //    presentation options also engages HDR (which is what
        //    moonlight-qt has been doing all along).
        // Start invisible — we fade in on the first decoded frame so the
        // user never sees the borderless covering window mid-handshake
        // (an empty AVSampleBufferDisplayLayer renders black and reads
        // as "macOS desktop with letterbox bars"). `fadeInOnFirstFrame()`
        // is called by the session when VT produces its first frame.
        window.alphaValue = 0.0
        awaitingFirstFrameFadeIn = true

        if coversNotch {
            // Borderless covering window above the menu bar level.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            // Cover the full screen frame INCLUDING the notch zone.
            // On Sonoma+, screen.frame already covers the notch area.
            if let targetScreen = window.screen ?? screen {
                window.setFrame(targetScreen.frame, display: true)
            }
            window.makeKeyAndOrderFront(nil)
            // Force-fit the content view to the full window — no Space
            // transition to wait on, so do this synchronously here.
            if let cv = window.contentView {
                cv.frame = NSRect(origin: .zero, size: window.frame.size)
                cv.autoresizingMask = [.width, .height]
                displayLayer.frame = cv.bounds
            }
            let frameWidth = self.window.frame.size.width
            let frameHeight = self.window.frame.size.height
            self.log.info(
                "Stream window borderless-covering — frame \(frameWidth, privacy: .public)×\(frameHeight, privacy: .public)"
            )
            // No Space animation; install input + cursor capture next runloop.
            DispatchQueue.main.async { [weak self] in
                self?.onDidBecomeReadyForInput?()
            }
        } else {
            // Path B: Space-based fullscreen → safe-area framing.
            window.makeKeyAndOrderFront(nil)
            // One-shot enter observer, stored on the window (not a closure-
            // local box) so close() can sweep it when the session ends before
            // AppKit ever posts the notification — a connect-fail inside the
            // ~1s Space-enter animation, or the dropped-notification quirk the
            // 1.5s backstop below covers. The closure body executes MainActor-
            // isolated via `assumeIsolated` (we asked for queue: .main).
            enterFullScreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Consume the one-shot token FIRST — on the didClose path
                    // too — so the observation can't outlive its single fire.
                    if let token = self.enterFullScreenObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.enterFullScreenObserver = nil
                    }
                    // Same didClose guard as every sibling observer: an enter
                    // notification landing during the close fade must not run
                    // first-responder install on a torn-down session.
                    guard !self.didClose else { return }
                    self.log.info("Stream window entered Space-based fullscreen (safe-area)")
                    self.onDidBecomeReadyForInput?()
                }
            }
            window.toggleFullScreen(nil)
        }

        setCursorHidden(true)

        installLifecycleObservers()

        // NOTE: cursor ASSOCIATION (the SDL_SetRelativeMouseMode equivalent) is
        // owned by InputForwarder.enterCapturedMode()/exitCapturedMode(), which
        // call CGAssociateMouseAndMouseCursorPosition(false/true) on the window's
        // becomeKey/resignKey transitions — NOT here. StreamWindow owns only
        // cursor VISIBILITY via `setCursorHidden(true)` (CGDisplayHideCursor, the
        // single owner). Together: the cursor is hidden (so there's no visible
        // pointer to freeze) AND disassociated (so the OS stops moving it and
        // relative HID deltas read off the CGEvent's kCGMouseEventDeltaX/Y are
        // pure — no warp, no edge, no reconciliation delta to leak). This is the
        // P0 mouse-snap fix; see InputForwarder+Capture for the contract.

        // 6. Safety-net first-responder install. The didEnterFullScreen
        //    observer above handles the happy path — it fires onDidBecome-
        //    ReadyForInput after AppKit finishes the Space-creation
        //    animation. But if that notification is dropped for any reason
        //    (older macOS quirk, fullscreen transition fails), we'd be
        //    left without an installed first responder and the user's
        //    hotkeys never fire. A 1.5s backstop covers it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let win = self.window
            let isKey = win.isKeyWindow
            let isFullscreen = win.styleMask.contains(.fullScreen)
            let level = win.level.rawValue
            let firstResponder = String(describing: win.firstResponder)
            self.log.info(
                """
                Post-show state: isKeyWindow=\(isKey, privacy: .public) \
                isFullscreen=\(isFullscreen, privacy: .public) \
                level=\(level, privacy: .public) \
                firstResponder=\(firstResponder, privacy: .public)
                """
            )
            if !win.isKeyWindow {
                self.log.error("Window not key 1.5s after show(); retrying activate + makeKeyAndOrderFront + first-responder install")
                NSApp.activate()
                win.makeKeyAndOrderFront(nil)
                self.onDidBecomeReadyForInput?()
            }
        }
    }

    /// Register the key-status / screen-change / display-wake observers that
    /// keep the cursor-hide latch balanced and the FramePacer link bound to the
    /// live display. Split out of `show()` so each unit stays focused; the
    /// behaviour is unchanged (same notifications, same MainActor-isolated
    /// handlers, same observer-array bookkeeping for `close()` teardown).
    private func installLifecycleObservers() {
        // Track key status so the cursor follows it. The CGDisplay hide is a
        // process-wide reference-counted latch; without these observers,
        // Cmd-Tabbing away leaves the cursor invisible everywhere on the Mac
        // until the user comes back. Pair every hide with a show on resign,
        // and every show with a re-hide on becomeKey — both routed through the
        // single-owner `setCursorHidden(_:)` so the latch count stays at 1.
        let nc = NotificationCenter.default
        // Snapshot the streaming window level we set above so we can put it
        // back when the user Cmd-Tabs into us. We can't unconditionally
        // raise to `mainMenuWindow + 1` because in the safe-area
        // (`coversNotch == false`) path the window is in a fullscreen
        // Space and AppKit owns its level.
        let streamingLevel = window.level
        // Persist the streaming level so the shared foreground re-engage
        // (`reengageForeground()`, used by BOTH return paths) can restore it
        // after a resign dropped us to `.normal`.
        self.streamingWindowLevel = streamingLevel
        // Resume from the launcher is intentionally explicit (the
        // "Back to stream" CTA → `StreamWindow.show()`). An
        // `NSApplication.didBecomeActiveNotification` observer that
        // auto-orderFronted the stream window would yank the user back
        // into the stream the moment they clicked the launcher / Dock
        // icon to change a setting — same UX as QuickTime's
        // "Reopen Window" and Music's "Mini Player".
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, !self.didClose else { return }
            // DEBOUNCE the resign. A genuine Cmd-Tab-away / app deactivation
            // resigns the stream window AND keeps it resigned. A transient
            // key flutter — most importantly a DualSense/HID controller
            // connecting over Bluetooth mid-stream — resigns the borderless
            // window for a frame and then snaps key back within the same
            // run loop, posting didBecomeKey almost immediately. The naive
            // synchronous teardown (`orderOut` + restore presentation
            // options) ran on EVERY resign, so a controller-connect blip
            // ordered the stream window off screen and uncovered the still-
            // alive, dimmed launcher window for one frame — a blank/dark
            // flash over the live stream. Defer the teardown and re-check
            // that we're truly backgrounded before committing to it.
            self.resignGeneration &+= 1
            let generation = self.resignGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.didClose else { return }
                    // A becomeKey (or a later resign) bumped the token — this
                    // resign was a transient blip, not a real background. Bail.
                    guard self.resignGeneration == generation else {
                        self.log.info("Stream window resign was a transient key blip — teardown cancelled (stream stays foregrounded)")
                        return
                    }
                    // The app is still active (an in-process key flutter from a
                    // BT/HID connect does NOT deactivate the app) OR the window
                    // re-took key — not a real Cmd-Tab-away. Bail. A genuine
                    // background flips NSApp.isActive false and leaves the
                    // window non-key, so this only short-circuits the blip case.
                    guard !NSApp.isActive, !self.window.isKeyWindow else {
                        self.log.info("Stream window still active/key after resign debounce — teardown cancelled (stream stays foregrounded)")
                        return
                    }
                    // Confirmed genuine background (Cmd-Tab-away / app
                    // deactivate): run the teardown.
                    self.backgroundStreamWindow()
                }
            }
          }
        })
        // Screen-change: the window was dragged to another display (or its
        // backing display's mode changed / woke from sleep). Notify the owner
        // so the FramePacer rebinds its CADisplayLink to the new screen's
        // cadence. AppKit's NSView.displayLink already follows the view across
        // screens in the common case, but a hard mode change / sleep-wake can
        // leave the old link silently stopped — rebinding is the safe fix.
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Stream window changed screen — rebinding pacer link")
                self.onScreenChanged?()
                // A display swap can make the WindowServer re-show the cursor
                // behind the one-shot hide latch; re-assert (no-op unless we're
                // the desired-hidden owner and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        // Same-screen display reconfiguration. `didChangeScreenNotification`
        // ONLY fires when the window's backing NSScreen changes (a cross-
        // display drag). It does NOT fire for a display MODE / HDR / VRR
        // transition on the SAME external panel — exactly the 4K240 HDR/VRR
        // "first HDR engagement" case that silently stopped the CADisplayLink
        // and hard-froze the stream. `NSApplication.didChangeScreenParameters`
        // DOES fire on those mode/HDR/VRR changes (the display's parameters
        // changed even though the window stayed on it), so route it to the same
        // pacer-rebind path. Object is nil — it's an app-wide notification.
        keyObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Screen parameters changed (mode/HDR/VRR) — rebinding pacer link")
                self.onScreenChanged?()
                // This is exactly the HDR/VRR-engage reconfig that makes
                // the WindowServer re-show the cursor mid-stream. Re-assert the
                // hide here so it's repaired before the next mouse move (no-op
                // unless we're the desired-hidden owner and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        // Display wake. The link can silently stop across a display sleep on
        // the external panel and is never rebuilt by either notification above
        // (no screen swap, no parameter change on wake in some configs). The
        // workspace screens-did-wake notification is the reliable signal.
        // Lives on NSWorkspace.shared.notificationCenter, NOT the default
        // center — a common gotcha. Tracked in `workspaceObservers` so close()
        // removes it from the right center.
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wsnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Displays woke — rebinding pacer link")
                self.onScreenChanged?()
                // Display sleep-wake re-shows the cursor behind the latch too;
                // re-assert the hide (no-op unless we're the desired-hidden owner
                // and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, !self.didClose else { return }
            // Cancel any pending resign teardown: a becomeKey that lands
            // inside the resign debounce window means the resign was a
            // transient key blip (e.g. a DualSense connecting over Bluetooth
            // mid-stream momentarily fluttered key away and back). Bumping the
            // shared generation token makes the deferred resign handler bail,
            // so the stream window is never ordered out and the launcher never
            // flashes. reengageForeground() below is idempotent/latch-safe.
            self.resignGeneration &+= 1
            // Funnel through the SINGLE shared foreground re-engage so this
            // Cmd-Tab/reactivation path is byte-for-byte identical to the
            // menubar "Back to stream" path (`resumeWindow()` calls the same
            // method). Re-hides the cursor (idempotent latch), restores the
            // streaming level, re-applies the fullscreen presentation flags,
            // and fires onBackgroundedChanged(false).
            self.reengageForeground()
            self.log.info(
                "Stream window became key — re-engaged foreground (level \(streamingLevel.rawValue, privacy: .public))")
          }
        })
        installAppReactivationObserver(nc: nc)
    }

    /// App reactivation. Cmd-Tab BACK fires the didBecomeKey observer above,
    /// and the launcher "Back to stream" CTA calls reengageForeground()
    /// directly — but a THIRD return path was uncovered: clicking the DOCK
    /// ICON after a Cmd-Tab away. AppKit's reopen/reactivation machinery can
    /// order the stream window front and resolve its key status synchronously,
    /// without posting a fresh didBecomeKey (the same AppKit edge the
    /// resumeWindow() comment in reengageForeground() documents), so the
    /// cursor-hide latch never re-engaged and the arrow sat visible over the
    /// stream. `didBecomeActive` is the reactivation signal that DOES always
    /// fire; gate on the stream window being key so a Dock click that surfaces
    /// the LAUNCHER (the intentional "don't yank back" design in
    /// installLifecycleObservers) stays untouched. The
    /// `awaitingFirstFrameFadeIn` gate keeps this from applying the streaming
    /// presentation flags during the initial show()'s own NSApp.activate()
    /// (whose notification can land after this observer registers) — those
    /// flags are deliberately deferred to the first-frame fade-in (the
    /// bare-desktop-flash fix). reengageForeground() is idempotent/latch-safe,
    /// so the common case where didBecomeKey ALSO fired is a harmless
    /// double-call.
    private func installAppReactivationObserver(nc: NotificationCenter) {
        keyObservers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, !self.awaitingFirstFrameFadeIn,
                      self.window.isKeyWindow else { return }
                // Foreground again with the stream window key — any pending
                // resign teardown is stale (same role as didBecomeKey's bump).
                self.resignGeneration &+= 1
                self.reengageForeground()
                self.log.info("App reactivated with stream window key — re-engaged foreground (cursor re-hidden)")
            }
        })
    }

    /// Background the stream window: restore the cursor, order the window off
    /// screen, restore the host's presentation options, and notify the owner.
    ///
    /// Called ONLY from the resign observer's debounced deferred block, after it
    /// has confirmed a genuine Cmd-Tab-away / app deactivation. It is NOT run on
    /// the sub-second key flutter a Bluetooth controller connect produces
    /// mid-stream — that path is short-circuited by the resign-generation token
    /// + NSApp.isActive guard, so the still-alive (dimmed) launcher window is
    /// never uncovered for a frame. didBecomeKey's reengageForeground() reverses
    /// all of this on the way back in.
    func backgroundStreamWindow() {
        // Cursor: restore so the user can interact with whatever app they
        // Cmd-Tabbed to. Idempotent + latch-balanced via the single owner —
        // shows iff currently hidden, bringing the count to 0.
        setCursorHidden(false)
        // Window level: in the borderless-covering path we parked the window
        // above the menu-bar level so it covers the notch. That also keeps it
        // painted ON TOP of any other app the user Cmd-Tabs to, which makes
        // Cmd-Tab / Cmd-Space feel broken — they think their selected app didn't
        // surface.
        //
        // Cleanest possible passivity while the user is in another app: orderOut
        // the entire window. A fullscreen-covering window at `.normal` level with
        // `ignoresMouseEvents = true` is supposed to let everything pass through,
        // but in practice the Dock's bottom-edge hover-show heuristic and a few
        // other macOS window-manager behaviours stop firing because our window
        // still owns the geometry. orderOut removes us from screen entirely — the
        // stream session keeps running (the AVSampleBufferDisplayLayer is
        // independent of window visibility, and StreamSession owns the
        // lifecycle), and the user can use the Dock / Settings / any other app
        // without Glimmer being part of the picture. On didBecomeKey we
        // orderFront + restore level / cursor.
        window.orderOut(nil)
        // Restore the app's presentation options so the user gets their menu bar
        // and Dock back while interacting with the launcher / Settings / any
        // other app. Without this, the [.hideMenuBar, .hideDock] flags we set in
        // show() stick around — the launcher window appears with the menu bar
        // still hidden and the Dock still auto-hidden, which reads as "Glimmer is
        // still in fullscreen even though I clicked away". didBecomeKey re-applies
        // the streaming flags when we come back.
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
        }
        onBackgroundedChanged?(true)
        log.info("Stream window resigned key — cursor restored, window ordered out (stream continues in background)")
    }
}
