// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Cover motion stays in the compositor; completion restores the opaque resting state.

import AppKit
import QuartzCore

/// The moments the cover can move.
enum CoverSlideEvent { case firstFrame, away, back, close }

/// How a moment is shown: slid, faded (the first frame's existing fade), or at once.
enum CoverTransition: Equatable { case slide, fade, snap }

extension StreamWindow {

    static let coverSlideKey = "glimmer.coverSlide"

    /// Spaces keep AppKit's motion; the borderless cover uses a fade under Reduce Motion.
    nonisolated static func coverTransition(_ event: CoverSlideEvent, borderlessCover: Bool,
                                            reduceMotion: Bool) -> CoverTransition {
        if borderlessCover { return reduceMotion ? .fade : .slide }
        return event == .firstFrame ? .fade : .snap
    }

    /// An interrupted slide carries on from where the picture is now.
    nonisolated static func slideStart(entering: Bool, inFlight: CGFloat?, width: CGFloat) -> CGFloat {
        guard let inFlight, inFlight.isFinite else { return entering ? width : 0 }
        return min(max(inFlight, 0), width)
    }

    var isBorderlessCover: Bool { displayMode == .fullScreen && coversNotch }

    func coverTransition(_ event: CoverSlideEvent, reduceMotion: Bool? = nil) -> CoverTransition {
        Self.coverTransition(event, borderlessCover: isBorderlessCover,
                             reduceMotion: reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Slides the video layer, not the window: a transform runs in the render
    /// server with the picture still live, where a screen-sized setFrame would
    /// re-lay out the window every step. The model transform is never touched.
    func slideCover(entering: Bool, closing: Bool = false, completion: @escaping @MainActor () -> Void) {
        let layer = displayLayer
        let width = window.frame.width
        let inFlight = layer.animation(forKey: Self.coverSlideKey) == nil ? nil
            : (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)
                .map { CGFloat($0.doubleValue) }
        // Critical damping keeps the left edge covered throughout the slide.
        let spring = CASpringAnimation(perceptualDuration: Motion.structural, bounce: 0)
        spring.keyPath = "transform.translation.x"
        spring.fromValue = Self.slideStart(entering: entering, inFlight: inFlight, width: width)
        spring.toValue = entering ? 0 : width
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false

        coverSlideGeneration &+= 1
        presentationRevealInProgress = entering
        let generation = coverSlideGeneration
        // Clear only while sliding, so the desktop shows beside the picture.
        window.isOpaque = false
        window.backgroundColor = .clear
        let settle: @MainActor () -> Void = { [weak self] in
            guard let self, closing || !self.didClose, self.coverSlideGeneration == generation else { return }
            if entering { self.resetCoverSlide() }
            completion()
        }
        runSlideAnimation({ layer.add(spring, forKey: Self.coverSlideKey) }, settle)
        // An occluded layer can lose completion delivery. Never retain its transform and clear window on return.
        if entering { scheduleCoverSettlement(spring.duration + 0.1, settle) }
    }

    /// Back to rest: identity, opaque, clickable. Cancels any slide in flight.
    func resetCoverSlide() {
        presentationRevealInProgress = false
        coverSlideGeneration &+= 1
        displayLayer.removeAnimation(forKey: Self.coverSlideKey)
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = awaitingFirstFrameFadeIn
    }

    /// The switch away: slide out, then order out. Clicks pass through
    /// meanwhile so they reach the app the user switched to.
    func retreatCover(reduceMotion: Bool? = nil) {
        if coverTransition(.away, reduceMotion: reduceMotion) == .fade {
            fadeCover(entering: false) { [weak self] in self?.window.orderOut(nil) }
            return
        }
        guard coverTransition(.away, reduceMotion: reduceMotion) == .slide else {
            resetCoverSlide()
            window.orderOut(nil)
            return
        }
        window.ignoresMouseEvents = true
        slideCover(entering: false) { [weak self] in self?.window.orderOut(nil) }
    }

    /// The return: slide back in from wherever the picture is.
    func returnCover(reduceMotion: Bool? = nil) {
        let completion: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.applyPresentationOptions(coversNotch: self.coversNotch)
            self.refreshPresentationVisibility()
        }
        if coverTransition(.back, reduceMotion: reduceMotion) == .fade {
            fadeCover(entering: true, completion: completion)
            return
        }
        guard coverTransition(.back, reduceMotion: reduceMotion) == .slide else {
            resetCoverSlide()
            completion()
            return
        }
        window.ignoresMouseEvents = awaitingFirstFrameFadeIn
        slideCover(entering: true, completion: completion)
        if !awaitingFirstFrameFadeIn { window.alphaValue = 1 }
    }

    /// A stale completion must not hide a cover that has already returned.
    func fadeCover(entering: Bool, completion: @escaping @MainActor () -> Void) {
        resetCoverSlide()
        presentationRevealInProgress = entering
        let generation = coverSlideGeneration
        window.ignoresMouseEvents = !entering || awaitingFirstFrameFadeIn
        let settle: @MainActor () -> Void = { [weak self] in
            guard let self, !self.didClose, self.coverSlideGeneration == generation else { return }
            self.coverSlideGeneration &+= 1
            self.presentationRevealInProgress = false
            if entering { self.window.alphaValue = 1 }
            completion()
        }
        runFadeAnimation(window, entering ? 1 : 0, settle)
        if entering { scheduleCoverSettlement(Motion.short + 0.1, settle) }
    }

    static func runSlideAnimation(changes: @MainActor () -> Void, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        changes()
        CATransaction.commit()
    }

    static func runFadeAnimation(window: NSWindow, alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.short
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }
}
