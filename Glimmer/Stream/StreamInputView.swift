// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamInputView.swift
//
//  First-responder NSView that captures keyboard/mouse events for the stream
//  session. Forwards them through a delegate so the AppKit responder chain
//  and the C-bridge (InputForwarder) stay decoupled - InputForwarder's
//  `StreamInputViewDelegate` conformance lives in InputForwarder.swift.
//

import AppKit

// MARK: - StreamInputViewDelegate

/// Callback surface the input view uses to ask the forwarder what to do with
/// each event. Kept on a private protocol so we can keep StreamInputView
/// confined to the view layer and InputForwarder to the C-bridge layer.
@MainActor
protocol StreamInputViewDelegate: AnyObject {
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent)
    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent)
    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseDown event: NSEvent)
    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent)
    func streamView(_ view: StreamInputView, handleScroll event: NSEvent)
    func streamViewPointerDidEnter(_ view: StreamInputView)
    func streamViewPointerDidExit(_ view: StreamInputView)
    func streamView(_ view: StreamInputView, handleKeyEquivalent event: NSEvent) -> Bool
    func streamViewPaste(_ view: StreamInputView)
}

// MARK: - StreamInputView

/// First-responder NSView that captures keyboard/mouse events for the stream
/// session. Forwards them through a delegate so we keep the input forwarder
/// (InputForwarder) decoupled from the AppKit responder chain.
final class StreamInputView: NSView {
    weak var delegate: (any StreamInputViewDelegate)?

    private var trackingArea: NSTrackingArea?

    /// The invisible image prevents a system reveal from drawing an arrow over
    /// captured input. Release and teardown must explicitly restore the arrow.
    private static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// The first frame or windowed capture opts in; connecting and released
    /// views leave the pointer visible, including during late tracking updates.
    private var transparentCursorEnabled = false

    /// Window mode's capture edge. Applies the matching cursor immediately
    /// rather than waiting for the next motion, so a chord release shows the
    /// arrow at once and a grab click hides it at once.
    func setTransparentCursorEnabled(_ enabled: Bool) {
        transparentCursorEnabled = enabled
        if enabled {
            Self.transparentCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Mini player: the click that activates the app also lands in the game.
    var acceptsActivatingClick = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsActivatingClick }

    private var motionBoundary: TimeInterval?
    private var needsMotionBaseline = false

    /// Queued motion predating capture or a warp must not consume the reset.
    /// The first later delta can span the transition, so establish a baseline.
    func resetMotion(after timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        motionBoundary = timestamp
        needsMotionBaseline = true
    }

    func resumeMotion() {
        motionBoundary = nil
        needsMotionBaseline = false
    }

    func acceptsMotion(_ event: NSEvent) -> Bool {
        if let motionBoundary, event.timestamp <= motionBoundary { return false }
        if needsMotionBaseline {
            needsMotionBaseline = false
            return false
        }
        return true
    }

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
        // Tracking outlives focus and live resizing. The forwarder gates input
        // on key ownership, and cursorUpdate follows explicit cursor ownership.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Tracking can continue through a close fade or after key focus changes.
    /// Released views select the arrow even when AppKit delivers a late update.
    override func cursorUpdate(with event: NSEvent) {
        guard transparentCursorEnabled else {
            NSCursor.arrow.set()
            return
        }
        Self.transparentCursor.set()
    }

    /// Display changes can reveal a stationary cursor without a tracking event.
    /// Refresh only while the window still owns the transparent image.
    func refreshCursor() {
        guard transparentCursorEnabled else { return }
        Self.transparentCursor.set()
    }

    // MARK: NSResponder - keyboard

    override func keyDown(with event: NSEvent) {
        // The delegate forwards the key, or drops a ⌘ chord left with the Mac
        // that no menu item took (super would only beep). moonlight instead
        // forwards such chords to the PC without the Win modifier.
        delegate?.streamView(self, handleKeyDown: event)
    }

    override func keyUp(with event: NSEvent) {
        delegate?.streamView(self, handleKeyUp: event)
    }

    override func flagsChanged(with event: NSEvent) {
        delegate?.streamView(self, handleFlagsChanged: event)
    }

    /// Key equivalents reach the view before the main menu, so while ⌘
    /// shortcuts belong to the game the forwarder claims them here (⌘Q, ⌘W
    /// and the rest go to the PC instead of Glimmer's menus).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, delegate?.streamView(self, handleKeyEquivalent: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Edit › Paste, and ⌘V while ⌘ stays with the Mac: the clipboard is typed
    /// into the PC as text (InputForwarder+Paste.swift).
    @objc func paste(_ sender: Any?) {
        delegate?.streamViewPaste(self)
    }

    // MARK: NSResponder - mouse

    override func mouseMoved(with event: NSEvent) { forwardMotion(event) }
    override func mouseDragged(with event: NSEvent) { forwardMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMotion(event) }

    private func forwardMotion(_ event: NSEvent) {
        guard acceptsMotion(event) else { return }
        delegate?.streamView(self, handleMouseMoved: event)
    }

    override func mouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }
    override func rightMouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }
    override func otherMouseDown(with event: NSEvent) { delegate?.streamView(self, handleMouseDown: event) }

    override func mouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }
    override func rightMouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }
    override func otherMouseUp(with event: NSEvent) { delegate?.streamView(self, handleMouseUp: event) }

    override func scrollWheel(with event: NSEvent) { delegate?.streamView(self, handleScroll: event) }

    // Window mode's grab edge. Nothing is decided here - the view reports the
    // crossing and the forwarder's pure rule decides, so full screen (which
    // ignores both) pays one delegate hop and nothing else. No event is
    // consumed: AppKit does not route enter/exit anywhere else.
    override func mouseEntered(with event: NSEvent) { delegate?.streamViewPointerDidEnter(self) }
    override func mouseExited(with event: NSEvent) { delegate?.streamViewPointerDidExit(self) }
}

// MARK: - Shared cursor-centering helper

/// One owner of the cursor's screen geometry. The warp's only caller is
/// `StreamWindow.warpCursorToCentre`, which also has the view drop the motion
/// event that carries the jump.
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

    /// Is an AppKit mouse location on this screen? Pointer rows run from
    /// minY + 1 to maxY (the top row is maxY), so the frame's own half-open
    /// `contains` would call the top row off screen and the bottom edge on.
    static func isOnScreen(_ point: CGPoint, frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }
}
