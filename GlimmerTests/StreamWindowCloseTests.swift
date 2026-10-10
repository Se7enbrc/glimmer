import Testing
@testable import Glimmer

struct StreamWindowCloseTests {
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
