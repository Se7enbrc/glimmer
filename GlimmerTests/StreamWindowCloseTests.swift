// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Testing
@testable import Glimmer

struct StreamWindowCloseTests {
    @MainActor @Test(arguments: [StreamDisplayMode.window, .fullScreen])
    func userCloseAlwaysRequestsSessionStop(mode: StreamDisplayMode) {
        let stream = StreamWindow()
        stream.displayMode = mode
        stream.streamDelegate.displayMode = mode
        stream.streamDelegate.onCloseRequested = { stream.handleUserCloseRequest() }
        stream.window.delegate = stream.streamDelegate
        var stops = 0
        stream.onCloseRequested = { stops += 1 }
        stream.window.performClose(nil)
        #expect(stops == 1)
        #expect(!stream.didClose)
        #expect(!stream.userBackgrounded)
        stream.streamDelegate.onCloseRequested = nil
    }

    @Test func aSettledSpaceExitsBeforeFading() {
        var state = StreamWindowCloseState()
        #expect(state.nextAction(isFullScreen: true) == .exitSpace)
        #expect(state.transition == .exiting)
        #expect(state.nextAction(isFullScreen: false) == .wait)
        #expect(!state.fadeStarted)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: false) == .fade)
        #expect(state.nextAction(isFullScreen: false) == .none)
    }

    @Test(arguments: [false, true])
    func quittingDuringEntryWaitsRegardlessOfTheStyleBit(isFullScreen: Bool) {
        var state = StreamWindowCloseState()
        state.transition = .entering
        #expect(state.nextAction(isFullScreen: isFullScreen) == .wait)
        #expect(!state.fadeStarted)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: true) == .exitSpace)
        #expect(state.nextAction(isFullScreen: true) == .wait)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: false) == .fade)
    }

    @Test(arguments: [false, true])
    func quittingDuringConversionOrMiniPlayerExitDoesNotToggleAgain(isFullScreen: Bool) {
        var state = StreamWindowCloseState()
        state.transition = .exiting
        #expect(state.nextAction(isFullScreen: isFullScreen) == .wait)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: false) == .fade)
    }

    @Test func aFailedEntryCanCloseWithoutAnExit() {
        var state = StreamWindowCloseState()
        state.transition = .entering
        #expect(state.nextAction(isFullScreen: false) == .wait)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: false) == .fade)
    }

    @Test func aFailedExitRetriesWithoutRemovingTheWindow() {
        var state = StreamWindowCloseState()
        #expect(state.nextAction(isFullScreen: true) == .exitSpace)
        state.transition = .idle
        #expect(state.nextAction(isFullScreen: true) == .exitSpace)
        #expect(!state.fadeStarted)
    }

    @Test func borderlessAndWindowedClosesFadeImmediatelyAndOnlyOnce() {
        var state = StreamWindowCloseState()
        #expect(state.nextAction(isFullScreen: false) == .fade)
        #expect(state.nextAction(isFullScreen: false) == .none)
    }

    @Test func watchdogFadesOnceWhenATransitionNeverSettles() {
        var state = StreamWindowCloseState()
        state.transition = .entering
        #expect(state.nextAction(isFullScreen: true) == .wait)
        let first = state.forceFade()
        let second = state.forceFade()
        #expect(first && !second)
        #expect(state.nextAction(isFullScreen: false) == .none)
    }
}
