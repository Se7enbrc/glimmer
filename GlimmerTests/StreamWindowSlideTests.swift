// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Interrupted cover motion must return to identity and ignore superseded completions.

import AppKit
@testable import GlimmerEngine
import Synchronization
import QuartzCore
import Testing
import SwiftUI
@testable import Glimmer

@MainActor
struct StreamWindowSlideTests {
    @Test(arguments: [false, true])
    func lostClosingCompletionSettlesTeardownExactlyOnce(retreating: Bool) async {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        var deadlines: [@MainActor () -> Void] = []
        stream.scheduleCoverSettlement = { delay, settle in
            #expect(delay > 0 && delay < 2)
            deadlines.append(settle)
        }
        defer { stream.resetCoverSlide() }
        if retreating { stream.slideCover(entering: false) {} }
        let power = Mutex(0)
        var services = SessionServices()
        services.beginActivity = { power.withLock { $0 += 1 } }
        services.endActivity = { power.withLock { $0 -= 1 } }
        let defaults = IsolatedDefaults()
        let pc = FakeSunshine.scripted([:])
        let session = StreamSession(hostDisposition: .disconnectOnly,
            audioDecoder: AudioDecoder(defaults: defaults.defaults), services: services,
            backend: InputRecordingBackend(), makeNetwork: { pc.client($0) }, makeBackend: { InputRecordingBackend() })
        let presentation = SessionPresentation()
        var closes = 0
        presentation.close = {
            stream.didClose = true
            stream.slideCover(entering: false, closing: true) {
                closes += 1
                stream.completeVisualClose()
            }
        }
        let waiting = SafetyTestGate()
        presentation.waitForVisualClose = {
            await waiting.open()
            await stream.waitForVisualClose()
        }
        await session.installCloseFixture(presentation, streaming: true)
        await session.beginPowerAssertion()
        let stopping = Task { await session.stop() }
        await waiting.wait()
        #expect(power.withLock { $0 } == 1 && !stream.visualCloseFinished)
        #expect(deadlines.count == 1)
        if let deadline = deadlines.first { deadline() } else { stream.completeVisualClose() }
        await stopping.value
        for await _ in session.events {}
        #expect(stream.visualCloseFinished && power.withLock { $0 } == 0)
        #expect(closes == 1)
        animations.finish()
        deadlines.first?()
        #expect(closes == 1 && power.withLock { $0 } == 0)
    }

    @Test func resumeWaitsForOpaqueSettlementEvenWhenAnimationCompletionIsLost() throws {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        var deadlines: [@MainActor () -> Void] = []
        stream.scheduleCoverSettlement = { _, settle in deadlines.append(settle) }
        defer { stream.resetCoverSlide() }
        var resumes = 0
        stream.slideCover(entering: false) {}
        animations.finish()
        stream.slideCover(entering: true) { resumes += 1 }
        #expect(StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: false,
            occlusionVisible: true, revealing: stream.presentationRevealInProgress))
        #expect(!stream.window.isOpaque)
        let settle = try #require(deadlines.first)
        settle()
        #expect(resumes == 1)
        #expect(stream.window.isOpaque)
        #expect(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) == nil)
        #expect(!StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: false,
            occlusionVisible: true, revealing: stream.presentationRevealInProgress))
        animations.finish()
        settle()
        #expect(resumes == 1)
    }

    @Test func staleSettlementCannotUndoAnotherRetreat() throws {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        var settle: (@MainActor () -> Void)?
        stream.scheduleCoverSettlement = { _, completion in settle = completion }
        defer { stream.resetCoverSlide() }
        var returned = false
        stream.slideCover(entering: true) { returned = true }
        stream.slideCover(entering: false) {}
        let staleSettlement = try #require(settle)
        staleSettlement()
        #expect(!returned)
        #expect(!stream.window.isOpaque)
        #expect(stream.displayLayer.animation(forKey: StreamWindow.coverSlideKey) != nil)
    }

    @Test func reducedMotionReturnAlsoSettlesWithoutACompletion() throws {
        let stream = StreamWindow()
        let animations = AnimationDriver()
        animations.install(on: stream)
        var settle: (@MainActor () -> Void)?
        stream.scheduleCoverSettlement = { _, completion in settle = completion }
        defer { stream.resetCoverSlide() }
        stream.window.alphaValue = 0
        stream.refreshPresentationVisibility()
        #expect(stream.presentationSuppressed)
        #expect(StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: false,
            occlusionVisible: true, alpha: 0))
        var returned = 0
        stream.fadeCover(entering: true) { returned += 1 }
        let deadline = try #require(settle)
        deadline()
        #expect(!stream.presentationRevealInProgress)
        #expect(stream.window.alphaValue == 1)
        animations.finish()
        #expect(returned == 1)
    }

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
        #expect(stream.statsOverlay.layer.isHidden)
        expectNoAnimations(in: stream.statsOverlay.layer)
        for banner in [stream.reconnectBanner, stream.networkBanner, stream.leaveHintBanner, stream.captureHintBanner] {
            #expect(!banner.isVisible && banner.noticeFrame == nil)
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
