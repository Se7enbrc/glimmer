//
//  FramePacerTests.swift
//
//  Pacer release decisions that need no display link: the post-gap trim
//  ceiling, the off-tick timer's one-present-per-vsync guard, and the
//  queue's non-empty clock the present watchdog reads.
//

import CoreMedia
import Foundation
import os
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerTests {

    /// The catch-up only drains when the stream runs under the panel's rate;
    /// at fps≈refresh or above it arrives one per tick and never drains.
    @Test func postGapCatchUpDrainsOnlyBelowRefresh() {
        func drains(_ streamHz: Double, on panelHz: Double) -> Bool {
            FramePacer.postGapCatchUpDrains(
                streamIntervalSeconds: 1 / streamHz, nominalVsyncSeconds: 1 / panelHz)
        }
        #expect(!drains(120, on: 120))
        #expect(!drains(118, on: 120))
        #expect(!drains(240, on: 120))
        #expect(drains(60, on: 120))
        #expect(drains(54, on: 120))
        #expect(drains(174, on: 240))
        #expect(FramePacer.postGapCatchUpDrains(
            streamIntervalSeconds: 1.0 / 120, nominalVsyncSeconds: .nan))
    }

    /// 120fps on 120Hz right after a gap: trim to target+1 instead of parking
    /// a 6-deep burst; 60fps on the same panel keeps the burst to play through.
    @Test func postGapTrimCeilingFollowsDrainability() throws {
        for (fps, kept) in [(Int32(120), 2), (Int32(60), FramePacer.maxQueuedFrames)] {
            let pacer = try makePacer(fps: fps, queued: FramePacer.maxQueuedFrames)
            pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 120
            let now = CFAbsoluteTimeGetCurrent()
            pacer.liveness.lastGapRecoveryTime = now
            os_unfair_lock_lock(&pacer.lock)
            let result = pacer.gapAwareTrimLocked(now: now, effectiveTarget: 1)
            os_unfair_lock_unlock(&pacer.lock)
            #expect(result.inGapRecovery)
            #expect(pacer.queue.count == kept)
        }
    }

    /// A timer beat before the tick's frame scans out must not hand the
    /// renderer a second frame inside that panel vsync.
    @Test func assistBeatBeforeTickScanoutPresentsOnce() throws {
        let (pacer, presents) = try makeAssistPacer()
        releaseOnHalfRateTick(pacer, linkTimestamp: CACurrentMediaTime())
        pacer.deficitTimerFired()
        #expect(presents.withLock { $0 } == 1)
        #expect(pacer.queue.count == 1)
    }

    /// The tick's target leads by two panel vsyncs, but its frame scans out on
    /// the first; a beat past that lands on a later vsync and still releases.
    @Test func assistBeatAfterFirstPanelVsyncReleases() throws {
        let (pacer, presents) = try makeAssistPacer()
        releaseOnHalfRateTick(pacer, linkTimestamp: CACurrentMediaTime() - 1.5 * panelVsync)
        pacer.deficitTimerFired()
        #expect(presents.withLock { $0 } == 2)
    }

    /// Only a plausible lead counts as a tick's pending scanout; a lead past 1s
    /// is a timebase jump the due gate's clamp must still recover.
    @Test func tickScanoutLeadBounds() {
        #expect(FramePacer.tickOwnsScanout(now: 100, scanout: 100.008))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: 99.99))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: 105))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: .nan))
    }

    @Test func dueGateRecoversFromTimebaseJumps() throws {
        let pacer = try makePacer(fps: 120, queued: 1)
        pacer.lastPresentMediaTime = 1_000
        os_unfair_lock_lock(&pacer.lock)
        let result = pacer.dequeueDueFrameLocked(
            targetTimestamp: 5, vsyncInterval: 1.0 / 120, effectiveTarget: 1)
        os_unfair_lock_unlock(&pacer.lock)
        #expect(result.toPresent != nil)
        #expect(pacer.lastPresentMediaTime == 5)

        let overdue = try makePacer(fps: 120, queued: 1)
        overdue.lastPresentMediaTime = 0
        os_unfair_lock_lock(&overdue.lock)
        let overdueResult = overdue.dequeueDueFrameLocked(
            targetTimestamp: 2, vsyncInterval: 1.0 / 120, effectiveTarget: 1)
        os_unfair_lock_unlock(&overdue.lock)
        #expect(overdueResult.toPresent != nil)
    }

    @Test func dueGateHoldsOnlyAfterCadenceLocks() throws {
        let interval = 1.0 / 120
        let pacer = try makePacer(fps: 120, queued: 1)
        pacer.lastPresentMediaTime = 0
        pacer.adaptiveDepth.adaptiveTargetDepth = 2
        pacer.liveness.releaseCount = 31
        os_unfair_lock_lock(&pacer.lock)
        let held = pacer.dequeueDueFrameLocked(
            targetTimestamp: interval - interval / 4, vsyncInterval: interval / 2,
            effectiveTarget: 2)
        os_unfair_lock_unlock(&pacer.lock)
        #expect(held.toPresent == nil)
        #expect(held.heldForGrowth)

        let startup = try makePacer(fps: 120, queued: 1)
        startup.lastPresentMediaTime = 0
        startup.adaptiveDepth.adaptiveTargetDepth = 2
        startup.liveness.releaseCount = 10
        os_unfair_lock_lock(&startup.lock)
        let released = startup.dequeueDueFrameLocked(
            targetTimestamp: interval - interval / 4, vsyncInterval: interval / 2,
            effectiveTarget: 2)
        os_unfair_lock_unlock(&startup.lock)
        #expect(released.toPresent != nil)
    }

    @Test func dueGateForcesBacklogAboveTrimSlack() throws {
        let pacer = try makePacer(fps: 120, queued: 4)
        pacer.lastPresentMediaTime = 0
        os_unfair_lock_lock(&pacer.lock)
        let result = pacer.dequeueDueFrameLocked(
            targetTimestamp: 0.001, vsyncInterval: 1.0 / 120, effectiveTarget: 2)
        os_unfair_lock_unlock(&pacer.lock)
        #expect(result.toPresent != nil)
        #expect(result.forcedOverTarget)
    }

    @Test func adaptiveDepthUsesSelfDecidePath() {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        #expect(pacer.adaptiveDepth.reconciledDecisionGeneration == 0)
        os_unfair_lock_lock(&pacer.lock)
        pacer.adaptiveDepth.measuredJitterMs = 0.09
        #expect(pacer.justifiedDepthLocked() == 1)
        pacer.adaptiveDepth.measuredJitterMs = 22
        #expect(pacer.justifiedDepthLocked() == 4)
        pacer.adaptiveDepth.adaptiveTargetDepth = 1
        pacer.bumpTargetForJitterLocked()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 2)

        pacer.adaptiveDepth.measuredJitterMs = 0
        pacer.adaptiveDepth.adaptiveTargetDepth = 3
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 0.1
        #expect(pacer.decayTargetLocked() == 3)
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 0.3
        #expect(pacer.decayTargetLocked() == 2)
        os_unfair_lock_unlock(&pacer.lock)

        #expect(pacer.skipRobustInterval([
            1.0 / 120, 1.0 / 120, 1.0 / 120, 1.0 / 120, 1.0 / 120, 1.0 / 120,
            1.0 / 60, 1.0 / 60
        ]) == 1.0 / 120)
    }

    @Test func cadenceWindowMirrorMatchesSortedReference() {
        var window: [Double] = []
        var sorted: [Double] = []
        window.reserveCapacity(65)
        sorted.reserveCapacity(65)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<1_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let delta = Double(state % 100_000) / 1_000_000
            window.append(delta)
            FramePacer.insertCadenceDelta(delta, into: &sorted)
            if window.count > 64 {
                let evicted = window.removeFirst()
                FramePacer.removeCadenceDelta(evicted, from: &sorted)
            }
            let reference = window.sorted()
            let index = min(reference.count - 1,
                            Int(Double(reference.count) * FramePacer.cadencePercentile))
            #expect(sorted[index] == reference[index])
        }
        let gaps = Array(repeating: 1.0 / 120, count: 6) + [1.0 / 60, 1.0 / 60]
        var gapSorted: [Double] = []
        for delta in gaps { FramePacer.insertCadenceDelta(delta, into: &gapSorted) }
        #expect(gapSorted[Int(Double(gapSorted.count) * FramePacer.cadencePercentile)] == 1.0 / 120)
    }

    @Test func backwardsPTSAppendsInQueueOrder() throws {
        let pacer = try makePacer(fps: 120, queued: 0)
        pacer.tickDeficit.warmingUp = false
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 4_294_971_000, timescale: 90_000))
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 900, timescale: 90_000))
        #expect(pacer.queue.map(\.hostPTSSeconds) == [47_721.9, 0.01])
    }

    @Test func reorderedPTSAfterResetStaysInNewEpoch() throws {
        let pacer = try makePacer(fps: 120, queued: 0)
        pacer.tickDeficit.warmingUp = false
        for seconds in [47_721.8, 0.02, 0.01] {
            try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(seconds: seconds, preferredTimescale: 90_000))
        }
        #expect(pacer.queue.map(\.hostPTSSeconds) == [47_721.8, 0.01, 0.02])
    }

    /// The watchdog's non-empty clock starts on the empty → non-empty submit,
    /// keeps running through submits that find frames queued (a wedge with
    /// frames still arriving), and reads 0 once the queue drains.
    @Test func queueNonEmptyClockFollowsSubmits() throws {
        let pacer = try makePacer(fps: 120, queued: 0)
        #expect(pacer.livenessSnapshot().secondsQueueNonEmpty == 0)
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        let held = pacer.livenessSnapshot().secondsQueueNonEmpty
        #expect(held >= 0 && held < StreamSession.presentStallThreshold)
        pacer.liveness.queueNonEmptySince -= 2 * StreamSession.presentStallThreshold
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        #expect(pacer.livenessSnapshot().secondsQueueNonEmpty > StreamSession.presentStallThreshold)
        pacer.queue.removeAll()
        #expect(pacer.livenessSnapshot().secondsQueueNonEmpty == 0)
    }

    /// A long panel vsync keeps the scanout and target 50-100 ms from `now`, so a
    /// scheduling delay between the test's clock read and the beat's can't flip either test.
    private let panelVsync = 0.1

    /// A tick release as `handleTick` makes it with the link at half the panel's
    /// rate: the target two panel vsyncs out, the scanout on the first.
    private func releaseOnHalfRateTick(_ pacer: FramePacer, linkTimestamp: CFTimeInterval) {
        pacer.releaseDueFrame(
            targetTimestamp: linkTimestamp + 2 * panelVsync, vsyncInterval: panelVsync,
            tickScanout: linkTimestamp + panelVsync)
    }

    private func makePacer(fps: Int32, queued: Int) throws -> FramePacer {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: fps)
        pacer.running = true
        for index in 0..<queued {
            pacer.queue.append(FramePacer.Entry(
                sampleBuffer: try emptySampleBuffer(), hostPTSSeconds: Double(index) / Double(fps)))
        }
        return pacer
    }

    private func makeAssistPacer() throws -> (FramePacer, OSAllocatedUnfairLock<Int>) {
        let pacer = try makePacer(fps: 120, queued: 2)
        let presents = OSAllocatedUnfairLock(initialState: 0)
        pacer.willPresent = { _ in
            presents.withLock { $0 += 1 }
            return true
        }
        pacer.tickDeficit.floorAssistActive = true
        return (pacer, presents)
    }

    private func emptySampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}
