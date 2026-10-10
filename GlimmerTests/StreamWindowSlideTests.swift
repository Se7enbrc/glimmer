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
@testable import Glimmer

@MainActor
struct StreamWindowSlideTests {

    @Test(arguments: [CoverSlideEvent.firstFrame, .away, .back])
    func onlyTheBorderlessCoverSlides(event: CoverSlideEvent) {
        let still: CoverTransition = event == .firstFrame ? .fade : .snap
        #expect(StreamWindow.coverTransition(event, borderlessCover: true, reduceMotion: false) == .slide)
        #expect(StreamWindow.coverTransition(event, borderlessCover: true, reduceMotion: true) == still)
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
}
