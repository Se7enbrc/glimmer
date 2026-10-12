// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Interrupted cover motion must return to identity and ignore superseded completions.

import AppKit
import QuartzCore
import Testing
import SwiftUI
@testable import Glimmer

@MainActor
struct StreamWindowSlideTests {

    @Test func steadyPresentationHasNoCompositionEffectsAfterTransitions() async throws {
        let stream = StreamWindow()
        defer { stream.resetCoverSlide() }
        stream.statsOverlay.setVisible(true)
        stream.leaveHintBanner.announce = { _ in }
        stream.leaveHintBanner.setText("Stream started")
        stream.leaveHintBanner.setVisible(true)
        stream.slideCover(entering: true) {}
        CATransaction.flush()
        try await Task.sleep(for: .seconds(1))
        stream.leaveHintBanner.setText("Pointer captured")
        stream.statsOverlay.setVisible(false)
        stream.leaveHintBanner.setVisible(false)
        CATransaction.flush()
        try await Task.sleep(for: .seconds(1))
        let layer = stream.displayLayer
        #expect(stream.displayView.layer === layer)
        #expect(stream.window.isOpaque)
        #expect(stream.window.alphaValue == 1)
        #expect(layer.isOpaque)
        #expect(layer.opacity == 1)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animationKeys()?.isEmpty ?? true)
        #expect(layer.mask == nil)
        #expect(!layer.masksToBounds)
        #expect(layer.cornerRadius == 0)
        #expect(layer.shadowOpacity == 0)
        #expect(layer.filters?.isEmpty ?? true)
        #expect(layer.backgroundFilters?.isEmpty ?? true)
        #expect(layer.compositingFilter == nil)
        #expect(!layer.shouldRasterize)
        let overlays = [stream.statsOverlay.layer, stream.reconnectBanner.layer, stream.networkBanner.layer,
                        stream.leaveHintBanner.layer, stream.captureHintBanner.layer]
        for (index, overlay) in overlays.enumerated() {
            #expect(overlay.isHidden, "Overlay \(index), opacity \(overlay.opacity)")
            expectNoAnimations(in: overlay)
        }
    }

    private func expectNoAnimations(in layer: CALayer) {
        #expect(layer.animationKeys()?.isEmpty ?? true, "\(type(of: layer)): \(layer.animationKeys() ?? [])")
        for child in layer.sublayers ?? [] { expectNoAnimations(in: child) }
    }

    @Test(arguments: [CoverSlideEvent.firstFrame, .away, .back, .close])
    func onlyTheBorderlessCoverSlides(event: CoverSlideEvent) {
        let still: CoverTransition = event == .firstFrame ? .fade : .snap
        #expect(StreamWindow.coverTransition(event, borderlessCover: true, reduceMotion: false) == .slide)
        #expect(StreamWindow.coverTransition(event, borderlessCover: true, reduceMotion: true) == .fade)
        #expect(StreamWindow.coverTransition(event, borderlessCover: false, reduceMotion: false) == still)
        #expect(StreamWindow.coverTransition(event, borderlessCover: false, reduceMotion: true) == still)
    }

    @Test func anInterruptedSlideCarriesOnFromThePicture() {
        #expect(StreamWindow.slideStart(entering: true, inFlight: nil, width: 1512) == 1512)
        #expect(StreamWindow.slideStart(entering: false, inFlight: nil, width: 1512) == 0)
        #expect(StreamWindow.slideStart(entering: true, inFlight: 600, width: 1512) == 600)
        #expect(StreamWindow.slideStart(entering: false, inFlight: 600, width: 1512) == 600)
        #expect(StreamWindow.slideStart(entering: true, inFlight: -3, width: 1512) == 0)
        #expect(StreamWindow.slideStart(entering: true, inFlight: 2000, width: 1512) == 1512)
        #expect(StreamWindow.slideStart(entering: true, inFlight: .nan, width: 1512) == 1512)
    }

