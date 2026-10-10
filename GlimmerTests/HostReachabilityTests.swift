// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

    @Test(arguments: [Int.min, -1, 0, 65_536, Int.max])
    func invalidPortsAreUnreachable(_ port: Int) async {
        #expect(await HostReachability.measureRTT(host: "127.0.0.1", port: port) == .unreachable)
    }

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
