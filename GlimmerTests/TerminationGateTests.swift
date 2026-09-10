//
//  TerminationGateTests.swift
//
//  Covers the quit-time rule for a live stream: the reply defers while a
//  session is up, a prompt stop completes inside the bound, and a stop that
//  never returns is abandoned AT the bound rather than pinning the quit.
//  The AppKit side (applicationShouldTerminate's reply call) is deliberately
//  not exercised; the gate is the pure part.
//

import AppKit
import Testing
@testable import Glimmer

struct TerminationGateTests {

    @Test func liveOrConnectingSessionDefersTheQuit() {
        #expect(TerminationGate.reply(isStreaming: true) == .terminateLater)
        #expect(TerminationGate.reply(isStreaming: false) == .terminateNow)
    }

    @Test func theBoundIsShortEnoughToFeelLikeQuit() {
        // Two seconds: a LAN /cancel with margin, short enough that a dead
        // host doesn't make Cmd-Q feel broken.
        #expect(TerminationGate.stopBoundSeconds == 2.0)
    }

    @Test func aPromptStopCompletesInsideTheBound() async {
        let finished = await TerminationGate.runBounded(seconds: 2.0) { }
        #expect(finished)
    }

    @Test func aHungStopIsAbandonedAtTheBound() async {
        let hang = HangingOperation()
        let start = ContinuousClock.now
        let finished = await TerminationGate.runBounded(seconds: 0.2) { await hang.wait() }
        let elapsed = ContinuousClock.now - start
        #expect(!finished)
        // Returned at the bound - not at the operation's (never) completion.
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
        await hang.release()
    }
}

/// An operation that never returns on its own and ignores cancellation - the
/// shape of a stop wedged on a dead host. `release` lets the leftover task
/// finish so the test leaves nothing suspended.
private actor HangingOperation {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
