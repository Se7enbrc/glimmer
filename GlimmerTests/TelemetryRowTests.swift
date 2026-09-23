//
//  TelemetryRowTests.swift
//
//  The per-second NDJSON row and the per-frame trace: which fields a row carries,
//  how host cadence and input latency are attributed, and what the trace keeps.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetryRowTests {

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

    @Test func bunchedHostFramesCountAsUnevenPairs() throws {
        // A ~60 fps game delivering frames in pairs: 28 ms, then 5 ms, repeated.
        let bunched = StatsCollector()
        var pts: UInt64 = 1_000_000
        for index in 0..<60 {
            pts += index.isMultiple(of: 2) ? 5_000 : 28_000
            bunched.recordReceivedFrame(bytes: 1_000, ptsUs: pts)
        }
        let cadence = try #require(bunched.snapshot().hostCadence)
        #expect(cadence.unevenPairs == 58)
        #expect(cadence.intervalP95Ms == 28)

        // A steady 120 fps host with one lost frame is not uneven delivery.
        let steady = StatsCollector()
        pts = 1_000_000
        for index in 0..<60 {
            pts += index == 30 ? 16_667 : 8_333
            steady.recordReceivedFrame(bytes: 1_000, ptsUs: pts)
        }
        #expect(steady.snapshot().hostCadence?.unevenPairs == 0)
    }

    @Test func latePresentsAreChargedToTheHostOnlyWhenItsTimingExplainsThem() throws {
        let stats = StatsCollector()
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000)
        stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_008_333)
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
            stats.recordReceivedFrame(bytes: 1_000, ptsUs: 1_000_000 + UInt64(frame) * 8_333)
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

    @Test func hostFrameIntervalFollowsAssembledFramesAcrossTheRtpWrap() {
        let tracker = FrameTimingTracker(sessionId: "test")
        var rtp = UInt32.max - 3_000
        for index in 0..<40 {
            let nanos = UInt64(index + 1) * 8_333_333
            tracker.recordAssembled(rtpTimestamp: rtp, frameIndex: Int32(index),
                                    receiveNanos: nanos, assembleNanos: nanos)
            rtp &+= 750   // 8.33 ms on the 90 kHz clock
        }
        #expect(abs(tracker.hostFrameIntervalMs - 1_000.0 / 120.0) < 0.01)
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
}
