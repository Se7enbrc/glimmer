// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// First-frame fade-in and close after the native Space has finished exiting.

import AppKit
import AVFoundation
import QuartzCore

extension StreamWindow {

    /// First-picture gating prevents an empty black window during connection.
    /// Later decoder flushes never replay the entrance.
    public func fadeInOnFirstFrame() {
        // didClose: the first frame can land inside the close fade.
        guard awaitingFirstFrameFadeIn, !didClose else { return }
        if !isBorderlessCover, streamDelegate.closeState.transition != .idle {
            guard !pendingFirstFrameReveal else { return }
            pendingFirstFrameReveal = true
            // AppKit can drop settlement delivery; never strand a decoded picture behind alpha zero.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.pendingFirstFrameReveal else { return }
                self.revealFirstFrame()
            }
            return
        }
        revealFirstFrame()
    }

    private func revealFirstFrame() {
        guard awaitingFirstFrameFadeIn, !didClose else { return }
        pendingFirstFrameReveal = false
        awaitingFirstFrameFadeIn = false
        if !userBackgrounded { takePointerOnFirstFrame() }
        // Hide the bars only after the picture covers them, avoiding a bare-desktop flash.
        let win = window
        let cover = coversNotch
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
        presentationRevealInProgress = true
        let generation = coverSlideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.short
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated {
                guard !self.didClose, self.coverSlideGeneration == generation else { return }
                self.presentationRevealInProgress = false
                self.applyPresentationOptions(coversNotch: cover)
                self.refreshPresentationVisibility()
            }
        })
    }

    /// The one place the streaming options are set. Only for a live, visible
    /// full-screen cover: a late fade-in completion or a backgrounded window
    /// must not hide the menu bar under the launcher. Window mode keeps both.
    func applyPresentationOptions(coversNotch cover: Bool) {
        guard displayMode == .fullScreen, !didClose, !userBackgrounded, !presentationRevealInProgress,
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
        statsOverlayWindow.close()
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.short
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { win.toggleFullScreen(nil) }
        })
    }

    /// Backgrounding starts the retreat; only actual invisibility makes its close immediate.
    nonisolated static func closeTransition(cover: CoverTransition, visible: Bool, alpha: CGFloat) -> CoverTransition {
        guard visible, alpha > 0 else { return .snap }
        return cover == .slide ? .slide : .fade
    }

    private func fadeOutForClose() {
        // Presentation belongs to AppKit during a Space transition. Restore it only after exit.
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
            previousPresentationOptions = nil
        }
        let win = window
        // The borderless cover leaves the way it came in, unless it is already off screen.
        switch Self.closeTransition(cover: coverTransition(.close), visible: win.isVisible, alpha: win.alphaValue) {
        case .slide:
            slideCover(entering: false, closing: true) { [weak self] in self?.finishClose() }
            return
        case .snap:
            win.alphaValue = 0.0
            finishClose()
            return
        case .fade:
            break
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.short
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated { self.finishClose() }
        })
    }

    /// The launcher receipt starts its hold after the stream has actually left the screen.
    func waitForVisualClose() async {
        guard didClose, !visualCloseFinished else { return }
        await withCheckedContinuation { visualCloseWaiters.append($0) }
    }

    func completeVisualClose() {
        visualCloseFinished = true
        let waiters = visualCloseWaiters
        visualCloseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
        completeVisualClose()
    }
}
