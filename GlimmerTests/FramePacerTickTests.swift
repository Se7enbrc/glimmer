// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  FramePacerTickTests.swift
//
//  Tick-driven decisions on scripted link timing: present, hold and drop, the
//  refresh telemetry, the deficit engage, the self-heal poke and adaptive depth.
//

import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import GlimmerEngine
@testable import Glimmer

// Serialized: the realized-cadence baseline is process-wide tick state.
@Suite(.serialized)
struct FramePacerTickTests {
    private let interval = 1.0 / 120

    /// One tick on scripted values, with its dispatched release drained.
    private func tick(_ pacer: FramePacer, target: Double, duration: Double? = nil, timestamp: Double? = nil) {
        let duration = duration ?? interval
        pacer.handleTick(target: target, duration: duration, timestamp: timestamp ?? target - duration)
        pacer.pacingQueue.sync {}
    }

    @Test func dueTickPresentsAndStampsLiveness() throws {
        let pacer = try makeTestPacer(queued: 1)
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 10
        tick(pacer, target: 10 + interval, timestamp: 10)
        #expect(presented.withLock { $0.count } == 1)
        #expect(pacer.queue.isEmpty)
        #expect(pacer.liveness.tickCount == 1)
        #expect(pacer.liveness.lastTickTargetMediaTime == 10 + interval)
        #expect(pacer.tickDeficit.tickScanoutMediaTime == 10 + interval)
        #expect(pacer.lastPresentMediaTime == 10 + interval)
    }

    @Test func earlyTickHoldsTheFrame() throws {
        let pacer = try makeTestPacer(queued: 1)
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 20
        tick(pacer, target: 20.001)
        #expect(presented.withLock { $0.isEmpty })
        #expect(pacer.queue.count == 1)
        #expect(pacer.liveness.starvedTickStreak == 1)
    }

    @Test func lateTickDropsToTheNewest() throws {
        let pacer = try makeTestPacer(queued: 2)
        let newest = try ObjectIdentifier(#require(pacer.queue.last?.sampleBuffer))
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 30
        tick(pacer, target: 30.05)
        #expect(presented.withLock { $0 } == [newest])
        #expect(pacer.stats.presentationLateDropCount() == 1)
    }

    /// A degenerate first tick paces on 60 Hz rather than a zero interval.
    @Test func zeroDurationFallsBackToSixtyHertz() throws {
        let pacer = try makeTestPacer(queued: 1)
        pacer.lastPresentMediaTime = 39
        tick(pacer, target: 40, duration: 0, timestamp: 39.99)
        #expect(pacer.refreshTelemetry.lastRefreshIntervalSeconds == 1.0 / 60)
        #expect(abs(pacer.tickDeficit.tickScanoutMediaTime - (39.99 + 1.0 / 60)) < 1e-9)
    }

    /// Realized deltas feed the window; only a nominal-duration change flags a refresh edge.
    @Test func ticksFeedRealizedCadenceAndTheRefreshEdge() throws {
        let pacer = try makeTestPacer()
        tick(pacer, target: 50)
        tick(pacer, target: 50 + interval)
        #expect(pacer.refreshTelemetry.refreshIntervalSamples == 1)
        #expect(!pacer.refreshTelemetry.refreshChangedSinceRead)
        tick(pacer, target: 50 + 3 * interval)
        #expect(pacer.refreshTelemetry.refreshIntervalSamples == 2)
        #expect(abs(pacer.refreshTelemetry.refreshIntervalMaxSeconds - 2 * interval) < 1e-9)
        #expect(!pacer.refreshTelemetry.refreshChangedSinceRead)
        tick(pacer, target: 50 + 5 * interval, duration: 1.0 / 60)
        #expect(pacer.refreshTelemetry.refreshChangedSinceRead)
        #expect(pacer.refreshTelemetry.refreshIntervalSamples == 3)
        tick(pacer, target: 1_000)
        #expect(pacer.refreshTelemetry.refreshIntervalSamples == 3)
    }

    /// A tick closing a starved window engages the deficit mode and arms the off-tick timer.
    @Test func starvedWindowTickEngagesTheDeficitTimer() async throws {
        let pacer = try makeTestPacer(queued: 2)
        pacer.tickDeficit.warmingUp = false
        pacer.lastPresentMediaTime = 60
        pacer.tickDeficit.rateWindowStartHostTime = CFAbsoluteTimeGetCurrent() - 1.5 * FramePacer.rateWindowSeconds
        tick(pacer, target: 60.001)
        #expect(pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isFinite)
        await pacer.pacingQueue.drainForTest()
        #expect(pacer.tickDeficit.deficitTimer != nil)
        pacer.running = false
        pacer.pacingQueue.sync { pacer.reconcileDeficitTimer() }
        #expect(pacer.tickDeficit.deficitTimer == nil)
    }

    /// With a link the poke anchors one interval behind its target, so that tick releases.
    @Test func forceReleaseWithALinkReleasesOnTheNextTick() throws {
        let pacer = try makeTestPacer(queued: 1)
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 70
        pacer.liveness.starvedTickStreak = 3
        tick(pacer, target: 70.001)
        #expect(presented.withLock { $0.isEmpty })
        #expect(pacer.forceReleaseNextTick(reason: "test", linkTarget: 70.002) == 1)
        #expect(abs(pacer.lastPresentMediaTime - (70.002 - interval)) < 1e-9)
        #expect(pacer.liveness.starvedTickStreak == 0)
        tick(pacer, target: 70.002)
        #expect(presented.withLock { $0.count } == 1)
        #expect(pacer.lastPresentMediaTime == 70.002)
    }

    /// Ticks only decay the target, one frame per shrink interval; growth waits for the window tick.
    @Test func ticksDecayButNeverGrowTheDepth() throws {
        let pacer = try makeTestPacer()
        pacer.adaptiveDepth.reconciledDecisionGeneration = EnvSignalController.shared.decision.generation
        pacer.adaptiveDepth.reconciledTargetDepth = 4
        for step in 1...3 { tick(pacer, target: 80 + Double(step) * interval) }
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 1)
        pacer.growDepthTowardTarget()
        pacer.growDepthTowardTarget()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 3)

        pacer.adaptiveDepth.reconciledTargetDepth = 1
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 1
        tick(pacer, target: 81)
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 2)
        tick(pacer, target: 81 + interval)
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 2)
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 1
        tick(pacer, target: 81 + 2 * interval)
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 1)
    }
}
