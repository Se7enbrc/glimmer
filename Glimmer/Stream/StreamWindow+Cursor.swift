//
//  StreamWindow+Cursor.swift
//
//  StreamWindow's cursor-visibility ownership and the single foreground
//  re-engage. The CGDisplay hide/show latch (single source of truth =
//  `didHideCursor`), the per-view transparent-cursor backstop, and the one
//  method both return-to-foreground paths funnel through. Split out of
//  StreamWindow.swift to keep each unit focused; see that file for the
//  window's stored state.
//

import AppKit
import CoreGraphics

extension StreamWindow {

    /// THE one and only entry point for hiding/showing the system cursor.
    ///
    /// We use `CGDisplayHideCursor`/`CGDisplayShowCursor` rather than
    /// `NSCursor.hide()`/`unhide()` deliberately: `NSCursor.hide()` only takes
    /// effect while the app is active AND the cursor is over one of the app's
    /// own windows, so a `becomeKey` that fires with the pointer momentarily
    /// off-content no-ops and leaves a stuck arrow on the stream. The
    /// CGDisplay pair is also a counted latch, but it does NOT require the
    /// cursor to be over our window, so the race disappears. This is the same
    /// recipe SDL uses for relative mouse mode on macOS (CGDisplayHideCursor
    /// while the cursor stays associated).
    ///
    /// Idempotent against `didHideCursor` (the single source of truth): hiding
    /// while already hidden, or showing while already shown, is a no-op. That
    /// guarantee caps the latch count at exactly 1, so the cursor can never be
    /// stranded invisible system-wide regardless of how many times key status
    /// flips. InputForwarder must never call this - visibility has exactly one
    /// owner.
    func setCursorHidden(_ hidden: Bool) {
        if hidden {
            guard !didHideCursor else { return }
            CGDisplayHideCursor(CGMainDisplayID())
            didHideCursor = true
        } else {
            guard didHideCursor else { return }
            CGDisplayShowCursor(CGMainDisplayID())
            didHideCursor = false
        }
    }

    /// Re-assert invisibility when the OS may have silently re-shown the cursor
    /// while we still believe it's hidden. The WindowServer re-shows the cursor
    /// on its own for system events that do NOT cycle the window's key status -
    /// display mode / HDR / VRR reconfiguration (a 4K240 HDR panel case), display
    /// sleep-wake, HID device attach - and `setCursorHidden(true)` is then a
    /// no-op because `didHideCursor` is still true, so the one-shot CGDisplay
    /// latch never re-hides.
    ///
    /// This re-applies the per-view TRANSPARENT cursor (an invisible image),
    /// NOT a CGDisplayShowCursor→HideCursor toggle. The old "net-neutral" pair
    /// claimed it ran in one runloop turn "before any compositor frame," but the
    /// WindowServer is a separate process compositing on its OWN vsync cadence -
    /// it samples cursor state in the gap between the two CG calls and composites
    /// a frame with the arrow visible. That was the flash. Setting an invisible
    /// IMAGE has no show/hide pair, so no frame can ever paint a visible arrow -
    /// it cannot flash by construction (the same idiom SDL/Qt use).
    ///
    /// Gated on `didHideCursor` so it only re-applies "while WE want it hidden":
    /// it never fights resign/teardown (which set `didHideCursor = false` first).
    /// The transparent cursor is self-balancing - AppKit restores the system
    /// cursor the instant the pointer leaves the view - so it can never strand
    /// the cursor invisible; the CGDisplay latch's balanced show on
    /// resign/teardown remains the authoritative system-wide restore.
    ///
    /// (`CGCursorIsVisible()` exists in the SDK but is
    /// `API_DEPRECATED("No longer supported")`, so a conditional re-hide gated on
    /// it would emit a deprecation warning and rely on a value Apple marks
    /// unreliable on the modern WindowServer - we avoid it entirely.)
    func reassertCursorHiddenIfNeeded() {
        guard didHideCursor else { return }   // only while WE want it hidden
        (window.contentView as? StreamInputView)?.refreshCursor()
    }

    /// THE single foreground re-engage. Re-hides the cursor, restores the
    /// streaming window level, and re-applies the fullscreen presentation
    /// flags - everything that must happen when the stream window comes back
    /// to the foreground from the backgrounded (resigned-key, ordered-out)
    /// state.
    ///
    /// Why this exists: there are TWO return paths and they MUST be identical.
    ///   (a) Cmd-Tab / app reactivation → AppKit fires `didBecomeKey`, whose
    ///       observer calls this.
    ///   (b) The launcher "Back to stream" / menubar CTA → `resumeWindow()`
    ///       calls `makeKeyAndOrderFront` and then this DIRECTLY. The menubar
    ///       path does not reliably re-fire `didBecomeKey` (the launcher window
    ///       is already key when the user clicks, and ordering the stream
    ///       window front from an already-active app can resolve key status
    ///       synchronously inside makeKeyAndOrderFront without posting a fresh
    ///       notification) - so the cursor-hide latch that path (a) re-engages
    ///       was being skipped, leaving the system cursor drawn over the stream
    ///       (the cursor-model-adjacent bug). Funnelling both paths through this one
    ///       method makes them indistinguishable.
    ///
    /// Single-owner safe: `setCursorHidden(true)` is idempotent off
    /// `didHideCursor`, so calling this when the cursor is already hidden
    /// (e.g. didBecomeKey fired AND resumeWindow called it) is a no-op for the
    /// latch - the count stays capped at 1. Genuine exit/resign/teardown still
    /// own the balanced show; this never fights them (it only ever hides).
    func reengageForeground() {
        guard !didClose else { return }
        // Cursor: re-hide. Idempotent + latch-balanced via the single owner -
        // hides iff currently shown, capping the count at 1.
        setCursorHidden(true)
        // Belt-and-braces: if the WindowServer had the system cursor drawn at
        // the moment we re-hid (it was visible while backgrounded), the per-view
        // transparent-cursor backstop guarantees no arrow can paint over the
        // stream on the next mouse move.
        reassertCursorHiddenIfNeeded()
        // Window level: re-elevate to the saved streaming level so we cover the
        // notch again. Only in the borderless-covering path - the Space-based
        // (`coversNotch == false`) window's level is owned by AppKit's
        // fullscreen system, so we leave it alone there (matching the
        // becomeKey observer's gate).
        if coversNotch, let level = streamingWindowLevel {
            window.level = level
        }
        // Re-apply the streaming presentation flags so the menu bar / Dock
        // auto-hide again while we're in fullscreen-cover mode. Mirrors the
        // gate in show() - coversNotch picks the strict `.hideMenuBar +
        // .hideDock` for notch coverage, otherwise the softer
        // `.autoHideMenuBar + .autoHideDock`.
        if coversNotch {
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        } else {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
        onBackgroundedChanged?(false)
    }
}
