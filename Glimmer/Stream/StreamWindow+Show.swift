//
//  StreamWindow+Show.swift
//
//  StreamWindow.show() - the borderless full-screen window bring-up: screen
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
        // Window mode has its own bring-up (StreamWindow+Windowed.swift): a
        // titled window, no presentation-options change, no cover, no cursor
        // hide. Everything else is the fullscreen path, unchanged.
        if displayMode == .window { showWindowed(); return }
        presentFullScreen(firstShow: true)
    }

    /// The fullscreen bring-up. `firstShow` fades in on the first decoded
    /// frame; the return from the mini player is already showing video, so
    /// it stays opaque and takes the presentation options at once.
    func presentFullScreen(firstShow: Bool) {
        // 1. Save the host app's current presentation options so we can put
        //    them back verbatim on close(). Pulling this from NSApp at
        //    show() time (rather than caching a constant) means we cooperate
        //    with anything else in the app that fiddles with presentation
        //    options between sessions.
        previousPresentationOptions = NSApp.presentationOptions

        // 2. The menu bar and Dock stay until the first frame: the fade-in hides
        //    them, since hiding them now shows a bare desktop through the
        //    still-invisible window (applyPresentationOptions has the set).
        streamDelegate.coversNotch = coversNotch

        // 3. Bring the *app* to the foreground before we ask the *window* to
        //    become key. macOS will refuse key status to any window of a non-
        //    active app, which is exactly the trap we hit when the stream is
        //    launched from a SwiftUI button: the click activates the host
        //    window briefly, our borderless KeyableWindow comes up, and
        //    without an explicit activate the new window is "on screen but
        //    not key" - mouseMoved fires (it's hover, not focus), but
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

        // 4b. The first show parks the cursor at the fade-in. A return from the
        //     mini player re-centres it only if it sits off this screen, where the
        //     frozen cursor would take clicks outside the cover.
        if !firstShow, let screen, !StreamCursor.isOnScreen(NSEvent.mouseLocation, frame: screen.frame) {
            warpCursorToCentre(of: screen)
        }

        // 5. Two fullscreen paths, picked by `coversNotch`. This mirrors
        //    moonlight-qt's session.cpp:588 logic for handling notched
        //    MacBook displays, which in turn maps to SDL's
        //    `SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES` hint:
        //
        //    A) coversNotch == true  → SDL_HINT...=0  → borderless covering
        //       window at .mainMenu level + 1 (above the menu bar). NO
        //       Space-based fullscreen. The window owns the entire physical
        //       panel including the notch zone; the layer paints up to the
        //       physical notch cutout. HDR engages because we're the
        //       topmost layer-host on the display. moonlight-qt routes
        //       here when the user picks the full-native resolution.
        //
        //    B) coversNotch == false → SDL_HINT...=1  → Space-based
        //       fullscreen via toggleFullScreen. AppKit handles the Space
        //       creation and reserves the menu-bar / notch area as safe
        //       inset, so content lays out below the notch. Used when the
        //       user explicitly wants the safe-area framing.
        // Start invisible - we fade in on the first decoded frame so the
        // user never sees the borderless covering window mid-handshake
        // (an empty AVSampleBufferDisplayLayer renders black and reads
        // as "macOS desktop with letterbox bars"). `fadeInOnFirstFrame()`
        // is called by the session when VT produces its first frame.
        if firstShow {
            window.alphaValue = 0.0
            awaitingFirstFrameFadeIn = true
        }

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
            // Force-fit the content view to the full window - no Space
            // transition to wait on, so do this synchronously here.
            if let cv = window.contentView {
                cv.frame = NSRect(origin: .zero, size: window.frame.size)
                cv.autoresizingMask = [.width, .height]
                displayLayer.frame = cv.bounds
            }
            let frameWidth = self.window.frame.size.width
            let frameHeight = self.window.frame.size.height
            self.log.info(
                "Stream window borderless-covering - frame \(frameWidth, privacy: .public)×\(frameHeight, privacy: .public)"
            )
            // No Space animation; install input + cursor capture next runloop.
            DispatchQueue.main.async { [weak self] in
                // didClose guard like every sibling: a connect that fails/cancels
                // before this runs must not re-capture a torn-down session.
                guard let self, !self.didClose else { return }
                self.onDidBecomeReadyForInput?()
            }
        } else {
            // Path B: Space-based fullscreen → safe-area framing.
            window.makeKeyAndOrderFront(nil)
            // One-shot enter observer, stored on the window (not a closure-
            // local box) so close() can sweep it when the session ends before
            // AppKit ever posts the notification - a connect-fail inside the
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
                    // Consume the one-shot token FIRST - on the didClose path
                    // too - so the observation can't outlive its single fire.
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
            // A user-driven exit from this Space (Mission Control, the Esc
            // gesture) used to leave a vanished window over a still-running
            // stream (issue #84). It now lands the session in a window - see
            // StreamWindow+Windowed.swift for the conversion these drive.
            installSpaceExitObservers()
            window.toggleFullScreen(nil)
        }

        installLifecycleObservers()
        refreshPresentationVisibility()
        // The first show leaves the cursor and the menu bar to the fade-in.
        if !firstShow {
            setCursorHidden(true)
            applyPresentationOptions(coversNotch: coversNotch)
        }

        // NOTE: cursor ASSOCIATION (the SDL_SetRelativeMouseMode equivalent) is
        // owned by InputForwarder.enterCapturedMode()/exitCapturedMode(), which
        // call CGAssociateMouseAndMouseCursorPosition(false/true) on the window's
        // becomeKey/resignKey transitions - NOT here. StreamWindow owns only
        // cursor VISIBILITY via `setCursorHidden(true)` (CGDisplayHideCursor, the
        // single owner). Together: the cursor is hidden (so there's no visible
        // pointer to freeze) AND disassociated (so the OS stops moving it and
        // relative HID deltas read off the CGEvent's kCGMouseEventDeltaX/Y are
        // pure - no warp, no edge, no reconciliation delta to leak). This is the
        // P0 mouse-snap fix; see InputForwarder+Capture for the contract.

        installKeyBackstop()
    }

    /// Safety-net first-responder install. The didEnterFullScreen observer
    /// handles the happy path; if that notification is dropped (older macOS
    /// quirk, a failed transition) the hotkeys would never fire, so a 1.5 s
    /// backstop re-activates and re-installs.
    private func installKeyBackstop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // didClose: the close fade keeps the window alive ~250ms. A Cmd-Tab
            // away is the user's choice, not an activate the system refused.
            guard let self, !self.didClose, !self.userBackgrounded,
                  !Self.isTransientFocusLoss(NSWorkspace.shared.frontmostApplication?.activationPolicy) else { return }
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

    /// Focus changes release input immediately; only a lasting app switch retires the cover.
    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        streamingWindowLevel = window.level
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.scheduleFocusLoss()
            }
        })
        installDisplayObservers(nc: nc)
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.resignGeneration &+= 1
                self.reengageForeground()
                self.log.info("Stream window became key - re-engaged foreground")
            }
        })
        // An overlay can hand focus to another app without a second stream resign.
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wsnc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let otherRegularApp = app.map {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
            } ?? false
            MainActor.assumeIsolated {
                guard let self, !self.didClose, otherRegularApp else { return }
                self.scheduleFocusLoss()
            }
        })
        installAppReactivationObserver(nc: nc)
    }

    /// Keep the debounce for controller key flutter and re-read the frontmost app at expiry.
    private func scheduleFocusLoss() {
        resignGeneration &+= 1
        let generation = resignGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.didClose, self.resignGeneration == generation,
                  !self.window.isKeyWindow else { return }
            // A Space may lose key to our launcher without deactivating the app.
            guard !NSApp.isActive || !self.coversNotch else { return }
            self.handleFocusLoss(NSWorkspace.shared.frontmostApplication?.activationPolicy)
        }
    }

    /// Accessory surfaces have no menu bar; restoring ours can steal their activation.
    nonisolated static func isTransientFocusLoss(_ policy: NSApplication.ActivationPolicy?) -> Bool {
        guard let policy else { return false }
        return policy != .regular
    }

    func handleFocusLoss(_ policy: NSApplication.ActivationPolicy?) {
        guard !didClose, displayMode == .fullScreen else { return }
        setCursorHidden(false)
        guard !Self.isTransientFocusLoss(policy) else { return }
        backgroundStreamWindow()
    }

    /// The display observers both presentation modes need: a screen change,
    /// a same-screen mode/HDR/VRR reconfiguration, and a display wake all
    /// rebind the FramePacer's CADisplayLink and re-assert the cursor hide.
    /// Split out of `installLifecycleObservers()` (a pure move, registered at
    /// the same point in the same order) so the windowed bring-up can install
    /// exactly these without the fullscreen-only key/activation observers.
    func installDisplayObservers(nc: NotificationCenter) {
        installPresentationVisibilityObserver(nc: nc)
        // Screen-change: the window was dragged to another display (or its
        // backing display's mode changed / woke from sleep). Notify the owner
        // so the FramePacer rebinds its CADisplayLink to the new screen's
        // cadence. AppKit's NSView.displayLink already follows the view across
        // screens in the common case, but a hard mode change / sleep-wake can
        // leave the old link silently stopped - rebinding is the safe fix.
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Stream window changed screen - rebinding pacer link")
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
        // transition on the SAME external panel - exactly the 4K240 HDR/VRR
        // "first HDR engagement" case that silently stopped the CADisplayLink
        // and hard-froze the stream. `NSApplication.didChangeScreenParameters`
        // DOES fire on those mode/HDR/VRR changes (the display's parameters
        // changed even though the window stayed on it), so route it to the same
        // pacer-rebind path. Object is nil - it's an app-wide notification.
        keyObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Screen parameters changed (mode/HDR/VRR) - rebinding pacer link")
                self.onScreenChanged?()
                // This is exactly the HDR/VRR-engage reconfig that makes
                // the WindowServer re-show the cursor mid-stream. Re-assert the
                // hide here so it's repaired before the next mouse move (no-op
                // unless we're the desired-hidden owner and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        // Wake can stop the link without changing the screen signature.
        // The workspace center carries the reliable wake signal, and close()
        // removes this observer from that same center.
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wsnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Displays woke - rebinding pacer link")
                self.onDisplaysWoke?()
                // Display sleep-wake re-shows the cursor behind the latch too;
                // re-assert the hide (no-op unless we're the desired-hidden owner
                // and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
    }

    /// App reactivation. Cmd-Tab BACK fires the didBecomeKey observer above,
    /// and the launcher "Back to stream" CTA calls reengageForeground()
    /// directly - but a THIRD return path was uncovered: clicking the DOCK
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
    /// (whose notification can land after this observer registers) - those
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
                // Foreground again with the stream window key - any pending
                // resign teardown is stale (same role as didBecomeKey's bump).
                self.resignGeneration &+= 1
                self.reengageForeground()
                self.log.info("App reactivated with stream window key - re-engaged foreground (cursor re-hidden)")
            }
        })
    }

    /// Release focus without removing a native fullscreen Space from the window manager.
    func backgroundStreamWindow() {
        setCursorHidden(false)
        guard !userBackgrounded else { return }
        if coversNotch { retreatCover() }
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
        }
        setBackgrounded(true)
        log.info("Stream window resigned key - cursor restored (stream continues in background)")
    }
}
