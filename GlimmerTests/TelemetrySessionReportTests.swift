// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetrySessionReportTests.swift
//
//  The end-of-session JSON report: schema and identity, segment and fps statistics, the
//  latency sections, event counters, handshake and lifecycle legs, and the worst windows.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetrySessionReportTests {

    private typealias Fixtures = TelemetryRenderFixtures

    private func report(
        aggregate: SessionAggregate = SessionAggregate(),
        histograms: LatencyHistogramSnapshot? = nil,
        counters: TelemetryCounters = TelemetryCounters(),
        wide: [(String, LatencyHistogramSnapshot.Stage)] = []
    ) -> SessionReport {
        SessionReport(
            sessionId: "abcd1234", client: "c1ent\"x", host: "deadbeef", buildCommit: "abc123",
            buildDate: "2026-10-10", generatedISO8601: "2026-10-10T12:30:00Z", durationSeconds: 61.25,
            aggregate: aggregate, histograms: histograms, counters: counters, sessionWideStages: wide)
    }

    private func json(_ report: SessionReport) throws -> [String: Any] {
        let text = report.renderJSON()
        #expect(text.hasSuffix("}\n") && !text.dropLast().contains("\n"))
        return try Fixtures.row(text)
    }

    private func object(_ root: [String: Any], _ key: String) throws -> [String: Any] {
        try #require(root[key] as? [String: Any])
    }

    private func number(_ dict: [String: Any], _ key: String) -> Double? {
        (dict[key] as? NSNumber)?.doubleValue
    }

    @Test func headerCarriesSchemaIdentityBuildAndDuration() throws {
        let root = try json(report())
        #expect(root["schema"] as? String == "glimmer.session_report.v1")
        #expect(root["session"] as? String == "abcd1234")
        #expect(root["client"] as? String == "c1ent\"x")
        #expect(root["host"] as? String == "deadbeef")
        #expect(root["generated"] as? String == "2026-10-10T12:30:00Z")
        let build = try object(root, "build")
        #expect(build["commit"] as? String == "abc123" && build["date"] as? String == "2026-10-10")
        #expect(number(root, "duration_s") == 61.25)
        #expect(number(root, "ticks") == 0)
    }

    @Test func emptySessionRendersEmptyStatsAndLatencyObjects() throws {
        let root = try json(report())
        for key in ["fps", "fps_raw", "latency", "latency_raw", "worst_windows", "ctrl_ignored_by_type"] {
            #expect(try object(root, key).isEmpty, "\(key) should be empty")
        }
        #expect(root["latency_basis"] as? String == "all_session")
        #expect(number(root, "peak_pacing_depth") == 0)
        let segments = try object(root, "segments")
        #expect(["active_s", "gated_s", "bring_up_s", "resume_s"].allSatisfy { number(segments, $0) == 0 })
    }

    @Test func segmentsAndFpsReflectTheAggregate() throws {
        var aggregate = SessionAggregate()
        for (second, hidden, fps) in [(5.0, false, 30.0), (20, false, 120), (21, false, 100), (30, true, 0)] {
            var snap = TelemetrySnapshot()
            snap.sinceConnectSeconds = second
            snap.receivedFps = fps
            snap.pacingQueueDepth = Int(second) % 7
            let segment = aggregate.classifyTick(atSeconds: second, hidden: hidden)
            aggregate.accumulate(snap, segment: segment)
        }
        let root = try json(report(aggregate: aggregate))
        #expect(number(root, "ticks") == 4)
        let segments = try object(root, "segments")
        #expect(number(segments, "active_s") == 2 && number(segments, "bring_up_s") == 1)
        #expect(number(segments, "gated_s") == 1 && number(segments, "resume_s") == 0)
        let fps = try object(try object(root, "fps"), "received")
        #expect(number(fps, "min") == 100 && number(fps, "avg") == 110 && number(fps, "max") == 120)
        let raw = try object(try object(root, "fps_raw"), "received")
        #expect(number(raw, "min") == 0 && number(raw, "avg") == 62.5 && number(raw, "max") == 120)
        #expect(try object(root, "fps")["decoded"] == nil)
        #expect(number(root, "peak_pacing_depth") == 6)
    }

    @Test func latencySectionsReportPercentilesAndCountsOnlyForStagesWithData() throws {
        let histograms = Fixtures.histograms {
            for _ in 0..<10 {
                $0.receiveToAssemble.observe(1)
                $0.glassToGlass.observe(8)
            }
        }
        let root = try json(report(histograms: histograms))
        #expect(root["latency_basis"] as? String == "all_session")
        for key in ["latency", "latency_raw"] {
            let latency = try object(root, key)
            #expect(Set(latency.keys) == ["recv_to_assemble", "glass_to_glass"])
            let assemble = try object(latency, "recv_to_assemble")
            #expect(number(assemble, "count") == 10)
            #expect(abs((number(assemble, "p50_ms") ?? 0) - 0.875) < 0.002)
            #expect(abs((number(assemble, "p95_ms") ?? 0) - 0.9875) < 0.002)
            #expect(abs((number(assemble, "p99_ms") ?? 0) - 0.9975) < 0.002)
            let glass = try object(latency, "glass_to_glass")
            #expect(abs((number(glass, "p50_ms") ?? 0) - 7) < 0.002)
        }
    }

    @Test func activeLatencyReplacesAllSessionLatencyAndRawKeepsTheWholeRun() throws {
        let source = LatencyHistograms()
        var aggregate = SessionAggregate()
        for _ in 0..<4 { source.endToEnd.observe(2) }
        aggregate.foldLatency(source.snapshot(), active: false)
        for _ in 0..<3 { source.endToEnd.observe(2) }
        aggregate.foldLatency(source.snapshot(), active: true)
        let root = try json(report(aggregate: aggregate, histograms: source.snapshot()))
        #expect(root["latency_basis"] as? String == "active_seconds")
        #expect(number(try object(try object(root, "latency"), "end_to_end"), "count") == 3)
        #expect(number(try object(try object(root, "latency_raw"), "end_to_end"), "count") == 7)
    }

    @Test func sessionWideStagesAppearOnlyInTheRawLatencyObject() throws {
        let wide = [("reorder_x", Fixtures.stage(1)), ("empty_x", Fixtures.stage(1, count: 0))]
        let root = try json(report(histograms: Fixtures.histograms(), wide: wide))
        #expect(try object(root, "latency_raw").keys.sorted() == ["reorder_x"])
        #expect(try object(root, "latency").isEmpty)
        #expect(number(try object(try object(root, "latency_raw"), "reorder_x"), "count") == 10)
    }

    @Test func eventsObjectMapsEachCounterToItsOwnKey() throws {
        let counters = TelemetryCounters()
        counters.rfiTotal.increment(by: 3)
        counters.idrRequestedTotal.increment(by: 4)
        counters.frameLossTotal.increment(by: 5)
        counters.videoPacketsLostPreFecTotal.increment(by: 6)
        counters.enetRetransmitTotal.increment(by: 7)
        counters.audioUnderrunTotal.increment(by: 8)
        counters.reconnectTotal.increment(by: 2)
        counters.wakeTotal.increment(by: 1)
        counters.tickMissLinkskipTotal.increment(by: 9)
        counters.videoGapOver100msTotal.increment(by: 10)
        let events = try object(try json(report(counters: counters)), "events")
        #expect(number(events, "rfi") == 3 && number(events, "idr_requested") == 4)
        #expect(number(events, "frame_loss") == 5 && number(events, "pre_fec_packets_lost") == 6)
        #expect(number(events, "enet_retransmit") == 7 && number(events, "audio_underrun") == 8)
        #expect(number(events, "reconnect") == 2 && number(events, "wake") == 1)
        #expect(number(events, "tick_miss_linkskip") == 9 && number(events, "net_gaps_over_100ms") == 10)
        #expect(number(events, "present_stall") == 0)
        #expect(events.count == 49)
    }

    @Test func reorderDisplacementReportsGaugeAndExceededCount() throws {
        let counters = TelemetryCounters()
        var reorder = try object(try json(report(counters: counters)), "reorder_displacement")
        #expect(reorder["hold_ms"] == nil && number(reorder, "hold_exceeded") == 0)
        counters.setReorderDisplacement(.init(maxMs: 6.5, maxPackets: 14, holdMs: 10))
        counters.reorderHoldExceededTotal.increment(by: 2)
        reorder = try object(try json(report(counters: counters)), "reorder_displacement")
        #expect(number(reorder, "hold_ms") == 10 && number(reorder, "max_ms") == 6.5)
        #expect(number(reorder, "max_packets") == 14 && number(reorder, "hold_exceeded") == 2)
    }

    @Test func handshakeLegsComeFromTheRecordedConnectMarks() throws {
        let counters = TelemetryCounters()
        counters.p2.anchorConnectStart(1_000_000_000)
        counters.p2.markRtspStart(1_100_000_000)
        counters.p2.markRtspDone(1_220_500_000)
        counters.p2.markEnetStart(1_235_500_000)
        counters.p2.markFirstFrame(1_425_750_000)
        let handshake = try object(try json(report(counters: counters)), "handshake")
        #expect(number(handshake, "rtsp_ms") == 120.5)
        #expect(number(handshake, "control_setup_ms") == 15)
        #expect(number(handshake, "total_ms") == 425.75)
        #expect(handshake["reconnect_last"] == nil)
    }

    @Test func afterAReconnectTheFirstConnectIsKeptAndTheLastLegsNest() throws {
        let counters = TelemetryCounters()
        counters.p2.anchorConnectStart(1_000_000_000)
        counters.p2.markRtspStart(1_100_000_000)
        counters.p2.markRtspDone(1_220_500_000)
        counters.p2.anchorReconnect(
            2_000_000_000, audioTtfMs: 250,
            audioTtf: AudioTtfContext.Record(ttfClass: "warm", pingToRtpMs: 12, hostIdleSeconds: 30, startup: "paced"))
        counters.p2.markRtspStart(2_100_000_000)
        counters.p2.markRtspDone(2_150_000_000)
        let root = try json(report(counters: counters))
        let handshake = try object(root, "handshake")
        #expect(number(handshake, "rtsp_ms") == 120.5)
        #expect(number(try object(handshake, "reconnect_last"), "rtsp_ms") == 50)
        let audio = try object(root, "audio_ttf")
        #expect(number(audio, "ttf_ms") == 250 && audio["ttf_class"] as? String == "warm")
        #expect(number(audio, "ping_to_rtp_ms") == 12 && number(audio, "host_idle_s") == 30)
        #expect(audio["startup"] as? String == "paced")
    }

    @Test func lifecycleReportsDisconnectReasonAndIdrRoundTrip() throws {
        let counters = TelemetryCounters()
        counters.p2.setDisconnectReason(.watchdogStall)
        counters.p2.setDisconnectReason(.userStopped)
        counters.reconnectTotal.increment(by: 2)
        counters.wakeTotal.increment()
        counters.idrRoundTripRequestTotal.increment(by: 3)
        counters.idrRoundTripMatchedTotal.increment(by: 2)
        var lifecycle = try object(try json(report(counters: counters)), "lifecycle")
        #expect(number(lifecycle, "disconnect_reason") == 4)
        #expect(lifecycle["disconnect_reason_label"] as? String == "watchdog_stall")
        #expect(number(lifecycle, "reconnects") == 2 && number(lifecycle, "wakes") == 1)
        #expect(number(lifecycle, "idr_round_trip_requests") == 3 && number(lifecycle, "idr_round_trip_matched") == 2)
        #expect(lifecycle["idr_round_trip_last_ms"] == nil)
        counters.p2.stampIdrRequest(1_000_000_000)
        _ = counters.p2.resolveIdrArrival(1_022_500_000)
        lifecycle = try object(try json(report(counters: counters)), "lifecycle")
        #expect(number(lifecycle, "idr_round_trip_last_ms") == 22.5)
    }

    @Test func audioTtfSaysNeverUntilAnAudioPacketArrives() throws {
        let counters = TelemetryCounters()
        let never = try object(try json(report(counters: counters)), "audio_ttf")
        #expect(never["never"] as? Bool == true && never["pings"] != nil)
        counters.audioPacketsTotal.increment()
        let seen = try object(try json(report(counters: counters)), "audio_ttf")
        #expect(seen["never"] == nil)
    }

    @Test func ignoredControlTypesAreListedInHexSortedByType() throws {
        let counters = TelemetryCounters()
        counters.noteCtrlIgnored(type: 0x010b)
        counters.noteCtrlIgnored(type: 0x010b)
        counters.noteCtrlIgnored(type: 0x0007)
        let root = try json(report(counters: counters))
        let ignored = try object(root, "ctrl_ignored_by_type")
        #expect(ignored["0x010b"] as? Int == 2 && ignored["0x0007"] as? Int == 1)
        let text = report(counters: counters).renderJSON()
        let low = try #require(text.range(of: "0x0007"))
        let high = try #require(text.range(of: "0x010b"))
        #expect(low.lowerBound < high.lowerBound)
        #expect(number(try object(root, "events"), "ctrl_ignored") == 3)
    }

    @Test func envSecondsAndWorstWindowsComeFromTheAggregate() throws {
        var aggregate = SessionAggregate()
        aggregate.noteEnvState(ordinal: 0, changesTotal: 0)
        aggregate.noteEnvState(ordinal: 2, changesTotal: 1)
        aggregate.noteEnvState(ordinal: 2, changesTotal: 1)
        var snap = TelemetrySnapshot()
        snap.sinceConnectSeconds = 5
        snap.presentCadenceErrorMs = 9
        aggregate.accumulate(snap, segment: .bringUp)
        snap.sinceConnectSeconds = 20
        snap.presentCadenceErrorMs = 2.5
        aggregate.accumulate(snap, segment: .active)
        let root = try json(report(aggregate: aggregate))
        let env = try object(root, "env")
        #expect(number(env, "clear_s") == 1 && number(env, "caution_s") == 0 && number(env, "distress_s") == 2)
        #expect(number(env, "state_changes") == 1)
        #expect(env["pings_sent_video"] != nil && env["pings_sent_audio"] != nil)
        let worst = try object(root, "worst_windows")
        let active = try object(worst, "present_cadence_error")
        #expect(number(active, "value_ms") == 2.5 && number(active, "at_t_connect_s") == 20)
        #expect(active["segment"] == nil)
        let raw = try object(worst, "present_cadence_error_raw")
        #expect(number(raw, "value_ms") == 9 && number(raw, "at_t_connect_s") == 5)
        #expect(raw["segment"] as? String == "bring_up")
        #expect(worst["glass_to_glass_p95"] == nil)
    }
}
