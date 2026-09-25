//
//  TelemetryRowTests.swift
//
//  The per-second NDJSON row and the per-frame trace: which fields a row carries,
//  how host cadence and input latency are attributed, and what the trace keeps.
//

import Foundation
import QuartzCore
import Testing
import os
@testable import Glimmer

struct TelemetryRowTests {

    @Test func jsonNumbersKeepThreeDecimalPlaces() {
        let cases: [(Double, String)] = [
            (0.5, "0.500"), (1.049, "1.049"), (-0.5, "-0.500"),
            (-1.25, "-1.250"), (12, "12"),
            (100_000_000_000_000.5, "100000000000000.500"),
            (1e16, String(format: "%.3f", 1e16))
        ]
        for (value, expected) in cases {
            #expect(TelemetryRenderer.jsonNumber(value) == expected)
        }
    }

    @Test func oldDropExpiresWhileNewFrameRemains() {
        let old = FrameTimingTracker.Timing(frameIndex: 1, receiveNanos: 1,
            assembleNanos: 1_000_000_000, frameBytes: 0, isIDR: false,
            hostEncodeMs: 0, assembledHidden: false)
        let new = FrameTimingTracker.Timing(frameIndex: 2, receiveNanos: 4_000_000_000,
            assembleNanos: 4_000_000_000, frameBytes: 0, isIDR: false,
            hostEncodeMs: 0, assembledHidden: false)
        #expect(FrameTimingTracker.expiredDropCount(order: [1, 2], timings: [1: old, 2: new],
                                                    nowNanos: 4_000_000_000) == 1)
    }

    @Test func shutdownDropsOnlyExpiredFrames() {
        let tracker = FrameTimingTracker(sessionId: "test")
        tracker.recordAssembled(rtpTimestamp: 1, frameIndex: 1,
                                receiveNanos: 1_000_000_000, assembleNanos: 1_000_000_000)
        tracker.recordAssembled(rtpTimestamp: 2, frameIndex: 2,
                                receiveNanos: 2_000_000_000, assembleNanos: 2_000_000_000)

        #expect(tracker.flushRemainingDrops(nowNanos: 3_500_000_000) == 1)
        #expect(tracker.flushRemainingDrops(nowNanos: 3_500_000_000) == 0)
        #expect(tracker.flushRemainingDrops(nowNanos: 4_500_000_000) == 1)
    }

    @Test func audioCushionRenderersUseTheCapturedValues() throws {
        var extras = TelemetrySnapshot.Extras()
        extras.audioCushionFloorMs = 17
        extras.audioCushionSeedMs = 43

        var snap = TelemetrySnapshot()
        snap.audio = AudioSnapshot()
        let prom = TelemetryRenderer.prometheus(snap, extras: extras)
        let ndjson = TelemetryRenderer.ndjson(snap, extras: extras)
        let row = try #require(try JSONSerialization.jsonObject(with: Data(ndjson.utf8)) as? [String: Any])

        #expect(prom.contains("glimmer_audio_cushion_floor_ms") && prom.contains(" 17\n"))
        #expect(prom.contains("glimmer_audio_cushion_seed_ms") && prom.contains(" 43\n"))
        #expect((row["audio_cushion_floor_ms"] as? NSNumber)?.doubleValue == 17)
        #expect((row["audio_cushion_seed_ms"] as? NSNumber)?.doubleValue == 43)
    }

    @Test func telemetryConnectionSlotsRejectAndRecoverCapacity() {
        let connections = (0..<9).map { _ in NSObject() }
        var slots = TelemetryConnectionSlots()
        for connection in connections.prefix(8) {
            let reserved = slots.reserve(ObjectIdentifier(connection))
            #expect(reserved)
        }
        #expect(slots.count == 8)
        let ninthReserved = slots.reserve(ObjectIdentifier(connections[8]))
        #expect(!ninthReserved)

        slots.release(ObjectIdentifier(connections[0]))
        let reusedAfterFinish = slots.reserve(ObjectIdentifier(connections[8]))
        #expect(reusedAfterFinish)
        #expect(slots.count == 8)

        slots.release(ObjectIdentifier(connections[1]))
        let reusedAfterExpiry = slots.reserve(ObjectIdentifier(connections[0]))
        #expect(reusedAfterExpiry)
        #expect(slots.count == 8)
    }

    // MARK: - NDJSON row

    @Test func rowCarriesTheAttributionFieldsAndDropsTheRetiredFecGauges() throws {
        var snap = TelemetrySnapshot()
        snap.fecPercentage = 20
        snap.reorderHoldTakenTotal = 7
        snap.reorderHoldRescuedTotal = 3
        snap.awdlSuppressing = true
        snap.awdlReSuppressTotal = 2
        snap.udpFullSockDelta = 5
        snap.dropsRecoveryWaitTotal = 13
        snap.presentLateHostCadenceCount = 9
        snap.hostFrameIntervalP50Ms = 5
        snap.hostFrameIntervalP95Ms = 28
        snap.hostUnevenPairs = 58
        snap.inputMotionPerSecond = 64
        let queueToWire = LatencyHistograms.Stage()
        queueToWire.observe(0.6)
        snap.latencyHistograms = LatencyHistograms().snapshot()
        snap.inputLocalLatency = queueToWire.snapshotValue()

        let line = TelemetryRenderer.ndjson(snap, extras: TelemetrySnapshot.Extras())
        let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        let expected: [String: Double] = [
            "reorder_hold_taken_total": 7, "reorder_hold_rescued_total": 3,
            "awdl_resuppress_total": 2, "udp_fullsock_delta": 5,
            "drops_recovery_wait_total": 13, "present_late_host_cadence": 9,
            "host_frame_interval_p50_ms": 5, "host_frame_interval_p95_ms": 28,
            "host_uneven_pairs": 58, "input_motion_per_s": 64
        ]
        for (key, value) in expected {
            #expect((row[key] as? NSNumber)?.doubleValue == value, "\(key)")
        }
        #expect(row["awdl_suppressing"] as? Bool == true)
        #expect(row["lat_input_queue_to_wire_p50_ms"] != nil)
        for retired in ["fec_reorder_hold_ms", "fec_headroom_level", "fec_loss_level"] {
            #expect(row[retired] == nil, "\(retired)")
        }
    }

    @Test func kernelUdpFullSocketCounterIsReadable() {
        #expect(TelemetryExporter.udpFullSockTotal() != nil)
    }

    // MARK: - Host cadence (StatsCollector)

    @Test @MainActor func stallRecreateDrainsPendingDecodeSubmits() async {
        let decoder = VideoDecoder()
        for _ in 0..<5 {
            let state = OSSignposter.decode.beginInterval("DecodeFrame")
            decoder.statsCollector.recordDecodeSubmit(intervalState: state)
        }
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 5
        decoder.releaseInFlightDecode(vtFailed: true)

        #expect(decoder.reserveDecodeSlot(isIDR: true) == .reservedForStallRecreate)
        await decoder.decodeQueue.drainForTest()
        #expect(decoder.statsCollector.submitFifo.isEmpty)
    }

    @Test func bunchedHostFramesCountAsUnevenPairs() throws {
        // A ~60 fps game delivering frames in pairs: 28 ms, then 5 ms, repeated.
        let bunched = StatsCollector()
        var pts: UInt64 = 1_000_000
        for index in 0..<60 {
            pts += index.isMultiple(of: 2) ? 5_000 : 28_000
            bunched.recordReceivedFrame(bytes: 1_000, ptsUs: pts, frameNumber: Int32(index))
        }
        let cadence = try #require(bunched.snapshot().hostCadence)
        #expect(cadence.unevenPairs == 58)
        #expect(cadence.intervalP95Ms == 28)

        // A steady 120 fps host with one lost frame is not uneven delivery.
        let steady = StatsCollector()
        pts = 1_000_000
        for index in 0..<60 {
            pts += index == 30 ? 16_667 : 8_333
            steady.recordReceivedFrame(bytes: 1_000, ptsUs: pts, frameNumber: Int32(index))
        }
        #expect(steady.snapshot().hostCadence?.unevenPairs == 0)
    }

    @Test func missingNetworkFramesDoNotBecomeHostCadence() throws {
        let stats = StatsCollector()
        for frame in 0..<4 {
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 8_333,
                                      frameNumber: Int32(frame))
        }
        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 1.025,
                            streamIntervalMs: 8.333, refreshMs: 8.333)

        for frame in 7..<11 {
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 8_333,
                                      frameNumber: Int32(frame))
        }
        stats.recordPresent(cadenceErrorMs: 25, hostPTSSeconds: 1.058331,
                            streamIntervalMs: 8.333, refreshMs: 8.333)

        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.unevenPairs == 0)
        #expect(cadence.intervalP95Ms < 9)
        #expect(cadence.lateByHostPercent == 0)
    }

    @Test func queuedPresentBeforeNetworkGapDoesNotConsumeItsAttribution() throws {
        let stats = StatsCollector()
        for frame in 1...3 {
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 8_333,
                                      frameNumber: Int32(frame))
        }
        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 1.016666,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_058_331, frameNumber: 7)
        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 1.024999,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        stats.recordPresent(cadenceErrorMs: 25, hostPTSSeconds: 1.058331,
                            streamIntervalMs: 8.333, refreshMs: 8.333)

        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.lateByHostPercent == 0)
    }

    @Test func networkGapsStayBoundedWithoutPresents() throws {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000, frameNumber: 0)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_008_333, frameNumber: 1)
        for frame in 1...2_000 {
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 28_000,
                                      frameNumber: Int32(frame * 2 + 1))
        }
        #expect(stats.pendingNetworkGapCount == StatsCollector.networkGapCapacity)
        #expect(stats.pendingNetworkGapPtsSeconds.count == StatsCollector.networkGapCapacity)

        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 56.972,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        stats.recordPresent(cadenceErrorMs: 25, hostPTSSeconds: 57.0,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.lateByHostPercent == 0)
        #expect(stats.pendingNetworkGapCount == 0)
    }

    @Test func backwardPtsClearsPendingNetworkGaps() throws {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 9_900_000, frameNumber: 0)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 10_000_000, frameNumber: 2)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000, frameNumber: 3)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_008_333, frameNumber: 4)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_028_000, frameNumber: 6)
        #expect(stats.pendingNetworkGapCount == 1)

        stats.recordPresent(cadenceErrorMs: 0, hostPTSSeconds: 1.0,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        stats.recordPresent(cadenceErrorMs: 25, hostPTSSeconds: 1.028,
                            streamIntervalMs: 8.333, refreshMs: 8.333)
        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.lateByHostPercent == 0)
        #expect(stats.pendingNetworkGapCount == 0)
    }

    @Test func latePresentsAreChargedToTheHostOnlyWhenItsTimingExplainsThem() throws {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000, frameNumber: 0)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_008_333, frameNumber: 1)
        func present(errorMs: Double, pts: Double) {
            stats.recordPresent(cadenceErrorMs: errorMs, hostPTSSeconds: pts,
                                streamIntervalMs: 8.333, refreshMs: 8.333)
        }
        present(errorMs: 0, pts: 1.000)
        present(errorMs: 5, pts: 1.008333)   // host on the grid, shown late: the client's
        present(errorMs: 0, pts: 1.013333)   // bunched 5 ms, but one refresh later is on time
        present(errorMs: 20, pts: 1.041333)  // a 28 ms host gap: the host's
        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.lateByHostPercent == 25)
    }

    @Test func aPresentAfterAClientSkipIsNeverChargedToTheHost() throws {
        // A steady 120 fps host on a 120 Hz display; the pacer trims one frame.
        let stats = StatsCollector()
        for frame in 0..<4 {
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 8_333,
                                      frameNumber: Int32(frame))
        }
        func present(errorMs: Double, pts: Double) {
            stats.recordPresent(cadenceErrorMs: errorMs, hostPTSSeconds: pts,
                                streamIntervalMs: 8.333, refreshMs: 8.333)
        }
        present(errorMs: 0, pts: 1.000)
        present(errorMs: 0, pts: 1.008333)
        stats.recordPresentationLateDrop()
        present(errorMs: 8.33, pts: 1.025)   // a missed vsync: the 16.67 ms delta is the client's
        let cadence = try #require(stats.snapshot().hostCadence)
        #expect(cadence.lateByHostPercent == 0)
    }

    // MARK: - Latency tracker

    /// Input-to-photon's host interval is the stats window's p50, published once a
    /// second; assembled frames' RTP deltas no longer keep a second estimate.
    @Test func hostFrameIntervalHasOneSource() {
        let tracker = FrameTimingTracker(sessionId: "test")
        tracker.hostFrameIntervalMs = 1_000.0 / 120.0
        for index in 0..<40 {
            let nanos = UInt64(index + 1) * 16_666_667
            tracker.recordAssembled(rtpTimestamp: 1 + UInt32(index) * 1_500, frameIndex: Int32(index),
                                    receiveNanos: nanos, assembleNanos: nanos)
        }
        #expect(tracker.hostFrameIntervalMs == 1_000.0 / 120.0)
    }

    @Test func inputToPhotonAddsTheInputLegsToGlassToGlass() {
        // Glass-to-glass 18.8 ms, 1.2 ms of client legs, 3 ms RTT, 120 fps host.
        let estimate = FrameTimingTracker.composeInputToPhoton(
            glassToGlassMs: 18.8, clientLegsMs: 1.2, rttMs: 3, hostFrameIntervalMs: 1_000.0 / 120.0)
        #expect(abs(estimate - (18.8 + 1.2 + 1.5 + 1_000.0 / 240.0)) < 0.001)
        // Legs not measured yet add nothing: it never reads below glass-to-glass.
        #expect(FrameTimingTracker.composeInputToPhoton(
            glassToGlassMs: 18.8, clientLegsMs: 0, rttMs: 0, hostFrameIntervalMs: 0) == 18.8)
    }

    @Test func dropStubsSkipFramesAssembledWhileTheWindowWasHidden() {
        let tracker = FrameTimingTracker(sessionId: "test")
        func timing(_ frame: Int32, hidden: Bool) -> FrameTimingTracker.Timing {
            FrameTimingTracker.Timing(frameIndex: frame, receiveNanos: 1, assembleNanos: 2,
                                      frameBytes: 0, isIDR: false, hostEncodeMs: 0,
                                      assembledHidden: hidden)
        }
        let evicted = [(rtp: UInt32(10), timing: timing(1, hidden: true)),
                       (rtp: UInt32(20), timing: timing(2, hidden: false))]
        let lines = tracker.dropStubLines(evicted, hiddenNow: false, evictMs: 5)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("\"frame\":2,") == true)
        #expect(lines.first?.contains("\"t_assemble_ms\":0.000,") == true)
        #expect(tracker.dropStubLines(evicted, hiddenNow: true, evictMs: 5).isEmpty)
    }

    // MARK: - Input trace

    @Test func motionTraceIsCappedAt20HzButAGyroNullAlwaysTraces() {
        let base: UInt64 = 10_000_000_000
        var last: UInt64 = 0
        var traced = 0
        for millisecond in 1...1_000 {   // a 1 kHz sensor for one second
            let now = base + UInt64(millisecond) * 1_000_000
            if InputBatcher.motionTraceDue(lastNanos: last, nowNanos: now, isGyroNull: false) {
                last = now
                traced += 1
            }
        }
        #expect(traced == 20)
        #expect(InputBatcher.motionTraceDue(lastNanos: last, nowNanos: last + 1, isGyroNull: true))
    }

    @Test func bookmarkRowSitsOnTheInputRowsClock() throws {
        let tracker = FrameTimingTracker(sessionId: "test")
        let line = tracker.bookmarkLine(total: 3, uptimeNanos: 92_230_141_830_000)
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(row["event"] as? String == "bookmark")
        #expect(row["bookmark_total"] as? Int == 3)
        // Input rows stamp `t_ms` as uptime in milliseconds; a bookmark must read the same.
        #expect(abs((row["t_ms"] as? Double ?? 0) - 92_230_141.83) < 0.001)
    }
}
