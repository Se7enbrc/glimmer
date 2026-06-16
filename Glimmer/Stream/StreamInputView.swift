//
//  StreamInputView.swift
//
//  First-responder NSView that captures keyboard/mouse events for the stream
//  session. Forwards them through a delegate so the AppKit responder chain
//  and the C-bridge (InputForwarder) stay decoupled - InputForwarder's
//  `StreamInputViewDelegate` conformance lives in InputForwarder.swift.
//

import AppKit
import os.log

// MARK: - StreamInputViewDelegate

/// Callback surface the input view uses to ask the forwarder what to do with
/// each event. Kept on a private protocol so we can keep StreamInputView
/// confined to the view layer and InputForwarder to the C-bridge layer.
@MainActor
protocol StreamInputViewDelegate: AnyObject {
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent) -> Bool
    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent)
    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseDown event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent)
    func streamView(_ view: StreamInputView, handleScroll event: NSEvent)
}

// MARK: - StreamInputView

/// First-responder NSView that captures keyboard/mouse events for the stream
/// session. Forwards them through a delegate so we keep the input forwarder
/// (InputForwarder) decoupled from the AppKit responder chain.
final class StreamInputView: NSView {
    weak var delegate: (any StreamInputViewDelegate)?

    private var trackingArea: NSTrackingArea?

    /// A fully transparent 1×1 cursor. Set in `cursorUpdate(with:)` as a
    /// belt-and-braces invisibility layer: whenever the pointer is over the
    /// stream content AppKit asks the view for its cursor, and handing it an
    /// invisible cursor guarantees no arrow paints even if the CGDisplay hide
    /// latch slips (e.g. a becomeKey that raced the pointer off-content).
    /// This layer is inherently self-balancing - AppKit resets the cursor to
    /// the system default the instant the pointer leaves the view - so it can
    /// never strand the system cursor invisible the way a counted latch can.
    private static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    /// Critical for the stream window: macOS only delivers mouseMoved to a
    /// view if its window has `acceptsMouseMovedEvents = true` AND the view
    /// has an active tracking area. Without this, mouseMoved silently never
    /// fires even though the responder chain otherwise works.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        // `.cursorUpdate` is load-bearing: AppKit ONLY calls `cursorUpdate(with:)`
        // for tracking areas that include it. Without it the transparent-cursor
        // backstop below was dead code (never invoked), so a system arrow could
        // paint over the stream whenever the OS re-showed the cursor behind the
        // CGDisplay hide latch (display/HDR/VRR reconfig, sleep-wake, HID attach).
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// AppKit calls this whenever the pointer is over the view's tracking area
    /// and it's time to set the cursor. Returning an invisible cursor is a
    /// second, self-balancing invisibility layer underneath the authoritative
    /// CGDisplayHideCursor latch owned by StreamWindow: if that latch ever
    /// slips (e.g. a becomeKey fired while the pointer was momentarily off
    /// content), this still guarantees no arrow paints over the stream. Unlike
    /// the counted latch this is balanced for free - AppKit restores the
    /// system cursor the moment the pointer leaves the view - so it can never
    /// leave the system cursor invisible.
    override func cursorUpdate(with event: NSEvent) {
        Self.transparentCursor.set()
    }

    /// Re-apply the transparent cursor directly, without waiting for the next
    /// `cursorUpdate(with:)`. AppKit re-invokes `cursorUpdate` on every pointer
    /// motion, so motion already repairs an OS re-show for free - but a display
    /// reconfig (display/HDR/VRR change, sleep-wake, HID attach) with the pointer
    /// perfectly STATIONARY produces no motion event until the user moves, so the
    /// re-shown system arrow could momentarily sit on screen for that zero-motion
    /// window. The display observers in StreamWindow call this to close that gap.
    /// Setting an invisible IMAGE (never a CGDisplayShowCursor/HideCursor pair)
    /// means no frame can ever composite a visible arrow - it cannot flash by
    /// construction. Self-balancing like `cursorUpdate`: AppKit restores the
    /// system cursor the instant the pointer leaves the view, so it can never
    /// strand the cursor invisible.
    func refreshCursor() {
        Self.transparentCursor.set()
    }

    // MARK: NSResponder - keyboard

