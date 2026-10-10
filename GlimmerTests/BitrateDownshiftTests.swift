// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
        #expect(controller.downshiftCount(nowUptime: 900) == BitrateDownshiftController.maxDownshifts)
    }

    /// The budget is a window, not a session: a downshift stops counting after half an hour, so a
    /// link that failed long ago is judged again rather than written off for the rest of the stream.
    @Test func budgetRecoversOnceTheWindowPasses() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100)
        controller.recordDownshift(atUptime: 300)
        let spent = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                                        currentKbps: 30_240, nowUptime: 900)
        #expect(spent == .budgetExhausted)
        let later = 300 + BitrateDownshiftController.budgetWindowSeconds + 1
        let again = controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                                        currentKbps: 30_240, nowUptime: later)
        #expect(again == .downshift(toKbps: 18_144))
        #expect(controller.downshiftCount(nowUptime: later) == 0)
    }

    // MARK: - The way back up

    /// A downshift must not be for good. After a clean window at the lowered rate, one step back
    /// toward the route's ask; a second step needs its own clean window.
    @Test func cleanWindowEarnsOneStepBackUp() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100, route: "tunnel")
        controller.recordDownshift(atUptime: 300, route: "tunnel")
        let clean = BitrateDownshiftController.stepUpCleanSeconds
        #expect(controller.stepUp(currentKbps: 30_240, routeKbps: configuredKbps, nowUptime: 300 + clean - 1) == nil)
        #expect(controller.stepUp(currentKbps: 30_240, routeKbps: configuredKbps, nowUptime: 300 + clean) == 50_400)
        controller.recordStepUp(atUptime: 300 + clean, reachedRoute: false)
        #expect(controller.isDownshifted)
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: 300 + clean + 1) == nil)
        let second = controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: 300 + 2 * clean)
        #expect(second == configuredKbps)   // capped at the route's ask, never above it
        controller.recordStepUp(atUptime: 300 + 2 * clean, reachedRoute: true)
        #expect(!controller.isDownshifted)
        #expect(controller.stepUp(currentKbps: configuredKbps, routeKbps: configuredKbps, nowUptime: 9_000) == nil)
    }

    /// A stall at the lowered rate restarts the clean window; the step-up waits for a full one.
    @Test func aStallRestartsTheCleanWindow() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100, route: "wifi")
        controller.noteStall(atUptime: 350)
        let clean = BitrateDownshiftController.stepUpCleanSeconds
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: 100 + clean) == nil)
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: 350 + clean) == configuredKbps)
    }

    /// A step-up that stalls again inside its own window doubles the next window, up to the cap; one
    /// that outlives its window proves the link and the backoff starts over.
    @Test func aStepUpThatStallsAgainWaitsTwiceAsLong() {
        var controller = BitrateDownshiftController()
        let clean = BitrateDownshiftController.stepUpCleanSeconds
        controller.recordDownshift(atUptime: 0, route: "tunnel")
        controller.recordStepUp(atUptime: clean, reachedRoute: true)
        controller.recordDownshift(atUptime: clean + 60, route: "tunnel")   // failed within its window
        let base = clean + 60
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: base + clean) == nil)
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: base + 2 * clean) == configuredKbps)

        controller.recordStepUp(atUptime: base + 2 * clean, reachedRoute: true)
        controller.recordDownshift(atUptime: base + 2 * clean + 3 * clean, route: "tunnel")   // outlived it
        let proven = base + 5 * clean
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: proven + clean) == configuredKbps)
    }

    /// A step-up gives back one downshift, so a probe that fails after the budget was spent can still
    /// drop back to the rate that worked, and that failure doubles the next clean window.
    @Test func aFailedStepUpCanAlwaysRollBack() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100, route: "tunnel")
        controller.recordDownshift(atUptime: 300, route: "tunnel")
        controller.recordStepUp(atUptime: 600, reachedRoute: false)
        #expect(controller.evaluate(isRemote: true, decodeIdle: stalled, receiveIdle: receiving,
                                    currentKbps: 50_400, nowUptime: 625) == .downshift(toKbps: 30_240))
        controller.recordDownshift(atUptime: 625, route: "tunnel")
        #expect(controller.stepUp(currentKbps: 30_240, routeKbps: configuredKbps, nowUptime: 925) == nil)
    }

    /// The window never grows past the cap however often a step-up fails.
    @Test func stepUpBackoffStopsAtTheCap() {
        var controller = BitrateDownshiftController()
        var now = 0.0
        for _ in 0..<8 {
            controller.recordDownshift(atUptime: now, route: "tunnel")
            now += 1
            controller.recordStepUp(atUptime: now, reachedRoute: true)
            now += 1
        }
        controller.recordDownshift(atUptime: now, route: "tunnel")
        let cap = BitrateDownshiftController.stepUpCleanCapSeconds
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: now + cap - 1) == nil)
        #expect(controller.stepUp(currentKbps: 50_400, routeKbps: configuredKbps, nowUptime: now + cap) == configuredKbps)
    }

    /// Undocking onto another route: a downshift judged on a tunnel says nothing about the LAN, so the
    /// reconnect asks for the new route's full rate and the controller starts fresh there.
    @Test func routeChangeRestoresTheRoutesAsk() {
        var controller = BitrateDownshiftController()
        controller.recordDownshift(atUptime: 100, route: "tunnel")
        let lowered = RouteAsk(kbps: 50_400, boost: 1, route: "tunnel")
        let wired = RouteAsk(kbps: 361_600, boost: 2, route: "wired")
        #expect(controller.covers(route: "tunnel"))
        #expect(!controller.covers(route: wired.route))
        #expect(StreamPathMTU.reconnectAsk(current: lowered, route: wired,
                                           downshifted: controller.covers(route: wired.route)) == wired)
        let sameRoute = RouteAsk(kbps: 84_000, boost: 1, route: "tunnel")
        #expect(StreamPathMTU.reconnectAsk(current: lowered, route: sameRoute,
                                           downshifted: controller.covers(route: sameRoute.route)) == lowered)
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
        #expect(controller.downshiftCount(nowUptime: 400) == 0)
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
        #expect(controller.downshiftCount(nowUptime: 100) == 0)
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
