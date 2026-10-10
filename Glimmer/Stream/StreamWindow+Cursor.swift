// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamWindow+Cursor.swift
//
//  Owns the counted display hide and transparent cursor image together,
//  and re-engages foreground presentation through one shared path.
//

import AppKit
import CoreGraphics

extension StreamWindow {

    /// Every hide is counted because system menu tracking can reveal the cursor.
    /// Release disables the transparent image before balancing all display hides;
    /// otherwise a late tracking callback can leave an invisible image selected.
    func setCursorHidden(_ hidden: Bool) {
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(hidden)
        if hidden {
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHideCount += 1
        } else {
            while cursorHideCount > 0 {
                CGDisplayShowCursor(CGMainDisplayID())
                cursorHideCount -= 1
            }
        }
    }

    /// Repair system cursor reveals without a show/hide gap the compositor can
    /// paint. Release disables the view's transparent image and clears this gate.
    func reassertCursorHiddenIfNeeded() {
        guard didHideCursor else { return }
        (window.contentView as? StreamInputView)?.refreshCursor()
    }

    /// App reactivation and the launcher's return action share the same cursor,
    /// window-level and presentation restoration; a key notification may be absent.
    func reengageForeground() {
        guard !didClose else { return }
        let wasAway = userBackgrounded
        userBackgrounded = false
        // Window mode: the cursor follows pointer capture, and the level and
        // presentation options are AppKit's. Only the backgrounded signal applies.
        if displayMode == .window {
            setBackgrounded(false)
            return
        }
        // Path A re-raises to its covering level; Path B's level is AppKit's.
        if coversNotch, let level = streamingWindowLevel {
            window.level = level
        }
        if wasAway, coversNotch { returnCover() }
        // Before the first frame the cursor and the menu bar stay the user's;
        // the fade-in takes them. The re-hide is latch-safe and the transparent
        // cursor backstops an arrow the WindowServer drew while we were away.
        if !awaitingFirstFrameFadeIn {
            setCursorHidden(true)
            reassertCursorHiddenIfNeeded()
            applyPresentationOptions(coversNotch: coversNotch)
        }
        setBackgrounded(false)
    }

    /// A late first frame cannot take focus back from the launcher or another app.
    func takePointerOnFirstFrame() {
        if displayMode == .fullScreen {
            guard NSApp.isActive, window.isKeyWindow else { return }
            if let screen = window.screen { warpCursorToCentre(of: screen) }
            setCursorHidden(true)
        }
        onDidBecomeReadyForInput?()
    }

    /// Park the cursor mid-screen and retire motion spanning the warp.
    func warpCursorToCentre(of screen: NSScreen) {
        StreamCursor.warpToCentre(of: screen)
        (window.contentView as? StreamInputView)?.resetMotion()
    }
}