    override func keyDown(with event: NSEvent) {
        // Diagnostic: confirms the responder chain is delivering keyDown
        // to this view. If this never logs in a live run, the bug is upstream
        // (window not key, view not first responder, app not active) and the
        // fix is in StreamWindow.show() / InputForwarder.installFirstResponder().
        //
        // SECURITY: do NOT include the character value here - `chars=...` at
        // `.public` would leak every keystroke (passwords typed mid-stream
        // included) into the unified log, where any process with the right
        // entitlement can read it. Scan code + modifier mask are positional
        // and not PII; that's all we need to fingerprint event delivery.
        let modsHex = String(event.modifierFlags.rawValue, radix: 16)
        Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Input")
            .debug("StreamInputView.keyDown keyCode=\(event.keyCode, privacy: .public) mods=0x\(modsHex, privacy: .public)")
        // The delegate returns `true` when it consumed the event (forwarded
        // to the host, or handled it locally as the quit hotkey). It returns
        // `false` for Cmd-modified events when sys-key capture is off - in
        // that case we want macOS to deal with it, but most of those chords
        // have already been handled higher in the dispatch chain:
        //   * Cmd-Tab / Cmd-Space - WindowServer intercepts; we never see them.
        //   * Cmd-Q / Cmd-H / Cmd-M / Cmd-W - main menu's performKeyEquivalent
        //     fires before keyDown, so we only see these here if no menu
        //     item is bound.
        // For the remaining "unbound Cmd-chord" leftovers, calling `super.keyDown`
        // would walk up the responder chain to `noResponderFor:` and beep.
        // moonlight-qt also drops these silently - see keyboard.cpp's
        // `if (!isSystemKeyCaptureActive()) return;`. Match that: swallow
        // silently without forwarding and without beeping.
        _ = delegate?.streamView(self, handleKeyDown: event)
    }

    override func keyUp(with event: NSEvent) {
        delegate?.streamView(self, handleKeyUp: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let modsHex = String(event.modifierFlags.rawValue, radix: 16)
        Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Input")
            .info("StreamInputView.flagsChanged keyCode=\(event.keyCode, privacy: .public) mods=0x\(modsHex, privacy: .public)")
        delegate?.streamView(self, handleFlagsChanged: event)
    }

    // MARK: NSResponder - mouse

    override func mouseMoved(with event: NSEvent) { delegate?.streamView(self, handleMouseMoved: event) }
    override func mouseDragged(with event: NSEvent) { delegate?.streamView(self, handleMouseMoved: event) }
    override func rightMouseDragged(with event: NSEvent) { delegate?.streamView(self, handleMouseMoved: event) }
    override func otherMouseDragged(with event: NSEvent) { delegate?.streamView(self, handleMouseMoved: event) }

    override func mouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }
    override func rightMouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }
    override func otherMouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }

    override func mouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }
    override func rightMouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }
    override func otherMouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }

    override func scrollWheel(with event: NSEvent) { delegate?.streamView(self, handleScroll: event) }

    // NOTE: warpCursorIfNearEdge was DELETED with the P0 mouse-snap fix. Under
    // the SDL associate-false model (InputForwarder.enterCapturedMode) the OS
    // does not move the system cursor while relative aim is engaged, so the
    // cursor can never reach a screen edge / hot corner - there is nothing to
    // warp away from. The per-motion warp was the source of the edge→centre
    // reconciliation delta that snapped in-game aim to an edge/corner; removing
    // it (and switching to associate-false) eliminates the bug class entirely.
    // The one remaining warp is the cosmetic pre-position in StreamWindow.show()
    // (StreamCursor.warpToCentre), which runs BEFORE the delta pipeline / the
    // associate-false latch is live, so it cannot leak a delta.
}

// MARK: - Shared cursor-centering helper

/// One owner of the warp-to-centre coordinate convention. The ONLY remaining
/// call site is the cosmetic pre-position in `StreamWindow.show()` - it runs
/// once, before the relative-delta pipeline and the associate-false latch are
/// live, so it cannot inject a motion delta. (The per-motion edge warp it used
/// to share with was deleted by the P0 mouse-snap fix.)
///
/// `CGWarpMouseCursorPosition` takes GLOBAL TOP-LEFT (y-down) coordinates -
/// the Quartz/CoreGraphics display space whose origin is the top-left of the
/// primary display - NOT AppKit's bottom-left (y-up) space. Passing an AppKit
/// `frame.midY` straight through warps the cursor to the vertically mirrored
/// point. We flip Y against the primary display's height to convert.
enum StreamCursor {
    /// Warp the system cursor to the centre of `screen`, converting from
    /// AppKit's bottom-left frame to Quartz top-left coordinates.
    static func warpToCentre(of screen: NSScreen) {
        // Primary display height (the screen whose frame origin is (0,0)) is
        // the reference for the AppKit→Quartz Y flip. `NSScreen.screens.first`
        // is the primary by AppKit's contract. Compute the target's Quartz-top
        // edge from the SAME screen's own AppKit frame (its maxY relative to the
        // primary), not the screen's own height alone, so a non-primary / scaled
        // screen whose frame origin is not (0,0) still lands truly centred:
        //   quartzTop(screen) = primaryHeight - screen.frame.maxY
        //   quartzCentreY     = quartzTop + screen.frame.height / 2
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let quartzTop = primaryHeight - screen.frame.maxY
        let centre = CGPoint(
            x: screen.frame.midX,
            y: quartzTop + screen.frame.height / 2.0
        )
        CGWarpMouseCursorPosition(centre)
    }
}
