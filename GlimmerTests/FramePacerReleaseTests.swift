// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  FramePacerReleaseTests.swift
//
//  Release decisions without a display link: the present-loop backoff, the
//  starvation failsafe, renderer refusals, the watchdog's recovery actions and
//  the submit path's suppression, overflow, warm-handover and cadence rules.
//

import CoreMedia
import Foundation
import os
import QuartzCore
import Testing
@testable import Glimmer

/// A running pacer with `queued` frames one stream interval apart.
func makeTestPacer(fps: Int32 = 120, queued: Int = 0) throws -> FramePacer {
    let pacer = FramePacer(stats: StatsCollector(), configuredFps: fps)
    pacer.running = true
    for index in 0..<queued {
        pacer.queue.append(FramePacer.Entry(
            sampleBuffer: try makeEmptySampleBuffer(), hostPTSSeconds: Double(index) / Double(fps)))
    }
    return pacer
}

func makeEmptySampleBuffer() throws -> CMSampleBuffer {
    var buffer: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &buffer)
    return try #require(buffer)
}

/// Records every buffer handed to the renderer and answers `accept`.
func recordPresents(_ pacer: FramePacer, accept: Bool = true) -> OSAllocatedUnfairLock<[ObjectIdentifier]> {
    let presented = OSAllocatedUnfairLock(initialState: [ObjectIdentifier]())
    pacer.willPresent = { buffer in
        let id = ObjectIdentifier(buffer)
        presented.withLock { $0.append(id) }
        return accept
    }
    return presented
}

struct FramePacerReleaseTests {
    private let interval = 1.0 / 120

    // MARK: - Present-loop backoff

    /// A head more than three intervals late with fresher frames behind it collapses to the
    /// newest and re-anchors the base one interval behind the target; anything less waits.
    @Test func backoffCollapsesOnlyAHopelesslyLateBacklog() throws {
        let pacer = try makeTestPacer(queued: 3)
        pacer.lastPresentMediaTime = 10
        pacer.liveness.starvedTickStreak = 5
        pacer.lock.lock()
        let early = pacer.takeBackoffNewestLocked(targetTimestamp: 10 + 2 * interval)
        let backwards = pacer.takeBackoffNewestLocked(targetTimestamp: 9)
        let late = pacer.takeBackoffNewestLocked(targetTimestamp: 10 + 4 * interval)
        pacer.lock.unlock()
        #expect(early == nil)
        #expect(backwards == nil)
        let beat = try #require(late)
        #expect(beat.newest.hostPTSSeconds == 2 * interval)
        #expect(beat.droppedCount == 2)
        #expect(pacer.queue.isEmpty)
        #expect(abs(pacer.lastPresentMediaTime - (10 + 3 * interval)) < 1e-9)
        #expect(pacer.liveness.starvedTickStreak == 0)

        let single = try makeTestPacer(queued: 1)
        single.lastPresentMediaTime = 10
        single.lock.lock()
        #expect(single.takeBackoffNewestLocked(targetTimestamp: 20) == nil)
        single.lock.unlock()
        #expect(single.queue.count == 1)
    }

