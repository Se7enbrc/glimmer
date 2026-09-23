//
//  StreamReconnectTests.swift
//
//  The silent reconnect's decisions: how much budget a sleep spends, and when
//  a PC-sent terminate means the PC ended the session rather than dropped it.
//

import Foundation
import Testing
@testable import Glimmer

struct StreamReconnectTests {

    // MARK: - Awake-time budget

    @Test func sleepingThroughTheEpisodeSpendsNoBudget() throws {
        let start = SuspendingClock.now
        let budget = ReconnectBudget(seconds: 30, now: start)
        // 10 s awake, then an hour asleep: 20 s are left, counted from the wake.
        let wake = Date(timeIntervalSinceReferenceDate: 3_600)
        let deadline = try #require(budget.deadline(now: start.advanced(by: .seconds(10)), wallNow: wake))
        #expect(abs(deadline.timeIntervalSince(wake) - 20) < 0.001)
    }

    @Test func spentBudgetHasNoDeadline() {
        let start = SuspendingClock.now
        let budget = ReconnectBudget(seconds: 30, now: start)
        #expect(budget.deadline(now: start.advanced(by: .seconds(30)), wallNow: Date()) == nil)
        #expect(budget.deadline(now: start.advanced(by: .seconds(45)), wallNow: Date()) == nil)
    }

    // MARK: - Did the PC end the session?

    @Test func pcThatQuitTheAppEndedTheSession() {
        #expect(StreamSession.pcEndedSession(runningAppID: 0, appID: 881))
    }

    @Test func pcRunningAnotherAppEndedTheSession() {
        #expect(StreamSession.pcEndedSession(runningAppID: 42, appID: 881))
    }

    @Test func pcStillRunningOurAppIsWorthAReconnect() {
        #expect(!StreamSession.pcEndedSession(runningAppID: 881, appID: 881))
    }

    /// Sunshine restarting doesn't answer; that's the case a reconnect rides out.
    @Test func silentPcIsWorthAReconnect() {
        #expect(!StreamSession.pcEndedSession(runningAppID: nil, appID: 881))
        #expect(!StreamSession.pcEndedSession(runningAppID: 0, appID: nil))
    }

    // MARK: - Reconnect log cause

    @Test func ourOwnDeadPeerDoesNotBlameAPcRestart() {
        let cause = StreamSession.reconnectCause(code: StreamSession.deadPeerTerminationCode)
        #expect(!cause.contains("restart"))
        #expect(cause.contains("-1"))
    }

    @Test func pcSentCodeIsNamedInHex() {
        let cause = StreamSession.reconnectCause(code: Int32(bitPattern: 0x80030023))
        #expect(cause.contains("0x80030023"))
    }
}
