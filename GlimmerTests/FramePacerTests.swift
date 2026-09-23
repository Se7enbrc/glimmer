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

    /// The watchdog's non-empty clock starts on the empty → non-empty submit and
    /// reads 0 once the queue drains.
    @Test func queueNonEmptyClockFollowsSubmits() throws {
        let pacer = try makePacer(fps: 120, queued: 0)
        #expect(pacer.livenessSnapshot().secondsQueueNonEmpty == 0)
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        let held = pacer.livenessSnapshot().secondsQueueNonEmpty
        #expect(held >= 0 && held < StreamSession.presentStallThreshold)
        pacer.queue.removeAll()
        #expect(pacer.livenessSnapshot().secondsQueueNonEmpty == 0)
    }

    private let panelVsync = 1.0 / 120

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
