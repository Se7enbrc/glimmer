// First-frame fade-in and close after the native Space has finished exiting.

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
        // didClose: the first frame can land inside the close fade.
        guard awaitingFirstFrameFadeIn, !didClose else { return }
        awaitingFirstFrameFadeIn = false
        if !userBackgrounded { takePointerOnFirstFrame() }
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
        if coverTransition(.firstFrame) == .slide, !userBackgrounded {
            slideCover(entering: true) { [weak self] in
                self?.applyPresentationOptions(coversNotch: cover)
                self?.refreshPresentationVisibility()
            }
            // Commit the offscreen start before the window turns visible, so
            // the picture never shows unslid for a frame.
            CATransaction.flush()
            win.alphaValue = 1.0
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 1.0
            applyPresentationOptions(coversNotch: cover)
            refreshPresentationVisibility()
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
            MainActor.assumeIsolated {
                self.applyPresentationOptions(coversNotch: cover)
                self.refreshPresentationVisibility()
            }
        })
    }

    /// The one place the streaming options are set. Only for a live, visible
    /// full-screen cover: a late fade-in completion or a backgrounded window
    /// must not hide the menu bar under the launcher. Window mode keeps both.
    func applyPresentationOptions(coversNotch cover: Bool) {
        guard displayMode == .fullScreen, !didClose, !userBackgrounded,
              NSApp.isActive, window.isKeyWindow, window.isVisible else { return }
        // AppKit negotiates Space options on entry; never replace them mid-transition.
        guard cover || window.styleMask.contains(.fullScreen) else { return }
        NSApp.presentationOptions = Self.streamingPresentationOptions(coversNotch: cover)
    }

    /// Both paths keep the system's gaming presentation active for Game Overlay.
    /// A native Space also retains AppKit's full-screen flag.
    nonisolated static func streamingPresentationOptions(coversNotch: Bool) -> NSApplication.PresentationOptions {
        var options: NSApplication.PresentationOptions = [.hideMenuBar, .hideDock]
        if !coversNotch { options.insert(.fullScreen) }
        options.insert(.disableCursorLocationAssistance)
        if #available(macOS 27, *) {
            // NSApplication.h in SDK 27 defines DisableScreenCornerInteractions as bit 15.
            // Use its public option value so SDK 26 builds retain the same behavior.
            let disableScreenCornerInteractions = NSApplication.PresentationOptions(rawValue: 1 << 15)
            options.insert(disableScreenCornerInteractions)
        }
        return options
    }

    /// Stop input immediately, but keep the Space and its last frame until AppKit finishes exiting.
    public func close() {
        guard !didClose else { return }
        didClose = true
        window.ignoresMouseEvents = true
        setCursorHidden(false)
        removeCloseObservers()
        if displayMode == .window {
            if streamDelegate.closeState.transition == .idle {
                finishWindowedFrameAutosave()
            } else {
                window.setFrameAutosaveName("")
            }
        }
        window.makeFirstResponder(nil)

        let fullScreen = window.styleMask.contains(.fullScreen)
        let transition = streamDelegate.closeState.transition
        if fullScreen || transition != .idle || (displayMode == .fullScreen && !coversNotch) {
            Diag.notice("Space close: fullScreen=\(fullScreen) transition=\(transition.rawValue) "
                + "waitForExit=\(fullScreen || transition != .idle)", "Stream.Window")
        }
        // The session can release us before the Space exits. finishClose breaks this retention.
        streamDelegate.onFullScreenSettled = { self.continueClose() }
        continueClose()
        // A transition AppKit ignored never settles; don't leave the stream window up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.streamDelegate.closeState.forceFade() else { return }
            Diag.notice("Space close: transition never settled - fading anyway", "Stream.Window")
            self.fadeOutForClose()
        }
    }

    private func removeCloseObservers() {
        for token in keyObservers { NotificationCenter.default.removeObserver(token) }
        keyObservers.removeAll()
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { wsnc.removeObserver(token) }
        workspaceObservers.removeAll()
        if let token = enterFullScreenObserver {
            NotificationCenter.default.removeObserver(token)
            enterFullScreenObserver = nil
        }
        // Stop #84 conversion; the delegate still tracks transitions throughout teardown.
        for token in spaceExitObservers { NotificationCenter.default.removeObserver(token) }
        spaceExitObservers.removeAll()
    }

    private func continueClose() {
        switch streamDelegate.closeState.nextAction(isFullScreen: window.styleMask.contains(.fullScreen)) {
        case .wait, .none:
            return
        case .exitSpace:
            // Fade first so the Space's exit animation carries no last frame; a close can
            // originate inside AppKit's did-enter delivery, hence the hop.
            DispatchQueue.main.async { self.fadeThenExitSpace() }
        case .fade:
            fadeOutForClose()
        }
    }

    private func fadeThenExitSpace() {
        let win = window
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            win.alphaValue = 0
            win.toggleFullScreen(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { win.toggleFullScreen(nil) }
        })
    }

    private func fadeOutForClose() {
        // Presentation belongs to AppKit during a Space transition. Restore it only after exit.
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
            previousPresentationOptions = nil
        }
        let win = window
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || win.alphaValue == 0 {
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
            MainActor.assumeIsolated { self.finishClose() }
        })
    }

    /// Neither the last frame nor the window may disappear while AppKit still owns its Space.
    private func finishClose() {
        window.orderOut(nil)
        window.close()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        streamDelegate.onFullScreenSettled = nil
        NSApp.activate()
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Glimmer" }) {
            main.makeKeyAndOrderFront(nil)
        }
    }
}
