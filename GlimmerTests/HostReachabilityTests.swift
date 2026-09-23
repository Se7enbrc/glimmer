//
//  HostReachabilityTests.swift
//
//  The launcher's reachability probe cancels each connection once. The
//  deadline cancels only when it is the first to resolve the probe; a second
//  cancel is what Network.framework logs as a fault on every poll.
//

import Testing
@testable import Glimmer

struct HostReachabilityTests {

    /// Only the call that resumes the probe learns it won.
    @Test func onlyTheFirstResumeWins() async {
        var wins: [Bool] = []
        let outcome = await withCheckedContinuation { cont in
            let once = HostReachability.OnceResumer(cont: cont)
            wins.append(once.resume(with: .reachable(rttMs: 3)))
            wins.append(once.resume(with: .unreachable))
        }
        #expect(wins == [true, false])
        #expect(outcome == .reachable(rttMs: 3))
    }
}
