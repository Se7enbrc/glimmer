//
//  BitrateDownshiftTests.swift
//
//  Policy coverage for the mid-session bitrate downshift - the only rate
//  adaptation this protocol profile permits (bitrate is fixed per session; the
//  SDP is the only place it is set, so a reconnect is the only way to change it).
//
//  The controller is pure by design so the DECISION is testable without a live
//  session: the watchdog supplies decodeIdle/receiveIdle and the resolved
//  remoteness, the controller decides, StreamSession owns the side effects.
//

import Foundation
import Testing
@testable import Glimmer

struct BitrateDownshiftTests {

    /// The captured failure: 84 Mbps configured, 20+ seconds of video arriving
    /// that would not decode, on a tunnel.
    private let stalled = 25.0
    private let receiving = 0.2
    private let configuredKbps = 84_000

    // MARK: - Gating

    /// A LAN that can't carry its own negotiated rate is a different fault (bad
    /// cable, duplex mismatch, overcommitted host) and lowering the ask would
    /// mask it rather than fix it.
    @Test func lanNeverDownshifts() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: false, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .notRemote)
    }

    /// The IDR nudge must get a full chance first - it is the cheap fix for the
    /// host-paused-encoder case, and it costs nothing.
    @Test func shortStallIsTooEarly() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: true, decodeIdle: 5, receiveIdle: receiving,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .tooEarly)
    }

    /// Bits must be ARRIVING. If reception is dead too, the link is gone - that
    /// is ENet dead-peer detection's call, and downshifting would be nonsense.
    @Test func deadReceptionIsNotABitrateProblem() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: 30,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .receptionAlsoDead)
    }

    @Test func infiniteReceiveIdleIsNotABitrateProblem() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: .infinity,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .receptionAlsoDead)
    }

    // MARK: - The happy path

    @Test func remoteStallWithLiveReceptionDownshifts() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .downshift(toKbps: 50_400))   // 84000 * 0.6
    }

    /// Two steps walk the rate to ~36% of the original, then stop. The captured
    /// tunnel sustained 6-14 Mbps against an 84 Mbps ask, so the walk has to
    /// cover real ground - a 10% nibble would cost a reconnect and still overrun.
    @Test func twoStepWalkThenBudgetExhausted() {
        var controller = BitrateDownshiftController()
        var kbps = configuredKbps

        guard case .downshift(let first) = controller.evaluate(
            isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
            currentKbps: kbps, nowUptime: 100) else {
            Issue.record("first downshift declined"); return
        }
        #expect(first == 50_400)
        controller.recordDownshift(atUptime: 100)
        kbps = first

        // Past the cooldown, the second step lands.
        guard case .downshift(let second) = controller.evaluate(
            isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
            currentKbps: kbps, nowUptime: 300) else {
            Issue.record("second downshift declined"); return
        }
        #expect(second == 30_240)
        controller.recordDownshift(atUptime: 300)
        kbps = second

        // Budget spent - a third is refused however bad it gets.
        let third = controller.evaluate(isRemote: true, decodeIdle: 600, receiveIdle: receiving,
                               currentKbps: kbps, nowUptime: 900)
        #expect(third == .budgetExhausted)
        #expect(controller.downshiftCount == BitrateDownshiftController.maxDownshifts)
    }

    // MARK: - The anti-thrash rails

    /// Two downshifts must never fire on ONE episode's evidence. The cooldown
    /// has to outlast the reconnect itself plus enough streaming to judge the
    /// new rate.
    @Test func cooldownBlocksAnImmediateSecondDownshift() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100)
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: 50_400, nowUptime: 120)   // 20s later
        #expect(d == .coolingDown)
    }

    @Test func cooldownExpiresAfterItsWindow() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100)
        let after = 100 + BitrateDownshiftController.cooldownSeconds + 1
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: 50_400, nowUptime: after)
        #expect(d == .downshift(toKbps: 30_240))
    }

    /// Below the floor the stream isn't worth resuming - the honest outcome is
    /// the existing teardown, not an unwatchable trickle.
    @Test func neverStepsBelowTheFloor() {
        let controller = BitrateDownshiftController()
        // 15 Mbps * 0.6 = 9 Mbps, under the 10 Mbps floor.
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: 15_000, nowUptime: 100)
        #expect(d == .budgetExhausted)
    }

    @Test func atTheFloorExactlyIsStillAllowed() {
        let controller = BitrateDownshiftController()
        // 16667 * 0.6 = 10000 exactly.
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                           currentKbps: 16_667, nowUptime: 100)
        #expect(d == .downshift(toKbps: BitrateDownshiftController.floorKbps))
    }

    /// There is no automatic UPshift by construction - the controller only ever
    /// returns a LOWER rate, so it cannot oscillate.
    @Test func decisionIsAlwaysStrictlyDownward() {
        let controller = BitrateDownshiftController()
        for kbps in [20_000, 40_000, 84_000, 150_000] {
            guard case .downshift(let to) = controller.evaluate(
                isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                currentKbps: kbps, nowUptime: 100) else { continue }
            #expect(to < kbps)
            #expect(to >= BitrateDownshiftController.floorKbps)
        }
    }

    /// A fresh stream starts with a full budget - the state is per-session by
    /// construction (StreamSession is built per launch and owns this), so a new
    /// controller must begin unspent. The budget deliberately SURVIVES a
    /// reconnect, including a downshift's own; otherwise a link that kept
    /// failing would downshift forever.
    @Test func freshControllerStartsWithAFullBudget() {
        let controller = BitrateDownshiftController()
        #expect(controller.downshiftCount == 0)
        let d = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                                    currentKbps: configuredKbps, nowUptime: 400)
        #expect(d == .downshift(toKbps: 50_400))
    }

    /// A clean session never touches any of this.
    @Test func healthySessionNeverDownshifts() {
        let controller = BitrateDownshiftController()
        let d = controller.evaluate(isRemote: true, decodeIdle: 0.01, receiveIdle: 0.01,
                           currentKbps: configuredKbps, nowUptime: 100)
        #expect(d == .tooEarly)
        #expect(controller.downshiftCount == 0)
    }

    /// The threshold has to sit clear of the IDR-nudge tier so the cheap fix is
    /// always tried first.
    @Test func downshiftThresholdIsWellPastTheIdrNudge() {
        #expect(BitrateDownshiftController.stallSecondsBeforeDownshift
                > StreamSession.decodeStallRecoveryThreshold)
        #expect(BitrateDownshiftController.stallSecondsBeforeDownshift
                > StreamSession.frameWatchdogTimeout)
    }
}
