// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamWindowSlideTests.swift
//
//  The borderless cover's slide: which moments slide, where an interrupted
//  slide picks up, and that any mix of slides comes to rest at identity.
//

import AppKit
import QuartzCore
import Testing
import SwiftUI
@testable import Glimmer

@MainActor
struct StreamWindowSlideTests {

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
