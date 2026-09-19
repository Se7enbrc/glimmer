//
//  StreamWindow+MiniPlayer.swift
//
//  The mini player: the same stream window as a small panel that floats over
//  every app and Space, so the game stays in view while the Mac is used for
//  something else. It is a window-mode variant - the cursor follows capture,
//  the menu bar and Dock stay, the red button ends the stream - with two
//  differences: it floats, and it never grabs the pointer on hover. A click
//  takes the pointer, a held Esc or the pointer chord gives it back.
//
//  Entering from full screen retires the cover exactly as a Space exit does;
//  leaving restores whichever presentation the session had before, so the
//  full-screen user lands back in full screen and the window user in a window.
//

import AppKit

extension StreamWindow {

    /// Its own autosave name: the corner the user parks it in persists, and
    /// never collides with the windowed frame.
    static let miniPlayerFrameAutosaveName = "GlimmerMiniPlayer"

    /// The chord and the menu bar row both land here.
    public func toggleMiniPlayer() {
        if isMiniPlayer { leaveMiniPlayer() } else { enterMiniPlayer() }
    }

    func enterMiniPlayer() {
        guard !didClose, !isMiniPlayer else { return }
        miniPlayerReturnMode = displayMode
        switch displayMode {
        case .window:
            window.saveFrame(usingName: Self.frameAutosaveName)
            window.setFrameAutosaveName("")
            applyMiniPlayerChrome()
            onMiniPlayerChanged?(true)
        case .fullScreen where window.styleMask.contains(.fullScreen):
            // Path B: leave the Space first; the exit observers finish here.
            miniPlayerPending = true
            window.toggleFullScreen(nil)
        case .fullScreen:
            retireFullScreenCover()
            applyMiniPlayerChrome()
            installWindowedLifecycleObservers()
            onBackgroundedChanged?(false)
            onDidBecomeReadyForInput?()
            onMiniPlayerChanged?(true)
        }
    }

    func leaveMiniPlayer() {
        guard !didClose, isMiniPlayer else { return }
        window.saveFrame(usingName: Self.miniPlayerFrameAutosaveName)
        window.setFrameAutosaveName("")
        isMiniPlayer = false
        streamDelegate.isMiniPlayer = false
        miniPlayerHovering = false
        // The forwarder hears first so the hover grab is back before the
        // window is key again under the pointer.
        onMiniPlayerChanged?(false)
        restoreStandardChrome()
        switch miniPlayerReturnMode {
        case .window:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.collectionBehavior = [.fullScreenPrimary]
            window.level = .normal
            configureWindowedChrome()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            Diag.notice("Mini player off - the stream is back in its window", "Stream")
        case .fullScreen:
            // The cover installs its own observers; drop the windowed set.
            for token in keyObservers { NotificationCenter.default.removeObserver(token) }
            keyObservers.removeAll()
            let wsnc = NSWorkspace.shared.notificationCenter
            for token in workspaceObservers { wsnc.removeObserver(token) }
            workspaceObservers.removeAll()
            window.styleMask = [.borderless]
            window.collectionBehavior = [.fullScreenPrimary, .stationary]
            window.level = .normal
            displayMode = .fullScreen
            streamDelegate.displayMode = .fullScreen
            onDisplayModeChanged?(.fullScreen)
            presentFullScreen(firstShow: false)
            Diag.notice("Mini player off - the stream is back in full screen", "Stream")
        }
    }

    /// Dress the window as the floating panel: transparent title strip (the
    /// drag handle), a close button that shows on hover, floating level on
    /// every Space, a quarter-screen opening size in the bottom-right corner
    /// or the corner the user last parked it in.
    func applyMiniPlayerChrome() {
        isMiniPlayer = true
        streamDelegate.isMiniPlayer = true
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.title = windowTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let aspect = streamPixelSize.width > 0 && streamPixelSize.height > 0
            ? streamPixelSize : CGSize(width: 16, height: 9)
        window.contentAspectRatio = aspect
        window.contentMinSize = StreamWindowGeometry.miniPlayerMinimumContentSize(aspect: aspect)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        window.setContentSize(StreamWindowGeometry.miniPlayerContentSize(aspect: aspect, visible: visible.size))
        window.setFrameOrigin(StreamWindowGeometry.miniPlayerOrigin(frame: window.frame.size, visible: visible))
        if !window.setFrameAutosaveName(Self.miniPlayerFrameAutosaveName) {
            log.error("Mini player frame autosave name already in use - this session's placement won't persist")
        }
        let restored = window.contentRect(forFrameRect: window.frame).size
        let conformed = StreamWindowGeometry.conformed(restored, toAspect: aspect, within: visible.size)
        if conformed != restored { window.setContentSize(conformed) }
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        // A free pointer shows the arrow over the picture; a backgrounded
        // full-screen window comes back on screen here.
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(false)
        updateMiniPlayerControls()
        window.orderFront(nil)
        let size = window.contentRect(forFrameRect: window.frame).size
        log.info("Mini player on - content \(size.width, privacy: .public)×\(size.height, privacy: .public) pt")
        Diag.notice("Mini player on - click it to play, hold Esc to get the pointer back", "Stream")
    }

    /// Undo the panel styling so the regular window or the cover starts clean.
    private func restoreStandardChrome() {
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .automatic
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            button?.isHidden = false
            button?.alphaValue = 1
        }
    }

    /// The forwarder's hover edge over the mini player.
    func setMiniPlayerHovering(_ hovering: Bool) {
        guard isMiniPlayer, miniPlayerHovering != hovering else { return }
        miniPlayerHovering = hovering
        updateMiniPlayerControls()
    }

    /// The close button shows while the pointer rests on the panel and is
    /// free; a captured pointer has nothing to click it with.
    func updateMiniPlayerControls() {
        guard isMiniPlayer, let close = window.standardWindowButton(.closeButton) else { return }
        let visible = miniPlayerHovering && !didHideCursor
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            close.alphaValue = visible ? 1 : 0
        } else {
            close.animator().alphaValue = visible ? 1 : 0
        }
    }
}