    /// A late tick backs off to the newest frame and presents it; the skipped head is a late drop.
    @Test func lateTickPresentsTheNewestFrame() throws {
        let pacer = try makeTestPacer(queued: 2)
        let newest = try ObjectIdentifier(#require(pacer.queue.last?.sampleBuffer))
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 10
        pacer.releaseDueFrame(targetTimestamp: 10.05, vsyncInterval: interval, tickScanout: 10.05)
        #expect(presented.withLock { $0 } == [newest])
        #expect(pacer.queue.isEmpty)
        #expect(pacer.stats.presentationLateDropCount() == 1)
        #expect(pacer.tickDeficit.tickScanoutMediaTime == 10.05)
        #expect(pacer.liveness.releaseCount == 1)
    }

    /// Gap recovery plays the catch-up through: no backoff, the oldest frame goes first.
    @Test func gapRecoverySuppressesTheBackoff() throws {
        let pacer = try makeTestPacer(queued: 3)
        let oldest = try ObjectIdentifier(#require(pacer.queue.first?.sampleBuffer))
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 10
        pacer.liveness.emptyTickStreak = FramePacer.gapRecoveryTickThreshold
        pacer.releaseDueFrame(targetTimestamp: 10.05, vsyncInterval: interval, tickScanout: 10.05)
        #expect(presented.withLock { $0 } == [oldest])
        #expect(pacer.queue.count == 2)
        #expect(pacer.stats.presentationLateDropCount() == 0)
    }

    /// A refused backoff frame is a felt gap and feeds the reject streak, never a release.
    @Test func refusedBackoffFrameCountsAGap() throws {
        let pacer = try makeTestPacer(queued: 3)
        let presented = recordPresents(pacer, accept: false)
        pacer.lastPresentMediaTime = 10
        pacer.lock.lock()
        let beat = try #require(pacer.takeBackoffNewestLocked(targetTimestamp: 11))
        pacer.lock.unlock()
        pacer.presentBackoffAndYield(beat)
        #expect(presented.withLock { $0.count } == 1)
        #expect(pacer.stats.presentationGapCount() == 1)
        #expect(pacer.stats.presentationLateDropCount() == 2)
        #expect(pacer.liveness.presentRejectStreak == 1)
        #expect(pacer.liveness.releaseCount == 0)
        #expect(pacer.tickDeficit.lastPresentedSampleBuffer == nil)
    }

    // MARK: - Starvation failsafe

    /// Ticks that find a frame queued but never due count a streak; the eighth re-anchors the
    /// base on the grid so the next tick releases, and that release clears the starvation log.
    @Test func starvationFailsafeReanchorsAfterEightWedgedTicks() throws {
        let pacer = try makeTestPacer(queued: 1)
        let presented = recordPresents(pacer)
        pacer.lastPresentMediaTime = 10
        let target = 10.001
        for tick in 1..<FramePacer.starvationFailsafeTicks {
            pacer.releaseDueFrame(targetTimestamp: target, vsyncInterval: interval, tickScanout: target)
            #expect(pacer.liveness.starvedTickStreak == tick)
        }
        #expect(pacer.liveness.loggedStarvation)
        #expect(pacer.lastPresentMediaTime == 10)
        pacer.releaseDueFrame(targetTimestamp: target, vsyncInterval: interval, tickScanout: target)
        #expect(pacer.liveness.starvedTickStreak == 0)
        #expect(abs(pacer.lastPresentMediaTime - (target - interval)) < 1e-9)
        #expect(presented.withLock { $0.isEmpty })
        pacer.releaseDueFrame(targetTimestamp: target, vsyncInterval: interval, tickScanout: target)
        #expect(presented.withLock { $0.count } == 1)
        #expect(!pacer.liveness.loggedStarvation)
    }

    // MARK: - Renderer refusals and over-target releases

    /// Refusals inside the 250 ms window extend one episode; a quiet gap past it starts a new one.
    @Test func rejectWindowRestartsAfterAQuietGap() throws {
        let pacer = try makeTestPacer()
        pacer.noteGateReleaseRejected(at: 100)
        pacer.noteGateReleaseRejected(at: 100.1)
        #expect(pacer.liveness.presentRejectStreak == 2)
        #expect(pacer.liveness.firstRejectHostTime == 100)
        pacer.noteGateReleaseRejected(at: 100.4)
        #expect(pacer.liveness.presentRejectStreak == 1)
        #expect(pacer.liveness.firstRejectHostTime == 100.4)
        #expect(pacer.liveness.lastRejectHostTime == 100.4)

        let refused = try makeTestPacer()
        _ = recordPresents(refused, accept: false)
        refused.presentGateRelease(
            FramePacer.Entry(sampleBuffer: try makeEmptySampleBuffer(), hostPTSSeconds: 0), vsyncInterval: interval)
        #expect(refused.liveness.presentRejectStreak == 1)
        #expect(refused.liveness.releaseCount == 0)
    }

    /// Forced releases build the streak, a normally-due release clears it, an idle tick keeps it.
    @Test func overTargetStreakTracksOnlyForcedReleases() throws {
        let pacer = try makeTestPacer()
        let entry = FramePacer.Entry(sampleBuffer: try makeEmptySampleBuffer(), hostPTSSeconds: 0)
        let forced = FramePacer.DueGateResult(toPresent: entry, heldForGrowth: false, forcedOverTarget: true)
        let normal = FramePacer.DueGateResult(toPresent: entry, heldForGrowth: false, forcedOverTarget: false)
        let idle = FramePacer.DueGateResult(toPresent: nil, heldForGrowth: false, forcedOverTarget: false)
        pacer.recordOverTargetReleaseIfNeeded(forced, depth: 3)
        pacer.recordOverTargetReleaseIfNeeded(forced, depth: 3)
        pacer.recordOverTargetReleaseIfNeeded(idle, depth: 3)
        #expect(pacer.liveness.overTargetReleaseStreak == 2)
        pacer.recordOverTargetReleaseIfNeeded(normal, depth: 1)
        #expect(pacer.liveness.overTargetReleaseStreak == 0)
    }

    // MARK: - Watchdog recovery actions

    @Test func dropToNewestKeepsOnlyTheFreshestFrame() throws {
        let pacer = try makeTestPacer(queued: 4)
        #expect(pacer.dropToNewest(reason: "test") == 3)
        #expect(pacer.queue.map(\.hostPTSSeconds) == [3.0 / 120])
        #expect(pacer.stats.presentationLateDropCount() == 3)
        #expect(pacer.dropToNewest(reason: "test") == 0)
        pacer.running = false
        pacer.queue.append(FramePacer.Entry(sampleBuffer: try makeEmptySampleBuffer(), hostPTSSeconds: 1))
        #expect(pacer.dropToNewest(reason: "test") == 0)
        #expect(pacer.queue.count == 2)
    }

    @Test func clearQueueDropsEverythingAndResetsTheBase() throws {
        let pacer = try makeTestPacer(queued: 3)
        pacer.lastPresentMediaTime = 5
        pacer.liveness.starvedTickStreak = 4
        pacer.tickDeficit.lastPresentedSampleBuffer = try makeEmptySampleBuffer()
        #expect(pacer.clearQueue(reason: "test") == 3)
        #expect(pacer.queue.isEmpty)
        #expect(pacer.lastPresentMediaTime.isNaN)
        #expect(pacer.liveness.starvedTickStreak == 0)
        #expect(pacer.tickDeficit.lastPresentedSampleBuffer == nil)
        #expect(pacer.stats.presentationLateDropCount() == 3)

        let stopped = try makeTestPacer(queued: 2)
        stopped.running = false
        #expect(stopped.clearQueue(reason: "test") == 0)
        #expect(stopped.queue.count == 2)
    }

    /// A refused direct drain still discards the stale frames but counts a reject, not a release.
    @Test func refusedDirectDrainFeedsTheRejectStreak() async throws {
        let pacer = try makeTestPacer(queued: 3)
        let newest = try ObjectIdentifier(#require(pacer.queue.last?.sampleBuffer))
        let presented = recordPresents(pacer, accept: false)
        pacer.lastPresentMediaTime = 5
        pacer.drainHeadDirectly(reason: "test")
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [newest])
        #expect(pacer.queue.isEmpty)
        #expect(pacer.lastPresentMediaTime.isNaN)
        #expect(pacer.stats.presentationLateDropCount() == 2)
        #expect(pacer.liveness.presentRejectStreak == 1)
        #expect(pacer.liveness.releaseCount == 0)

        pacer.drainHeadDirectly(reason: "test")
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0.count } == 1)
    }

