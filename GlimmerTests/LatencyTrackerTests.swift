//
//  LatencyTrackerTests.swift
//  Latency histogram buckets, the in-flight frame map, cadence and trace lines.
//

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct LatencyTrackerTests {

    // MARK: - Histogram stage

    @Test func bucketsAreCumulativeAndTheSumAndCountTrackEveryObservation() {
        let stage = LatencyHistograms.Stage()
        stage.observe(0.1)   // exactly on the first bound
        stage.observe(0.3)   // first bound >= 0.3 is 0.5 (index 2)
        stage.observe(600)   // above every bound: only sum and count move
        let snap = stage.snapshot()
        #expect(snap.count == 3)
        #expect(abs(snap.sumMs - 600.4) < 1e-9)
        #expect(snap.buckets.count == LatencyHistograms.Stage.boundsMs.count)
        #expect(Array(snap.buckets.prefix(3)) == [1, 1, 2])
        #expect(snap.buckets.last == 2)
        #expect(snap.buckets == snap.buckets.sorted())
    }

    @Test func negativeAndNonFiniteObservationsAreIgnored() {
        let stage = LatencyHistograms.Stage()
        stage.observe(-0.001)
        stage.observe(.nan)
        stage.observe(.infinity)
        let snap = stage.snapshot()
        #expect(snap.count == UInt64.zero)
        #expect(snap.sumMs == 0)
        #expect(snap.buckets.allSatisfy { $0 == 0 })
        stage.observe(0)
        #expect(stage.snapshot().count == 1)
        #expect(stage.snapshot().buckets.first == 1)
    }

    @Test func aStageKeepsItsOwnBoundsAndSnapshotsThemIntoTheValue() {
        let stage = LatencyHistograms.Stage(bounds: [1, 5])
        stage.observe(1)
        stage.observe(2)
        stage.observe(9)
        let value = stage.snapshotValue()
        #expect(value.boundsMs == [1, 5])
        #expect(value.buckets == [1, 2])
        #expect(value.observationCount == 3)
        #expect(value.sumMs == 12)
        stage.reset()
        let cleared = stage.snapshot()
        #expect(cleared.buckets == [0, 0])
        #expect(cleared.count == UInt64.zero)
        #expect(cleared.sumMs == 0)
    }

    @Test func resetClearsEveryTrackedStage() {
        let hist = LatencyHistograms()
        let stages = [hist.receiveToAssemble, hist.assembleToSubmit, hist.submitToOutput,
                      hist.outputToPresent, hist.endToEnd, hist.glassToGlass,
                      hist.inputToPhoton, hist.decodeIDR, hist.decodeP, hist.idrRoundTrip]
        for stage in stages { stage.observe(4) }
        #expect(stages.allSatisfy { $0.snapshot().count == 1 })
        hist.reset()
        #expect(stages.allSatisfy { $0.snapshot().count == UInt64.zero && $0.snapshot().sumMs == 0 })
    }

    @Test func snapshotCarriesEachStagesObservationsAndBounds() {
        let hist = LatencyHistograms()
        hist.decodeIDR.observe(10)
        hist.glassToGlass.observe(25)
        let snap = hist.snapshot()
        #expect(snap.decodeIDR.observationCount == 1)
        #expect(snap.decodeP.observationCount == 0)
        #expect(snap.glassToGlass.boundsMs == LatencyHistograms.Stage.glassToGlassBoundsMs)
        #expect(snap.endToEnd.boundsMs == LatencyHistograms.Stage.outputToPresentBoundsMs)
        #expect(snap.glassToGlass.sumMs == 25)
    }

    // MARK: - In-flight map

    @Test func rtpTimestampZeroIsNeverTracked() {
        let tracker = FrameTimingTracker(sessionId: "t")
        tracker.recordAssembled(rtpTimestamp: 0, frameIndex: 1,
                                receiveNanos: 1_000_000_000, assembleNanos: 1_000_000_000)
        #expect(tracker.flushRemainingDrops(nowNanos: 100_000_000_000) == 0)
    }

    @Test func aPresentedFrameLeavesTheMapSoItIsNeverCountedAsADrop() {
        let tracker = FrameTimingTracker(sessionId: "t")
        tracker.recordAssembled(rtpTimestamp: 7, frameIndex: 1,
                                receiveNanos: 1_000_000_000, assembleNanos: 1_000_000_000)
        tracker.recordAssembled(rtpTimestamp: 8, frameIndex: 2,
                                receiveNanos: 1_000_000_001, assembleNanos: 1_000_000_001)
        tracker.recordPresent(rtpTimestamp: 7)
        tracker.recordPresent(rtpTimestamp: 999)   // unknown frame: no-op
        #expect(tracker.flushRemainingDrops(nowNanos: 100_000_000_000) == 1)
    }

    @Test func reassemblingTheSameTimestampReplacesTheEntryInsteadOfDuplicatingIt() {
        let tracker = FrameTimingTracker(sessionId: "t")
        for _ in 0..<3 {
            tracker.recordAssembled(rtpTimestamp: 5, frameIndex: 1,
                                    receiveNanos: 1_000_000_000, assembleNanos: 1_000_000_000)
        }
        #expect(tracker.flushRemainingDrops(nowNanos: 100_000_000_000) == 1)
    }

    @Test func theMapNeverHoldsMoreThan256FramesAndEvictsTheOldest() {
        let tracker = FrameTimingTracker(sessionId: "t")
        for index in 0..<300 {
            let nanos = 1_000_000_000 + UInt64(index)
            tracker.recordAssembled(rtpTimestamp: UInt32(index + 1), frameIndex: Int32(index),
                                    receiveNanos: nanos, assembleNanos: nanos)
        }
        #expect(tracker.flushRemainingDrops(nowNanos: 100_000_000_000) == 256)
        #expect(tracker.flushRemainingDrops(nowNanos: 100_000_000_000) == 0)
    }

    @Test func aFrameOlderThanTwoSecondsIsEvictedWhenTheNextOneArrives() {
        let tracker = FrameTimingTracker(sessionId: "t")
        tracker.recordAssembled(rtpTimestamp: 1, frameIndex: 1,
                                receiveNanos: 1_000_000_000, assembleNanos: 1_000_000_000)
        tracker.recordAssembled(rtpTimestamp: 2, frameIndex: 2,
                                receiveNanos: 3_000_000_000, assembleNanos: 3_000_000_000)
        // Frame 1 aged out at 3 s; frame 2 is still within its grace window.
        #expect(tracker.flushRemainingDrops(nowNanos: 3_500_000_000) == 0)
        #expect(tracker.flushRemainingDrops(nowNanos: 5_000_000_000) == 1)
    }

    // MARK: - Cadence

    @Test func cadenceObservesTheGapBetweenAssembledFramesAndSkipsStalls() {
        let tracker = FrameTimingTracker(sessionId: "t")
        for (index, nanos) in [100_000_000, 110_000_000, 120_000_000, 2_000_000_000].enumerated() {
            tracker.recordAssembled(rtpTimestamp: UInt32(index + 1), frameIndex: Int32(index),
                                    receiveNanos: UInt64(nanos), assembleNanos: UInt64(nanos))
        }
        for stage in [tracker.receiveCadence, tracker.assembleCadence] {
            let snap = stage.snapshot()
            // Two 10 ms gaps; the first frame has no predecessor and the 1.88 s stall is cut off.
            #expect(snap.count == 2)
            #expect(snap.sumMs == 20)
            let bound10 = FrameTimingTracker.cadenceBoundsMs.firstIndex(of: 10)
            #expect(snap.buckets[bound10 ?? 0] == 2)
            #expect(snap.buckets[(bound10 ?? 0) - 1] == 0)
        }
        #expect(tracker.outputCadence.snapshot().count == UInt64.zero)
    }

    @Test func hostFrameIntervalIsReadBackAsWritten() {
        let tracker = FrameTimingTracker(sessionId: "t")
        #expect(tracker.hostFrameIntervalMs == 0)
        tracker.hostFrameIntervalMs = 8.33
        #expect(tracker.hostFrameIntervalMs == 8.33)
    }

    // MARK: - IDR round trip

    @Test func idrRoundTripKeepsOnlyFiniteNonNegativeValues() {
        let tracker = FrameTimingTracker(sessionId: "t")
        tracker.recordIdrRoundTrip(frameIndex: 1, roundTripMs: 30)
        tracker.recordIdrRoundTrip(frameIndex: 2, roundTripMs: 0)
        tracker.recordIdrRoundTrip(frameIndex: 3, roundTripMs: -1)
        tracker.recordIdrRoundTrip(frameIndex: 4, roundTripMs: .nan)
        tracker.recordIdrRoundTrip(frameIndex: 5, roundTripMs: .infinity)
        let snap = tracker.histograms.idrRoundTrip.snapshot()
        #expect(snap.count == 2)
        #expect(snap.sumMs == 30)
    }

    // MARK: - Composites

    @Test func glassToGlassAddsHostEncodeHalfTheRttAndThePipeline() {
        let tracker = FrameTimingTracker(sessionId: "t")
        let counters = TelemetryCounters.shared
        let previous = counters.rttMs
        defer { counters.setRttMs(previous) }
        counters.setRttMs(8)
        #expect(tracker.computeGlassToGlass(hostEncodeMs: 4, pipelineMs: 10) == 18)
        #expect(tracker.computeGlassToGlass(hostEncodeMs: 0, pipelineMs: nil) == 4)
        counters.setRttMs(0)
        #expect(tracker.computeGlassToGlass(hostEncodeMs: 0, pipelineMs: nil) == nil)
        #expect(tracker.computeGlassToGlass(hostEncodeMs: 0, pipelineMs: 0) == 0)
    }

    @Test func composeClampsNegativeLegsRttAndHostIntervalToZero() {
        #expect(FrameTimingTracker.composeInputToPhoton(
            glassToGlassMs: 10, clientLegsMs: -5, rttMs: -8, hostFrameIntervalMs: -3) == 10)
    }

    @Test func inputToPhotonIsConsumedOncePerInputAndNeedsALaterPresent() {
        let tracker = FrameTimingTracker(sessionId: "t")
        let counters = TelemetryCounters.shared
        let previousRtt = counters.rttMs
        defer { counters.setRttMs(previousRtt) }
        counters.setRttMs(0)
        counters.noteInputEvent()
        let stamp = counters.lastInputNanos ?? 0
        #expect(stamp > 0)
        tracker.noteInputLegs(2)
        // A present before the input cannot answer it and does not consume it.
        #expect(tracker.computeInputToPhoton(presentNanos: stamp - 1, glassToGlassMs: 10,
                                             hostFrameIntervalMs: 0) == nil)
        #expect(tracker.computeInputToPhoton(presentNanos: stamp + 1, glassToGlassMs: 10,
                                             hostFrameIntervalMs: 8) == 16)
        #expect(tracker.computeInputToPhoton(presentNanos: stamp + 2, glassToGlassMs: 10,
                                             hostFrameIntervalMs: 8) == nil)
    }

    // MARK: - Trace lines

    @Test func traceLineListsEveryFieldInOrder() {
        let tracker = FrameTimingTracker(sessionId: "s1")
        let line = tracker.renderTraceLine(FrameTimingTracker.TraceRecord(
            frameIndex: 12, rtpTimestamp: 900, frameBytes: 4096, isIDR: true,
            presentUptimeMs: 1234.5, isResumePresent: true,
            receiveToAssemble: 0.5, assembleToSubmit: 1, submitToOutput: 2.25,
            outputToPresent: 3, endToEnd: 7, glassToGlass: 12.5, inputToPhoton: 20))
        #expect(line == "{\"session\":\"s1\",\"frame\":12,\"rtp\":900,\"bytes\":4096,\"type\":\"idr\","
            + "\"t_present_ms\":1234.500,\"resume\":true,\"recv_to_assemble_ms\":0.500,"
            + "\"assemble_to_submit_ms\":1,\"submit_to_output_ms\":2.250,\"output_to_present_ms\":3,"
            + "\"end_to_end_ms\":7,\"glass_to_glass_ms\":12.500,\"input_to_photon_est_ms\":20}")
    }

    @Test func traceLineOmitsMissingStagesZeroBytesAndNonFiniteValues() throws {
        let tracker = FrameTimingTracker(sessionId: "s1")
        let line = tracker.renderTraceLine(FrameTimingTracker.TraceRecord(
            frameIndex: 3, rtpTimestamp: 5, frameBytes: 0, isIDR: false,
            presentUptimeMs: 10, isResumePresent: false,
            receiveToAssemble: nil, assembleToSubmit: .nan, submitToOutput: .infinity,
            outputToPresent: 1, endToEnd: nil, glassToGlass: nil, inputToPhoton: nil))
        #expect(line == "{\"session\":\"s1\",\"frame\":3,\"rtp\":5,\"type\":\"p\","
            + "\"t_present_ms\":10,\"output_to_present_ms\":1}")
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(parsed?["bytes"] == nil)
    }

    @Test func dropStubNamesTheFurthestStageTheFrameReached() {
        let tracker = FrameTimingTracker(sessionId: "s1")
        func timing(submit: UInt64, output: UInt64, idr: Bool) -> FrameTimingTracker.Timing {
            var timing = FrameTimingTracker.Timing(
                frameIndex: 4, receiveNanos: 1, assembleNanos: 2_000_000, frameBytes: 0,
                isIDR: idr, hostEncodeMs: 0)
            timing.submitNanos = submit
            timing.outputNanos = output
            return timing
        }
        let lines = tracker.dropStubLines([
            (rtp: 1, timing: timing(submit: 0, output: 0, idr: false)),
            (rtp: 2, timing: timing(submit: 5, output: 0, idr: false)),
            (rtp: 3, timing: timing(submit: 5, output: 6, idr: true))
        ], hiddenNow: false, evictMs: 9)
        #expect(lines.count == 3)
        #expect(lines[0] == "{\"session\":\"s1\",\"event\":\"frame_drop\",\"frame\":4,\"rtp\":1,"
            + "\"type\":\"p\",\"stage\":\"assembled\",\"t_assemble_ms\":2,\"t_evict_ms\":9}")
        #expect(lines[1].contains("\"stage\":\"submitted\""))
        #expect(lines[2].contains("\"stage\":\"decoded\""))
        #expect(lines[2].contains("\"type\":\"idr\""))
    }

    @Test func bookmarkLineCarriesTheRunningTotalAndTheClock() {
        let tracker = FrameTimingTracker(sessionId: "s1")
        #expect(tracker.bookmarkLine(total: 3, uptimeNanos: 1_500_000_000)
            == "{\"session\":\"s1\",\"event\":\"bookmark\",\"bookmark_total\":3,\"t_ms\":1500}")
    }
}
