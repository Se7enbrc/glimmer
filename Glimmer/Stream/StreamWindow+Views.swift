//
//  StreamWindow+Views.swift
//
//  The AppKit support types backing StreamWindow: the key-eligible borderless
//  NSWindow, the fullscreen-content-size delegate that covers the notch reserve
//  zone, and the AVSampleBufferDisplayLayer-hosting container view. Split out of
//  StreamWindow.swift to keep each unit focused; see that file for the window's
//  stored state and lifecycle.
//

import AppKit

/// Borderless NSWindow that can become key + main so the responder chain
/// delivers keyDown / flagsChanged / mouseMoved to our content view. Without
/// these overrides, AppKit treats borderless windows as decorative panels and
/// silently drops all key events.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Window delegate that hands AppKit a custom "fullscreen content size"
/// so our Space-based fullscreen window can cover the entire physical
/// panel including the notch reserve zone on 14"/16" MacBook Pros and
/// 13"/15" MacBook Airs with notches.
///
/// AppKit's default for `toggleFullScreen:` sizes the fullscreen content
/// to `screen.frame.size`, which on notched Macs is the safe-area-trimmed
/// rectangle (typically `screen.frame.height = panelHeight - notchHeight`).
/// A host bitstream at the panel's TRUE native resolution then renders
/// into a too-short layer and `resizeAspect` letterboxes it left/right.
/// Returning `screen.frame.size + safeAreaInsets.top` here makes AppKit
/// resize the fullscreen content to cover the notch zone too - same
/// behaviour SDL's FULLSCREEN_DESKTOP gives moonlight-qt for free.
///
/// `coversNotch == false` returns the default safe-area size, matching
/// moonlight-qt's "Optimize game settings for the notch" off variant.
@MainActor
final class StreamWindowDelegate: NSObject, NSWindowDelegate {
    var coversNotch: Bool = true

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        guard coversNotch, let screen = window.screen ?? NSScreen.main else { return proposedSize }
        // `screen.safeAreaInsets.top` is the notch height in points on
        // notched panels (typically 37pt = 74px @ 2x). Add it back to
        // proposed height to cover the notch zone.
        let extraPoints = screen.safeAreaInsets.top
        guard extraPoints > 0 else { return proposedSize }
        return NSSize(width: proposedSize.width, height: proposedSize.height + extraPoints)
    }
}

/// View that hosts the AVSampleBufferDisplayLayer.
///
/// InputForwarder later wraps this view inside a custom StreamInputView (as a
/// subview) and makes that view the window's first responder. This view must
/// therefore *not* accept first responder, or AppKit will route key/mouse
/// events here instead of to StreamInputView and the input pipeline goes
/// silent.
///
/// Layout-wise, the display layer is the view's root layer; AppKit keeps the
/// layer's frame in sync with the view bounds automatically as the window
/// resizes, so we don't need a custom `layout` override.
final class DisplayContainerView: NSView {
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}