    @Test func rapidSwitchingNeverMovesTheModelAndRestsAtIdentity() {
        let stream = StreamWindow()
        let layer = stream.displayLayer
        stream.slideCover(entering: false) {}
        stream.slideCover(entering: true) {}
        stream.slideCover(entering: false) {}
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: StreamWindow.coverSlideKey) != nil)
        #expect(!stream.window.isOpaque)

        stream.resetCoverSlide()

        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: StreamWindow.coverSlideKey) == nil)
        #expect(stream.window.isOpaque)
        #expect(!stream.window.ignoresMouseEvents)
    }

    @Test func leavingFullScreenDropsAHalfFinishedSlide() {
        let stream = StreamWindow()
        stream.retreatCover()
        stream.retireFullScreenCover()
        #expect(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) == nil)
        #expect(stream.window.isOpaque)
        #expect(!stream.window.ignoresMouseEvents)
    }

    @Test func aReturnKeepsPresentationDeferredUntilThePictureSettles() {
        let stream = StreamWindow()
        stream.slideCover(entering: true) {}
        #expect(stream.presentationRevealInProgress)
        stream.awaitingFirstFrameFadeIn = true
        stream.reengageForeground()
        #expect(stream.presentationRevealInProgress)
        stream.resetCoverSlide()
        #expect(!stream.presentationRevealInProgress)
        stream.slideCover(entering: false) {}
        #expect(!stream.presentationRevealInProgress)
        stream.resetCoverSlide()
    }

    @Test func closingARetreatKeepsItsSlideUntilTheWindowIsActuallyHidden() {
        #expect(StreamWindow.closeTransition(cover: .slide, visible: true, alpha: 1) == .slide)
        #expect(StreamWindow.closeTransition(cover: .slide, visible: false, alpha: 1) == .snap)
        #expect(StreamWindow.closeTransition(cover: .slide, visible: true, alpha: 0) == .snap)
        #expect(StreamWindow.closeTransition(cover: .fade, visible: true, alpha: 0.5) == .fade)
        #expect(StreamWindow.closeTransition(cover: .snap, visible: true, alpha: 1) == .fade)
    }

    @Test func motionPolicyUsesShortFadesAndImmediateAccessibleGeometry() {
        #expect(Motion.short == 0.18)
        #expect(Motion.structural == 0.3)
        #expect(Motion.layout(reduceMotion: true) == nil)
        #expect(Motion.press(reduceMotion: true) == nil)
        #expect(Motion.overlay(reduceMotion: true) == Motion.fade)
        #expect(Motion.layout(reduceMotion: false) == .smooth(duration: Motion.structural))
        #expect(Motion.pressedScale(true, reduceMotion: true) == 1)
        #expect(Motion.pressedScale(false, reduceMotion: false) == 1)
        #expect(Motion.pressedScale(true, reduceMotion: false) == 0.985)
    }

    @Test func slidesUseTheSharedStructuralResponseWithoutOvershoot() throws {
        let stream = StreamWindow()
        stream.slideCover(entering: false) {}
        let animation = try #require(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey)
            as? CASpringAnimation)
        let expected = CASpringAnimation(perceptualDuration: Motion.structural, bounce: 0)
        #expect(animation.stiffness == expected.stiffness)
        #expect(animation.damping == expected.damping)
        #expect(animation.duration == expected.settlingDuration)
        stream.resetCoverSlide()
    }

    @MainActor private final class AnimationDriver {
        var completions: [@MainActor () -> Void] = []

        func install(on stream: StreamWindow) {
            stream.runSlideAnimation = { changes, completion in
                changes()
                self.completions.append(completion)
            }
            stream.runFadeAnimation = { window, alpha, completion in
                window.alphaValue = alpha
                self.completions.append(completion)
            }
        }

        func finish() {
            let pending = completions
            completions.removeAll()
            for completion in pending { completion() }
        }
    }

    @Test func completedEntryClearsTheRevealAndInvalidatedFadeCannotComplete() {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        defer { stream.resetCoverSlide() }
        var completed = false
        stream.slideCover(entering: true) { completed = true }
        #expect(!completed)
        #expect(stream.presentationRevealInProgress)
        animations.finish()
        #expect(completed)
        #expect(!stream.presentationRevealInProgress)
        #expect(stream.window.isOpaque)
        #expect(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) == nil)
        var stale = false
        stream.fadeCover(entering: false) { stale = true }
        #expect(stream.window.ignoresMouseEvents)
        stream.awaitingFirstFrameFadeIn = true
        stream.resetCoverSlide()
        #expect(stream.window.ignoresMouseEvents)
        animations.finish()
        #expect(!stale)
    }

    @Test func completedFadeClearsRevealAndRestoresEntryAlpha() {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        defer { stream.resetCoverSlide() }
        var completed = false
        stream.window.alphaValue = 0
        stream.fadeCover(entering: true) { completed = true }
        #expect(!completed)
        #expect(stream.presentationRevealInProgress)
        animations.finish()
        #expect(completed)
        #expect(!stream.presentationRevealInProgress)
        #expect(!stream.window.ignoresMouseEvents)
        #expect(stream.window.alphaValue == 1)
    }

    @Test(arguments: [false, true])
    func returnAndRetreatRespectMotionAndLeaveNativeSpacesAtRest(reduceMotion: Bool) {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        defer { stream.resetCoverSlide() }
        stream.window.alphaValue = 0
        stream.returnCover(reduceMotion: reduceMotion)
        #expect(!stream.window.ignoresMouseEvents)
        #expect((stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) == nil) == reduceMotion)
        #expect(stream.presentationRevealInProgress)
        animations.finish()
        #expect(stream.window.alphaValue == 1)
        #expect(!stream.presentationRevealInProgress)
        #expect(stream.window.isOpaque)
        #expect(stream.presentationSuppressed)
        stream.retreatCover(reduceMotion: reduceMotion)
        #expect(stream.window.ignoresMouseEvents)
        animations.finish()
        #expect(!stream.window.isVisible)
        #expect(stream.window.alphaValue == (reduceMotion ? 0 : 1))
        stream.coversNotch = false
        stream.returnCover(reduceMotion: reduceMotion)
        #expect(animations.completions.isEmpty)
        #expect(stream.window.isOpaque)
        #expect(!stream.presentationRevealInProgress)
        #expect(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) == nil)
        stream.retreatCover(reduceMotion: reduceMotion)
        #expect(!stream.window.isVisible)
        #expect(!stream.window.ignoresMouseEvents)
    }

    @Test func visualCloseWaitsForTheWindowAndSupportsLateWaiters() async {
        let stream = StreamWindow()
        stream.didClose = true
        let waiter = Task { await stream.waitForVisualClose() }
        await Task.yield()
        #expect(!stream.visualCloseFinished)
        stream.completeVisualClose()
        await waiter.value
        #expect(stream.visualCloseWaiters.isEmpty)
        await stream.waitForVisualClose()
        stream.completeVisualClose()
        #expect(stream.visualCloseFinished)
    }
}