    /// Without a link there is no grid to anchor on, so the base resets and the next tick releases.
    @MainActor @Test func forceReleaseWithoutALinkResetsTheBase() throws {
        let pacer = try makeTestPacer(queued: 2)
        pacer.lastPresentMediaTime = 5
        pacer.liveness.starvedTickStreak = 3
        let marker = UUID().uuidString
        #expect(pacer.forceReleaseNextTick(reason: marker) == 2)
        #expect(pacer.lastPresentMediaTime.isNaN)
        #expect(pacer.liveness.starvedTickStreak == 0)
        #expect(LogStore.shared.snapshot().contains {
            $0.message == "FramePacer self-heal: force-release-next-tick (\(marker)) depth=2"
        })
    }

    /// The window snapshot reports min/avg/max Hz from the interval extremes, then starts fresh.
    @Test func refreshWindowSnapshotReportsAndResets() throws {
        let pacer = try makeTestPacer()
        pacer.refreshTelemetry.refreshIntervalSamples = 4
        pacer.refreshTelemetry.refreshIntervalSumSeconds = 4 * interval
        pacer.refreshTelemetry.refreshIntervalMinSeconds = 1.0 / 144
        pacer.refreshTelemetry.refreshIntervalMaxSeconds = 1.0 / 60
        pacer.refreshTelemetry.refreshChangedSinceRead = true
        let first = pacer.refreshWindowSnapshot()
        #expect(abs((first.minHz ?? 0) - 60) < 1e-9)
        #expect(abs((first.avgHz ?? 0) - 120) < 1e-9)
        #expect(abs((first.maxHz ?? 0) - 144) < 1e-9)
        #expect(first.changed)
        let second = pacer.refreshWindowSnapshot()
        #expect(second.minHz == nil && second.avgHz == nil && second.maxHz == nil)
        #expect(!second.changed)
    }

    // MARK: - Submit

    @Test func stoppedPacerIgnoresSubmits() throws {
        let pacer = try makeTestPacer()
        pacer.running = false
        pacer.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(pacer.queue.isEmpty)
    }

    /// While hidden only the newest frame is retained; visible, the queue caps at six.
    @Test func submitHoldsNewestWhileHiddenAndCapsWhileVisible() throws {
        let hidden = try makeTestPacer()
        hidden.tickDeficit.warmingUp = false
        hidden.setPresentSuppressed(true)
        for index in 0..<3 {
            hidden.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: Int64(index) * 750, timescale: 90_000))
        }
        #expect(hidden.queue.map(\.hostPTSSeconds) == [1_500.0 / 90_000])
        #expect(hidden.stats.presentationLateDropCount() == 0)

        let visible = try makeTestPacer()
        visible.tickDeficit.warmingUp = false
        for index in 0...FramePacer.maxQueuedFrames {
            visible.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: Int64(index) * 750, timescale: 90_000))
        }
        #expect(visible.queue.count == FramePacer.maxQueuedFrames)
        #expect(visible.queue.first?.hostPTSSeconds == 750.0 / 90_000)
        #expect(visible.stats.presentationLateDropCount() == 1)
    }

    /// During a warm handover a submit presents at once; a refusal is a reject, and a hidden
    /// window queues instead of presenting.
    @Test(arguments: [true, false])
    func warmHandoverSubmitPresentsDirectly(accept: Bool) throws {
        let pacer = try makeTestPacer()
        pacer.armWarmHandover()
        let presented = recordPresents(pacer, accept: accept)
        pacer.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(presented.withLock { $0.count } == 1)
        #expect(pacer.queue.isEmpty)
        #expect(pacer.liveness.releaseCount == (accept ? 1 : 0))
        #expect(pacer.liveness.presentRejectStreak == (accept ? 0 : 1))

        pacer.setPresentSuppressed(true)
        pacer.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        #expect(presented.withLock { $0.count } == 1)
        #expect(pacer.queue.count == 1)
    }

    /// The configured cadence holds until eight clean deltas arrive, then follows the content;
    /// a gap over a second is a stall, not a cadence sample.
    @Test func cadenceRefinesAfterEightCleanDeltas() throws {
        let pacer = try makeTestPacer()
        pacer.tickDeficit.warmingUp = false
        func submit(_ ticks: Int64) throws {
            pacer.submit(try makeEmptySampleBuffer(), hostPTS: CMTime(value: ticks, timescale: 90_000))
        }
        for index in 0..<FramePacer.minCadenceRefineSamples {
            try submit(Int64(index) * 1_500)
        }
        #expect(pacer.streamFrameIntervalSeconds == interval)
        try submit(Int64(FramePacer.minCadenceRefineSamples) * 1_500)
        #expect(abs(pacer.streamFrameIntervalSeconds - 1.0 / 60) < 1e-9)
        let samples = pacer.ptsDeltas.count
        try submit(Int64(FramePacer.minCadenceRefineSamples) * 1_500 + 180_000)
        #expect(pacer.ptsDeltas.count == samples)
    }
}
