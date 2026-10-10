// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StatsCollectorWindowTests.swift
//  The stats window: frame rates, host rate, decode EMAs, presents, drops and gaps.
//

import Foundation
import QuartzCore
import Testing
import os
@testable import Glimmer

struct StatsCollectorWindowTests {

    /// A collector whose window opened `seconds` ago, so a snapshot slides it.
    private func collector(windowAge seconds: Double = 1_000) -> StatsCollector {
        let stats = StatsCollector()
        stats.resetForConnection()
        stats.windowStart = CACurrentMediaTime() - seconds
        return stats
    }

    // MARK: - Host frame rate

    @Test func hostRateWaitsForTheWindowAndThenCountsFramesPerSecond() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for _ in 0..<30 { rate.record(hostProcessingLatency: 0) }
        #expect(rate.sample(now: 0.1) == nil)
        #expect(rate.sample(now: 1.0) == 30)
        for _ in 0..<15 { rate.record(hostProcessingLatency: 0) }
        // The old second stays in the rolling total: 45 frames over 1.5 s.
        #expect(rate.sample(now: 1.5) == 30)
    }

    @Test func hostRateCountsOnlyCaptureTimedFramesOnceAnyArrive() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for _ in 0..<3 { rate.record(hostProcessingLatency: 0) }
        for _ in 0..<2 { rate.record(hostProcessingLatency: 50) }
        #expect(rate.sample(now: 1) == 2)
    }

    @Test func hostRateIsHeldBackUntilAllFourSlicesOrOneSecondExist() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for step in 1...3 {
            for _ in 0..<10 { rate.record(hostProcessingLatency: 0) }
            #expect(rate.sample(now: Double(step) * 0.25) == nil)
        }
        for _ in 0..<10 { rate.record(hostProcessingLatency: 0) }
        #expect(rate.sample(now: 1.0) == 40)
    }

    @Test func aLongPauseDiscardsTheStaleSlices() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for _ in 0..<500 { rate.record(hostProcessingLatency: 0) }
        #expect(rate.sample(now: 1) == 500)
        for _ in 0..<10 { rate.record(hostProcessingLatency: 0) }
        #expect(rate.sample(now: 6) == 2)
    }

    // MARK: - Window snapshot

    @Test func snapshotRatesAndSizesComeFromTheSlidingWindow() throws {
        let stats = collector()
        for index in 0..<60 {
            stats.recordReceivedFrame(bytes: index == 0 ? 3_000 : 1_000, isIDR: index < 3,
                                      frameNumber: Int32(index), hostProcessingLatency: index % 2 == 0 ? 50 : 30)
        }
        for _ in 0..<54 { _ = stats.recordDecodeComplete(dropped: false) }
        for _ in 0..<30 { stats.recordRendererEnqueue() }
        let snap = stats.snapshot()
        #expect(abs((snap.receivedFps ?? 0) - 0.06) < 0.001)
        #expect(abs((snap.decodedFps ?? 0) - 0.054) < 0.001)
        #expect(abs((snap.renderedFps ?? 0) - 0.03) < 0.001)
        // 62,000 bytes over about 1000 s is about 0.000496 Mbps.
        #expect(abs((snap.measuredBitrateMbps ?? 0) - 0.000496) < 0.00005)
        #expect(abs((snap.avgFrameBytes ?? 0) - 62_000.0 / 60.0) < 1e-6)
        #expect(snap.maxFrameBytes == 3_000)
        #expect(abs((snap.idrFramePercent ?? 0) - 5) < 1e-9)
        #expect(snap.minHostProcessingLatencyMs == 3)
        #expect(snap.maxHostProcessingLatencyMs == 5)
        #expect(abs((snap.avgHostProcessingLatencyMs ?? 0) - 4) < 1e-9)
    }

    @Test func aSnapshotTakenRightAfterAnotherRepeatsTheCachedWindow() {
        let stats = collector()
        stats.recordReceivedFrame(bytes: 500, frameNumber: 1)
        let first = stats.snapshot()
        stats.recordReceivedFrame(bytes: 9_000, frameNumber: 2)
        let second = stats.snapshot()
        #expect(first.avgFrameBytes == 500)
        #expect(second.avgFrameBytes == 500)
        #expect(second.maxFrameBytes == 500)
        #expect(second.receivedFps == first.receivedFps)
    }

    @Test func aSnapshotBeforeAnyWindowCompletesCarriesNoWindowFigures() {
        let stats = StatsCollector()
        stats.resetForConnection()
        let snap = stats.snapshot(minWindowSeconds: 3_600)
        #expect(snap.receivedFps == nil)
        #expect(snap.avgFrameBytes == nil)
        #expect(snap.avgDecodeTimeMs == nil)
        #expect(snap.decoderDroppedPercent == nil)
        #expect(snap.pacingQueueDepth == 0)
        #expect(snap.presentationLateDrops == 0)
    }

    @Test func zeroByteFramesCountAsReceivedButNotInTheSizeStats() {
        let stats = collector()
        stats.recordReceivedFrame(bytes: 0, frameNumber: 1)
        stats.recordReceivedFrame(bytes: 2_000, frameNumber: 2)
        let snap = stats.snapshot()
        #expect(snap.avgFrameBytes == 2_000)
        #expect(snap.idrFramePercent == 0)
        #expect(abs((snap.receivedFps ?? 0) - 0.002) < 0.0005)
    }

    @Test func presentCadenceErrorsSplitOnTheTwoMillisecondTolerance() {
        let stats = collector()
        stats.recordPresent(cadenceErrorMs: 0.5)
        stats.recordPresent(cadenceErrorMs: -1.0)
        stats.recordPresent(cadenceErrorMs: 3.0)
        stats.recordPresent(cadenceErrorMs: 2.0)    // exactly on the tolerance is on time
        let snap = stats.snapshot()
        #expect(snap.avgPresentCadenceErrorMs == 1.625)
        #expect(snap.maxPresentCadenceErrorMs == 3)
        #expect(snap.onTimePresentPercent == 75)
    }

    @Test func hostCadencePercentilesAndLatePresentShareComeFromTheWindow() throws {
        let stats = collector()
        var pts: UInt64 = 1_000_000
        for frame in 0..<11 {
            stats.recordReceivedFrame(bytes: 100, ptsUs: pts, frameNumber: Int32(frame))
            pts += frame == 5 ? 25_000 : 10_000
        }
        stats.recordPresent(cadenceErrorMs: 9, hostPTSSeconds: 1.1, streamIntervalMs: 10, refreshMs: 0)
        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 1.11, streamIntervalMs: 10, refreshMs: 0)
        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.intervalP50Ms == 10)
        #expect(cadence.intervalP95Ms == 25)
        #expect(cadence.unevenPairs == 2)
        #expect(cadence.lateByHostPercent == 0)
    }

    // MARK: - Decode

    @Test func decodeCompletionFoldsAnEmaAndReleasesTheSubmitInterval() {
        let stats = StatsCollector()
        stats.resetForConnection()
        #expect(stats.recordDecodeComplete(dropped: false) == nil)
        let state = OSSignposter.decode.beginInterval("DecodeFrame")
        stats.recordDecodeSubmit(intervalState: state)
        #expect(stats.submitFifo.count == 1)
        #expect(stats.recordDecodeComplete(dropped: false) != nil)
        #expect(stats.submitFifo.isEmpty)
        let snap = stats.snapshot()
        #expect((snap.avgDecodeTimeMs ?? -1) >= 0)
        #expect((snap.avgDecodeServiceMs ?? -1) >= 0)
        #expect((snap.avgDecodeWaitMs ?? -1) >= 0)
        #expect(stats.decodedFrames == 2)
    }

    @Test func theSubmitFifoKeepsTheNewest64AndAbandonTakesTheLast() {
        let stats = StatsCollector()
        for _ in 0..<(StatsCollector.submitFifoCapacity + 5) {
            stats.recordDecodeSubmit(intervalState: OSSignposter.decode.beginInterval("DecodeFrame"))
        }
        #expect(stats.submitFifo.count == 64)
        #expect(stats.recordDecodeAbandoned() != nil)
        #expect(stats.submitFifo.count == 63)
        stats.dropPendingDecodeSubmits()
        #expect(stats.submitFifo.isEmpty)
        #expect(stats.recordDecodeAbandoned() == nil)
    }

    @Test func droppedDecodesAreCountedAndFeedTheDropPercentage() {
        let stats = collector()
        for frame in 0..<4 { stats.recordReceivedFrame(bytes: 100, frameNumber: Int32(frame)) }
        _ = stats.recordDecodeComplete(dropped: true)
        #expect(stats.decoderDropCount() == 1)
        stats.recordDecoderDiscard()
        #expect(stats.decoderDropCount() == 2)
        #expect(stats.snapshot().decoderDroppedPercent == 50)
    }

    @Test func resetForConnectionClearsTheWindowButKeepsLifetimeDropTotals() {
        let stats = collector()
        stats.recordReceivedFrame(bytes: 100, frameNumber: 1)
        _ = stats.recordDecodeComplete(dropped: true)
        stats.recordPresent(cadenceErrorMs: 5)
        stats.recordPacingDepth(3)
        stats.resetForConnection()
        #expect(stats.decoderDroppedFrames == 0)
        #expect(stats.presentCadenceSamples == 0)
        #expect(stats.lastPacingDepth == 0)
        #expect(stats.windowCache == nil)
        #expect(stats.decodeTimeEmaSeconds == nil)
        #expect(stats.decoderDropCount() == 1)
    }

    @Test func decodeAndPresentAgesAreInfiniteUntilSomethingHappens() {
        let stats = StatsCollector()
        #expect(stats.secondsSinceLastDecodedFrame() == .infinity)
        #expect(stats.secondsSinceLastPresent() == .infinity)
        stats.recordDecodedFrame()
        stats.recordRendererEnqueue()
        #expect(stats.secondsSinceLastDecodedFrame() >= 0)
        #expect(stats.secondsSinceLastDecodedFrame() < 60)
        #expect(stats.secondsSinceLastPresent() >= 0)
        #expect(stats.secondsSinceLastPresent() < 60)
    }

    // MARK: - Drop counters and gaps

    @Test func dropAndGapCountersAccumulateAndReachTheSnapshot() {
        let stats = collector()
        stats.recordPresentationLateDrop()
        stats.recordPresentationLateDrop()
        stats.recordPresentationGap()
        stats.recordRendererBackpressureDrop()
        stats.recordPacingDepth(4)
        #expect(stats.presentationLateDropCount() == 2)
        #expect(stats.presentationGapCount() == 1)
        #expect(stats.backpressureDropCount() == 1)
        let snap = stats.snapshot()
        #expect(snap.presentationLateDrops == 2)
        #expect(snap.presentationGaps == 1)
        #expect(snap.pacingQueueDepth == 4)
    }

    @Test func aHundredMillisecondDroughtWithFramesArrivingIsAPerceivedGap() {
        let stats = StatsCollector()
        let shared = TelemetryCounters.shared.presentGapDroughtTotal.value
        stats.recordReceivedFrame(bytes: 1, frameNumber: 1)
        stats.recordReceivedFrame(bytes: 1, frameNumber: 2)
        stats.gapBaselineTime = CACurrentMediaTime() - 0.5
        stats.gapBaselineReceived = 0
        stats.recordRendererEnqueue()
        #expect(stats.presentationGapCount() == 1)
        #expect(TelemetryCounters.shared.presentGapDroughtTotal.value >= shared + 1)
        // The present reset the baseline, so an immediate next one is not a gap.
        stats.recordRendererEnqueue()
        #expect(stats.presentationGapCount() == 1)
    }

    @Test func aDroughtWithTooFewIncomingFramesIsTheNetworksNotAGap() {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1, frameNumber: 1)
        stats.gapBaselineTime = CACurrentMediaTime() - 0.5
        stats.gapBaselineReceived = 0
        stats.recordRendererEnqueue()
        #expect(stats.presentationGapCount() == 0)
    }

    @Test func excludingGapJudgingClearsTheBaselineAndCountsNothing() {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1, frameNumber: 1)
        stats.recordReceivedFrame(bytes: 1, frameNumber: 2)
        stats.gapBaselineTime = CACurrentMediaTime() - 0.5
        stats.setGapJudgingExcluded(true)
        #expect(stats.gapBaselineTime == 0)
        stats.recordRendererEnqueue()
        #expect(stats.presentationGapCount() == 0)
        #expect(stats.gapBaselineTime == 0)
        stats.setGapJudgingExcluded(false)
        stats.recordRendererEnqueue()
        #expect(stats.gapBaselineTime > 0)
    }

    // MARK: - Host timing attribution

    @Test(arguments: [
        (10.0, 10.0, 0.0, false),    // host delivered on the stream interval
        (25.0, 10.0, 0.0, true),     // host was late by 15 ms
        (10.0, 10.0, 16.7, true),    // display refresh stretched it
        (0.0, 10.0, 0.0, false),     // no host delta yet
        (1_000.0, 10.0, 0.0, false), // pause, not a cadence miss
        (25.0, 0.0, 0.0, false)      // unknown stream interval
    ])
    func hostTimingExplainsOnlyAMeasuredDepartureFromTheStreamInterval(
        delta: Double, stream: Double, refresh: Double, expected: Bool
    ) {
        #expect(StatsCollector.hostTimingExplainsLate(
            hostDeltaMs: delta, streamIntervalMs: stream, refreshMs: refresh) == expected)
    }

    @Test func hostDeltaIgnoresNonConsecutiveFramesAndHugeGaps() {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1, ptsUs: 1_000_000, frameNumber: 1)
        stats.recordReceivedFrame(bytes: 1, ptsUs: 1_010_000, frameNumber: 2)
        #expect(stats.windowHostDeltasMs == [10])
        stats.recordReceivedFrame(bytes: 1, ptsUs: 1_020_000, frameNumber: 4)   // frame 3 missing
        #expect(stats.windowHostDeltasMs == [10])
        stats.recordReceivedFrame(bytes: 1, ptsUs: 3_000_000, frameNumber: 5)   // 1.98 s jump
        #expect(stats.windowHostDeltasMs == [10])
    }
}
