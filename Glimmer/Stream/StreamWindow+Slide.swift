//
//  StreamWindow+Slide.swift
//
//  The borderless cover's horizontal slide, its stand-in for the swipe AppKit
//  gives a full-screen Space: in from the right on the first frame and on
//  return, out to the right before a switch away orders the cover out.
//

import AppKit
import QuartzCore

/// The moments the cover can move.
enum CoverSlideEvent { case firstFrame, away, back }

/// How a moment is shown: slid, faded (the first frame's existing fade), or at once.
enum CoverTransition: Equatable { case slide, fade, snap }

extension StreamWindow {

    static let coverSlideKey = "glimmer.coverSlide"

    /// Only the borderless cover slides: a Space's swipe is AppKit's, and
    /// Reduce Motion keeps the existing fade or snap.
    nonisolated static func coverTransition(_ event: CoverSlideEvent, borderlessCover: Bool,
                                            reduceMotion: Bool) -> CoverTransition {
        if borderlessCover, !reduceMotion { return .slide }
        return event == .firstFrame ? .fade : .snap
    }

    /// An interrupted slide carries on from where the picture is now.
    nonisolated static func slideStart(entering: Bool, inFlight: CGFloat?, width: CGFloat) -> CGFloat {
        guard let inFlight, inFlight.isFinite else { return entering ? width : 0 }
        return min(max(inFlight, 0), width)
    }

    var isBorderlessCover: Bool { displayMode == .fullScreen && coversNotch }

    func coverTransition(_ event: CoverSlideEvent) -> CoverTransition {
        Self.coverTransition(event, borderlessCover: isBorderlessCover,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Slides the video layer, not the window: a transform runs in the render
    /// server with the picture still live, where a screen-sized setFrame would
    /// re-lay out the window every step. The model transform is never touched.
    func slideCover(entering: Bool, completion: @escaping @MainActor () -> Void) {
        let layer = displayLayer
        let width = window.frame.width
        let inFlight = layer.animation(forKey: Self.coverSlideKey) == nil ? nil
            : (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)
                .map { CGFloat($0.doubleValue) }
        // Space switching's feel: critically damped (an overshoot would bare the
        // left edge), the same response as SwiftUI's .smooth at 0.4 s.
        let spring = CASpringAnimation(perceptualDuration: 0.4, bounce: 0)
        spring.keyPath = "transform.translation.x"
        spring.fromValue = Self.slideStart(entering: entering, inFlight: inFlight, width: width)
        spring.toValue = entering ? 0 : width
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false

        coverSlideGeneration &+= 1
        let generation = coverSlideGeneration
        // Clear only while sliding, so the desktop shows beside the picture.
        window.isOpaque = false
        window.backgroundColor = .clear
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, self.coverSlideGeneration == generation else { return }
                if entering { self.resetCoverSlide() }
                completion()
            }
        }
        layer.add(spring, forKey: Self.coverSlideKey)
        CATransaction.commit()
    }

    /// Back to rest: identity, opaque, clickable. Cancels any slide in flight.
    func resetCoverSlide() {
        coverSlideGeneration &+= 1
        displayLayer.removeAnimation(forKey: Self.coverSlideKey)
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = awaitingFirstFrameFadeIn
    }

    /// The switch away: slide out, then order out. Clicks pass through
    /// meanwhile so they reach the app the user switched to.
    func retreatCover() {
        guard coverTransition(.away) == .slide else {
            resetCoverSlide()
            window.orderOut(nil)
            return
        }
        window.ignoresMouseEvents = true
        slideCover(entering: false) { [weak self] in self?.window.orderOut(nil) }
    }

    /// The return: slide back in from wherever the picture is.
    func returnCover() {
        guard coverTransition(.back) == .slide else { resetCoverSlide(); return }
        window.ignoresMouseEvents = awaitingFirstFrameFadeIn
        slideCover(entering: true) {}
    }
}
