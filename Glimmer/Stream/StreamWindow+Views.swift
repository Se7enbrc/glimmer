// AppKit support types for the stream window and its display layer.

import AppKit
import Carbon.HIToolbox

/// Borderless windows need explicit key eligibility to receive stream input.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private var gameOverlayMonitor: Any?
    var fullScreenExitSource = "unobserved"

    /// The system gets first refusal; consume its fallback before AppKit's main menu.
    override func becomeKey() {
        super.becomeKey()
        guard gameOverlayMonitor == nil else { return }
        gameOverlayMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.blocksGameOverlayEvent(event) else { return event }
            return nil
        }
    }

    override func resignKey() {
        removeGameOverlayMonitor()
        super.resignKey()
    }

    override func close() {
        removeGameOverlayMonitor()
        super.close()
    }

    private func removeGameOverlayMonitor() {
        if let monitor = gameOverlayMonitor {
            NSEvent.removeMonitor(monitor)
            gameOverlayMonitor = nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if blocksGameOverlayEvent(event) { return true }
        // Other Escape chords (Control-Escape is the PC's Start menu) belong to the stream.
        if isSpaceEscape(event), let view = firstResponder as? StreamInputView {
            view.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// AppKit can turn Escape into an action before the input view sees keyDown.
    /// Keep that fallback from exiting the Space; explicit full-screen commands still work.
    override func cancelOperation(_ sender: Any?) {
        if isSpaceEscape(NSApp.currentEvent) { return }
        super.cancelOperation(sender)
    }

    /// Menu actions can bypass both the window's key equivalents and cancelOperation.
    override func toggleFullScreen(_ sender: Any?) {
        if isSpaceEscape(NSApp.currentEvent) { return }
        if styleMask.contains(.fullScreen) {
            let senderType = sender.map { String(describing: type(of: $0)) } ?? "nil"
            let action = (sender as? NSMenuItem)?.action.map(NSStringFromSelector) ?? "none"
            fullScreenExitSource = "toggleFullScreen: sender=\(senderType) menuAction=\(action)"
        }
        super.toggleFullScreen(sender)
    }

    private func blocksGameOverlayEvent(_ event: NSEvent?) -> Bool {
        guard let event, !ignoresMouseEvents, event.type == .keyDown else { return false }
        return Self.isGameOverlayFallback(isFullScreen: styleMask.contains(.fullScreen), isKeyWindow: isKeyWindow,
                                          keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// No Escape chord leaves the Space; Control-Command-F, the green button and Mission Control still do.
    private func isSpaceEscape(_ event: NSEvent?) -> Bool {
        guard let event, !ignoresMouseEvents, event.type == .keyDown else { return false }
        return Self.isSpaceEscape(isFullScreen: styleMask.contains(.fullScreen), isKeyWindow: isKeyWindow,
                                  keyCode: event.keyCode)
    }

    nonisolated static func isSpaceEscape(isFullScreen: Bool, isKeyWindow: Bool, keyCode: UInt16) -> Bool {
        isFullScreen && isKeyWindow && keyCode == UInt16(kVK_Escape)
    }

    nonisolated static func isGameOverlayFallback(isFullScreen: Bool, isKeyWindow: Bool, keyCode: UInt16,
                                                  modifiers: NSEvent.ModifierFlags) -> Bool {
        isFullScreen && isKeyWindow && keyCode == UInt16(kVK_Escape)
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }
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

    /// Mirrors `StreamWindow.displayMode` so the close hook below only ever
    /// acts for a real window (the borderless cover has no close button, so
    /// `performClose:` never consults this in full screen anyway).
    var displayMode: StreamDisplayMode = .fullScreen

    /// Window mode: the user asked to close (red button / Cmd-W). The owner
    /// routes it to the session's stop(); the window is NOT closed here.
    var onCloseRequested: (() -> Void)?

    /// Mirrors `StreamWindow.isMiniPlayer`; a zoom (the title strip's
    /// double-click) leaves the mini player instead of resizing it.
    var isMiniPlayer = false
    var onMiniPlayerExitRequested: (() -> Void)?

    var closeState = StreamWindowCloseState()
    var onFullScreenSettled: (() -> Void)?

    func windowWillEnterFullScreen(_ notification: Notification) {
        closeState.transition = .entering
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        closeState.transition = .exiting
    }

    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenSettled() }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenSettled() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenSettled() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenSettled() }

    private func fullScreenSettled() {
        closeState.transition = .idle
        // Let AppKit finish delivering the transition before requesting another one.
        DispatchQueue.main.async { [weak self] in self?.onFullScreenSettled?() }
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard isMiniPlayer else { return true }
        onMiniPlayerExitRequested?()
        return false
    }

    /// Refuse the close and hand it to the session instead: letting AppKit
    /// close the window would orderOut a still-live stream (headless session,
    /// no /cancel - the same orphan issue #84 describes) and skip the fade-out
    /// teardown `StreamWindow.close()` owns. Window mode only; a fullscreen
    /// window never reaches here but stays refused for safety.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard displayMode == .window else { return false }
        onCloseRequested?()
        return false
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        guard displayMode == .fullScreen else { return proposedOptions }
        // Auto-hide toolbar needs auto-hide menu bar, so remove both when hiding the menu bar.
        return proposedOptions.subtracting([.autoHideMenuBar, .autoHideDock, .autoHideToolbar])
            .union(StreamWindow.streamingPresentationOptions(coversNotch: false))
    }

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
