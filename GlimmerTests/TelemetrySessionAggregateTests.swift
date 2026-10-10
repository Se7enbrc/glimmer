// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetrySessionAggregateTests.swift
//
//  Session aggregation and the latency histograms under it: tick classification,
//  active-versus-raw statistics, worst windows, and the cumulative and rolling bucket math.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetrySessionAggregateTests {

    private typealias Fixtures = TelemetryRenderFixtures

    // MARK: Stat

    @Test func statTracksMinMaxAverageAndIgnoresNonFinite() {
        var stat = SessionAggregate.Stat()
        #expect(stat.avg == nil && stat.min == nil && stat.max == nil)
        for value in [30.0, 10.0, .nan, 20.0, .infinity] { stat.add(value) }
        #expect(stat.samples == 3)
        #expect(stat.min == 10 && stat.max == 30 && stat.avg == 20)
    }

    @Test func singleSampleIsItsOwnMinMaxAndAverage() {
        var stat = SessionAggregate.Stat()
        stat.add(7.5)
        #expect(stat.min == 7.5 && stat.max == 7.5 && stat.avg == 7.5)
    }

    // MARK: Tick classification

    @Test func ticksInTheFirstTenSecondsAreBringUpAndGatedWinsOverEverything() {
        var aggregate = SessionAggregate()
        #expect(aggregate.classifyTick(atSeconds: 0, hidden: false) == .bringUp)
        #expect(aggregate.classifyTick(atSeconds: 10, hidden: false) == .bringUp)
        #expect(aggregate.classifyTick(atSeconds: 10.5, hidden: false) == .active)
        #expect(aggregate.classifyTick(atSeconds: 4, hidden: true) == .gated)
        #expect(aggregate.bringUpTicks == 2 && aggregate.activeTicks == 1 && aggregate.gatedTicks == 1)
    }

    @Test func unhidingOpensAFiveSecondResumeCorridor() {
        var aggregate = SessionAggregate()
        #expect(aggregate.classifyTick(atSeconds: 30, hidden: true) == .gated)
        #expect(aggregate.classifyTick(atSeconds: 31, hidden: false) == .resume)
        #expect(aggregate.classifyTick(atSeconds: 35.9, hidden: false) == .resume)
        #expect(aggregate.classifyTick(atSeconds: 36, hidden: false) == .active)
        #expect(aggregate.resumeTicks == 2 && aggregate.activeTicks == 1 && aggregate.gatedTicks == 1)
    }

    @Test func aSteadySessionNeverEntersTheResumeCorridor() {
        var aggregate = SessionAggregate()
        let segments = (11...20).map { aggregate.classifyTick(atSeconds: Double($0), hidden: false) }
        #expect(segments.allSatisfy { $0 == .active })
        #expect(aggregate.resumeTicks == 0)
    }

    // MARK: Accumulate

    private func tick(
        _ aggregate: inout SessionAggregate, at seconds: Double, hidden: Bool = false,
        fps: Double? = nil, cadence: Double? = nil, depth: Int? = nil,
        histograms: LatencyHistogramSnapshot? = nil
    ) {
        var snap = TelemetrySnapshot()
        snap.sinceConnectSeconds = seconds
        snap.receivedFps = fps
        snap.decodedFps = fps.map { $0 - 1 }
        snap.renderedFps = fps.map { $0 - 2 }
        snap.presentCadenceErrorMs = cadence
        snap.pacingQueueDepth = depth
        snap.latencyHistograms = histograms
        let segment = aggregate.classifyTick(atSeconds: seconds, hidden: hidden)
        aggregate.accumulate(snap, segment: segment)
        if let histograms { aggregate.foldLatency(histograms, active: segment == .active) }
    }

    @Test func fpsStatsSplitActiveFromRawAndPeakDepthIsTheMaximum() throws {
        var aggregate = SessionAggregate()
        tick(&aggregate, at: 5, fps: 30, depth: 9)
        tick(&aggregate, at: 20, fps: 120, depth: 3)
        tick(&aggregate, at: 21, fps: 100, depth: 5)
        #expect(aggregate.tickCount == 3)
        #expect(aggregate.receivedFps.min == 100 && aggregate.receivedFps.max == 120)
        #expect(aggregate.receivedFps.avg == 110)
        #expect(aggregate.decodedFps.avg == 109)
        #expect(aggregate.renderedFps.avg == 108)
        #expect(aggregate.receivedFpsRaw.min == 30 && aggregate.receivedFpsRaw.samples == 3)
        let rawAverage = try #require(aggregate.receivedFpsRaw.avg)
        #expect(abs(rawAverage - 83.333) < 0.01)
        #expect(aggregate.peakPacingDepth == 9)
    }

    @Test func worstCadenceErrorKeepsRawAndActiveWindowsSeparately() {
        var aggregate = SessionAggregate()
        tick(&aggregate, at: 5, cadence: 9)
        tick(&aggregate, at: 20, cadence: 2)
        tick(&aggregate, at: 21, cadence: 1)
        #expect(aggregate.worstPresentCadenceErrorRawMs == 9)
        #expect(aggregate.worstPresentCadenceErrorRawAtSeconds == 5)
        #expect(aggregate.worstPresentCadenceErrorRawSegment == .bringUp)
        #expect(aggregate.worstPresentCadenceErrorMs == 2)
        #expect(aggregate.worstPresentCadenceErrorAtSeconds == 20)
    }

    @Test func gatedTicksCountTowardRawStatsOnly() {
        var aggregate = SessionAggregate()
        tick(&aggregate, at: 30, hidden: true, fps: 0, cadence: 50)
        #expect(aggregate.receivedFpsRaw.samples == 1 && aggregate.receivedFps.samples == 0)
        #expect(aggregate.worstPresentCadenceErrorRawSegment == .gated)
        #expect(aggregate.worstPresentCadenceErrorMs == nil)
    }

    @Test func worstGlassToGlassP95IsComputedFromPerTickDeltas() throws {
        let source = LatencyHistograms()
        var aggregate = SessionAggregate()
        for _ in 0..<10 { source.glassToGlass.observe(8) }
        tick(&aggregate, at: 5, histograms: source.snapshot())
        for _ in 0..<10 { source.glassToGlass.observe(100) }
        tick(&aggregate, at: 20, histograms: source.snapshot())
        tick(&aggregate, at: 21, histograms: source.snapshot())
        let early = try #require(aggregate.worstGlassToGlassP95RawMs)
        #expect(abs(early - 129.9) < 0.01)
        #expect(aggregate.worstGlassToGlassP95RawAtSeconds == 20)
        #expect(aggregate.worstGlassToGlassP95RawSegment == .active)
        #expect(aggregate.worstGlassToGlassP95AtSeconds == 20)
    }

    @Test func bringUpLatencySpikeStaysOutOfTheActiveWindow() throws {
        let source = LatencyHistograms()
        var aggregate = SessionAggregate()
        for _ in 0..<10 { source.glassToGlass.observe(100) }
        tick(&aggregate, at: 5, histograms: source.snapshot())
        for _ in 0..<10 { source.glassToGlass.observe(8) }
        tick(&aggregate, at: 20, histograms: source.snapshot())
        #expect(aggregate.worstGlassToGlassP95RawSegment == .bringUp)
        let active = try #require(aggregate.worstGlassToGlassP95Ms)
        #expect(abs(active - 7.9) < 0.01)
        #expect(aggregate.worstGlassToGlassP95AtSeconds == 20)
    }

    @Test func activeLatencyFoldsOnlyActiveDeltas() throws {
        let source = LatencyHistograms()
        var aggregate = SessionAggregate()
        for _ in 0..<4 { source.endToEnd.observe(2) }
        aggregate.foldLatency(source.snapshot(), active: false)
        #expect(aggregate.activeLatency == nil)
        for _ in 0..<3 { source.endToEnd.observe(2) }
        aggregate.foldLatency(source.snapshot(), active: true)
        #expect(aggregate.activeLatency?.endToEnd.observationCount == 3)
        aggregate.foldLatency(source.snapshot(), active: false)
        for _ in 0..<2 { source.endToEnd.observe(2) }
        aggregate.foldLatency(source.snapshot(), active: true)
        let folded = try #require(aggregate.activeLatency)
        #expect(folded.endToEnd.observationCount == 5)
        #expect(folded.endToEnd.sumMs == 10)
    }

    @Test func envStateSecondsIgnoreUnknownOrdinalsButKeepTheChangeTotal() {
        var aggregate = SessionAggregate()
        aggregate.noteEnvState(ordinal: 0, changesTotal: 0)
        aggregate.noteEnvState(ordinal: 1, changesTotal: 1)
        aggregate.noteEnvState(ordinal: 1, changesTotal: 1)
        aggregate.noteEnvState(ordinal: 7, changesTotal: 4)
        #expect(aggregate.envStateSeconds == [1, 2, 0])
        #expect(aggregate.envStateChangesTotal == 4)
    }

    // MARK: Histograms

    @Test func observationsLandInCumulativeBucketsWithInclusiveBounds() {
        let stage = LatencyHistograms.Stage()
        stage.observe(0.1)
        stage.observe(0.3)
        stage.observe(528)
        let captured = stage.snapshot()
        let bounds = LatencyHistograms.Stage.boundsMs
        #expect(captured.count == 3)
        #expect(captured.buckets[0] == 1)
        #expect(captured.buckets[bounds.firstIndex(of: 0.25) ?? 0] == 1)
        #expect(captured.buckets[bounds.firstIndex(of: 0.5) ?? 0] == 2)
        #expect(captured.buckets.last == 3)
        #expect(abs(captured.sumMs - 528.4) < 1e-9)
    }

    @Test func overflowBeyondTheTopBoundCountsOnlyInTheTotal() {
        let stage = LatencyHistograms.Stage()
        stage.observe(9_999)
        let captured = stage.snapshot()
        #expect(captured.count == 1 && captured.sumMs == 9_999)
        #expect(captured.buckets.allSatisfy { $0 == 0 })
    }

    @Test func invalidObservationsAreIgnored() {
        let stage = LatencyHistograms.Stage()
        for value in [-1.0, .nan, .infinity, -.infinity] { stage.observe(value) }
        #expect(stage.snapshot().count < 1 && stage.snapshot().sumMs == 0)
        stage.observe(0)
        #expect(stage.snapshot().count == 1 && stage.snapshot().buckets[0] == 1)
    }

    @Test func stagesUseTheirOwnBoundsAndResetClearsEverything() {
        let source = LatencyHistograms()
        #expect(source.glassToGlass.bounds == LatencyHistograms.Stage.glassToGlassBoundsMs)
        #expect(source.endToEnd.bounds == LatencyHistograms.Stage.outputToPresentBoundsMs)
        #expect(source.receiveToAssemble.bounds == LatencyHistograms.Stage.boundsMs)
        source.decodeIDR.observe(3)
        source.idrRoundTrip.observe(3)
        let before = source.snapshot()
        #expect(before.decodeIDR.observationCount == 1 && before.idrRoundTrip.observationCount == 1)
        #expect(before.idrRoundTrip.boundsMs == LatencyHistograms.Stage.glassToGlassBoundsMs)
        source.reset()
        let after = source.snapshot()
        #expect(!after.decodeIDR.hasObservations && !after.idrRoundTrip.hasObservations)
        #expect(after.decodeIDR.sumMs == 0 && after.decodeIDR.buckets.allSatisfy { $0 == 0 })
    }

    @Test func eachSnapshotFieldComesFromItsOwnStage() {
        let source = LatencyHistograms()
        source.receiveToAssemble.observe(1)
        source.assembleToSubmit.observe(1)
        source.assembleToSubmit.observe(1)
        source.submitToOutput.observe(1)
        source.outputToPresent.observe(1)
        source.endToEnd.observe(1)
        source.glassToGlass.observe(1)
        source.inputToPhoton.observe(1)
        source.decodeP.observe(1)
        let snap = source.snapshot()
        let counts = [snap.receiveToAssemble, snap.assembleToSubmit, snap.submitToOutput, snap.outputToPresent,
                      snap.endToEnd, snap.glassToGlass, snap.inputToPhoton, snap.decodeIDR, snap.decodeP,
                      snap.idrRoundTrip].map(\.observationCount)
        #expect(counts == [1, 2, 1, 1, 1, 1, 1, 0, 1, 0])
    }

    // MARK: Rolling window and differences

    @Test func differenceSubtractsBucketsSumAndCountAndClampsAfterAReset() {
        let old = Fixtures.histograms { for _ in 0..<4 { $0.endToEnd.observe(2) } }
        let new = Fixtures.histograms { for _ in 0..<10 { $0.endToEnd.observe(2) } }
        let delta = LatencyRollingWindow.difference(new, minus: old)
        #expect(delta.endToEnd.observationCount == 6 && delta.endToEnd.sumMs == 12)
        #expect(delta.endToEnd.buckets.last == 6)
        let reset = LatencyRollingWindow.difference(old, minus: new)
        #expect(reset.endToEnd.observationCount == 0 && reset.endToEnd.sumMs == 0)
        #expect(reset.endToEnd.buckets.allSatisfy { $0 == 0 })
    }

    @Test func differenceAndSumKeepTheFirstOperandWhenBucketLayoutsDiffer() {
        var odd = Fixtures.histograms { $0.endToEnd.observe(2) }
        odd.endToEnd = LatencyHistogramSnapshot.Stage(buckets: [1, 1], boundsMs: [1, 2], sumMs: 2, observationCount: 1)
        let normal = Fixtures.histograms { for _ in 0..<5 { $0.endToEnd.observe(2) } }
        #expect(LatencyRollingWindow.difference(normal, minus: odd).endToEnd.observationCount == 5)
        #expect(LatencyRollingWindow.sum(normal, plus: odd).endToEnd.observationCount == 5)
    }

    @Test func sumAddsEveryField() {
        let first = Fixtures.histograms { for _ in 0..<3 { $0.decodeP.observe(1) } }
        let second = Fixtures.histograms { for _ in 0..<2 { $0.decodeP.observe(3) } }
        let total = LatencyRollingWindow.sum(first, plus: second).decodeP
        #expect(total.observationCount == 5 && total.sumMs == 9)
        #expect(total.buckets.last == 5)
    }

    @Test func windowReturnsCumulativeUntilFullThenTheLastSixtyTicks() {
        let window = LatencyRollingWindow()
        let source = LatencyHistograms()
        var results: [UInt64] = []
        for _ in 0..<(LatencyRollingWindow.windowTicks + 2) {
            source.endToEnd.observe(2)
            results.append(window.advance(with: source.snapshot()).endToEnd.observationCount)
        }
        #expect(results[0] == 1)
        #expect(results[LatencyRollingWindow.windowTicks - 1] == 60)
        // Tick 61 differences against tick 1: 61 - 1 observations.
        #expect(results[LatencyRollingWindow.windowTicks] == 60)
        #expect(results[LatencyRollingWindow.windowTicks + 1] == 60)
    }
}
