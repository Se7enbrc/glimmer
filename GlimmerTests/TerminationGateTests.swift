// A hung stop must not pin quit; the AppKit reply callback itself is not exercised.

import AppKit
import Testing
@testable import Glimmer

struct TerminationGateTests {

    @Test func anySessionObjectDefersTheQuit() {
        #expect(TerminationGate.reply(hasSession: true) == .terminateLater)
        #expect(TerminationGate.reply(hasSession: false) == .terminateNow)
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
        await Task(priority: .high) {
            let hang = HangingOperation()
            let started = ContinuousClock.now
            let finished = await TerminationGate.runBounded(seconds: 0.2) {
                await hang.wait()
            }
            let returned = ContinuousClock.now
            // The operation only ends when released below, so returning while it still
            // waits proves the bound won; an upper wall-clock limit would only time the pool.
            #expect(!finished)
            #expect(returned - started >= .milliseconds(150))
            #expect(await hang.isWaiting)
            await hang.release()
        }.value
    }
}

/// An operation that never returns on its own and ignores cancellation - the
/// shape of a stop wedged on a dead host. `release` lets the leftover task
/// finish so the test leaves nothing suspended.
private actor HangingOperation {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { waiter != nil && !released }

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
