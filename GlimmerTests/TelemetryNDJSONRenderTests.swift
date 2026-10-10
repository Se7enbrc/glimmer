// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryNDJSONRenderTests.swift
//
//  The per-second NDJSON row: every field a fully populated snapshot renders, what a
//  sparse one omits, the latency percentile fields, escaping, and number formatting.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetryNDJSONRenderTests {

    private typealias Fixtures = TelemetryRenderFixtures

    private func fullRow() throws -> [String: Any] {
        try Fixtures.row(TelemetryRenderer.ndjson(Fixtures.snapshot(), extras: Fixtures.extras()))
    }

    private func check(_ row: [String: Any], _ expected: [String: Double]) {
        for (key, want) in expected {
            let got = (row[key] as? NSNumber)?.doubleValue
            #expect(got != nil && abs((got ?? 0) - want) < 0.002, "\(key): \(String(describing: got)) != \(want)")
        }
    }

    @Test func rowIsOneLineOfValidJSONWithIdentityFields() throws {
        let line = TelemetryRenderer.ndjson(Fixtures.snapshot(), extras: Fixtures.extras())
        #expect(!line.contains("\n"))
        let row = try Fixtures.row(line)
        #expect(row["ts"] as? String == "2026-10-10T12:00:00Z")
        #expect(row["session"] as? String == "abcd1234")
        #expect(row["host"] as? String == "deadbeef")
        #expect(row["build_commit"] as? String == "abc123")
        #expect(row["build_date"] as? String == "2026-10-10")
        let client = try #require(row["client"] as? String)
        #expect(client == TelemetryRenderer.clientLabel)
        #expect(client.count == 8 && client.allSatisfy(\.isHexDigit))
        check(row, ["t_connect_s": 42.5])
    }

    @Test func frameNetworkAndPacingFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        check(row, [
            "fps_received": 119.5, "fps_decoded": 118.5, "fps_rendered": 117.5,
            "decode_ema_ms": 3.25, "decode_service_ms": 2.75, "decode_wait_ms": 0.5,
            "present_cadence_err_ms": 1.5, "present_on_time": 900, "present_late": 12,
            "present_late_host_cadence": 4, "host_frame_interval_p50_ms": 8.25,
            "host_frame_interval_p95_ms": 9.5, "host_uneven_pairs": 7,
            "host_encode_min_ms": 2.5, "host_encode_avg_ms": 4.5, "host_encode_max_ms": 9.75,
            "recv_jitter_ms": 0.75, "fec_recovery_rate": 0.125, "fec_percentage": 20,
            "fec_parity_margin": 3, "reorder_disp_max_ms": 6.5, "reorder_hold_exceeded": 2,
            "reorder_hold_taken_total": 21, "reorder_hold_rescued_total": 19,
            "pkts_per_s": 9_500.5, "rtt_ms": 4.5, "rtt_var_ms": 0.25,
            "pre_fec_loss_rate": 0.005, "out_of_order_rate": 0.01, "duplicate_rate": 0.002,
            "goodput_mbps": 180.5, "negotiated_bitrate_mbps": 200, "goodput_utilization": 0.9,
            "packet_gap_p50_us": 101, "packet_gap_p95_us": 450, "packet_gap_max_us": 2_500,
            "enet_sent_reliable": 3, "enet_oldest_unacked_ms": 40, "enet_since_last_ack_ms": 12,
            "enet_retransmit_total": 5, "ctrl_ignored_total": 74,
            "net_gaps_over_20ms_total": 91, "net_gaps_over_50ms_total": 92,
            "net_gaps_over_100ms_total": 93, "audio_gaps_over_20ms_total": 94,
            "audio_gaps_over_50ms_total": 95, "audio_gaps_over_100ms_total": 96,
            "enet_gaps_over_20ms_total": 97, "enet_gaps_over_50ms_total": 98,
            "enet_gaps_over_100ms_total": 99,
            "pacing_depth": 2, "pacing_target_depth": 3, "decode_backlog": 1,
            "pacer_ticks_per_s": 119.75, "pacer_releases_per_s": 118.5,
            "drops_decoder": 11, "drops_backpressure": 12, "drops_presentation_late": 13,
            "drops_recovery_wait_total": 15, "drops_suppressed_total": 72,
            "pacer_submit_release_total": 73, "drops_decode_gated_total": 79
        ])
        #expect(row["pacer_tick_realtime"] as? Bool == true)
        #expect(row["present_suppressed"] as? Bool == true)
        #expect(row["decode_gated"] as? Bool == true)
    }

    @Test func inputRefreshProcessAndEventFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        check(row, [
            "input_events_per_s": 250.5, "input_flush_per_s": 125, "input_motion_per_s": 240,
            "dualsense_hid_reports_per_s": 250, "input_idle_to_active_total": 9,
            "input_since_last_ms": 33.5, "rumble_events_total": 80, "rumble_events_per_s": 135,
            "rumble_dropped_invalid_total": 81, "refresh_min_hz": 80, "refresh_avg_hz": 110.5,
            "refresh_max_hz": 120, "frame_bytes_avg": 41_000.5, "frame_bytes_max": 190_000,
            "frame_idr_percent": 1.25, "thermal_state": 2, "cpu_percent": 55.5, "thread_count": 61,
            "rfi_total": 51, "idr_requested_total": 52, "backlog_overflow_total": 53,
            "present_stall_total": 54, "frame_loss_total": 55, "unrecoverable_frame_total": 56,
            "pacer_disabled_total": 57, "bookmark_total": 58
        ])
        #expect(row["refresh_changed"] as? Bool == true)
        #expect(row["low_power_mode"] as? Bool == true)
    }

    @Test func resourceSectionListsThreadsAndSocFields() throws {
        let row = try fullRow()
        let threads = try #require(row["threads"] as? [[String: Any]])
        #expect(threads.count == 2)
        #expect(threads[0]["name"] as? String == "Glimmer.decode")
        #expect(threads[0]["qos"] as? Int == 33)
        #expect(threads[0]["qos_label"] as? String == "userInteractive")
        #expect((threads[0]["cpu_percent"] as? Double) == 71.5)
        #expect(threads[1]["name"] as? String == "unnamed")
        check(row, [
            "phys_footprint_bytes": 512_000_000, "soc_ecluster_active": 0.25, "soc_pcluster_active": 0.75,
            "soc_ecluster_channels": 2, "soc_pcluster_channels": 4, "package_power_w": 9.5,
            "gpu_residency_percent": 38.5
        ])
        #expect(row["on_battery"] as? Bool == true)
        #expect(row["battery_charging"] as? Bool == false)
    }

    @Test func rendererDecodeAndDisplayFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        #expect(row["renderer_metrics_status"] as? String == "ready")
        check(row, [
            "renderer_metrics_resets_total": 2, "renderer_metrics_age_s": 0.5, "renderer_metrics_interval_s": 1,
            "renderer_frames_total": 1_000, "renderer_dropped_frames_total": 7,
            "renderer_optimized_frames_total": 990, "renderer_accumulated_frame_delay_s": 1.5,
            "renderer_frames_delta": 120, "renderer_dropped_frames_delta": 1,
            "renderer_optimized_frames_delta": 119, "renderer_frame_delay_delta_s": 0.25,
            "decoder_recreate_total": 4, "decoder_recreate_first_total": 1,
            "decoder_recreate_resolution_total": 2, "decoder_recreate_colorspace_total": 1,
            "vt_session_create_ms": 18.5, "discontinuity_flush_total": 3, "decode_bit_depth": 10,
            "present_stale_repeat_total": 31, "present_stale_repeats_per_s": 1.5,
            "pacer_over_target_release_total": 71, "pacer_over_target_releases_per_s": 0.5,
            "pacer_over_target_release_ratio": 0.0625, "tick_miss_descheduled_total": 41,
            "tick_miss_coalesced_total": 42, "tick_miss_preempted_total": 43,
            "tick_miss_linkskip_total": 44, "edr_headroom_min": 1, "edr_headroom_avg": 2.5,
            "edr_headroom_max": 4, "max_refresh_hz": 120
        ])
        #expect(row["decode_hw"] as? Bool == true)
        #expect(row["decode_pixel_format"] as? String == "x420")
        #expect(row["decode_colorspace"] as? String == "itur_2100_PQ")
        #expect(row["hdr_engaged"] as? Bool == true)
        #expect(row["promotion_capable"] as? Bool == true)
        #expect(row["screen"] as? String == "Studio \"Display\"")
    }

    @Test func audioFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        check(row, [
            "audio_packets_total": 5_000, "audio_packets_lost_total": 7, "audio_fec_recovered_total": 9,
            "audio_fec_mismatch_total": 76, "audio_receive_failed_total": 77, "audio_decode_failed_total": 78,
            "audio_pkts_per_s": 200.5, "audio_gap_max_ms": 25.5, "audio_loss_rate": 0.001,
            "audio_fec_recovery_rate": 0.002, "audio_engine_running": 1, "audio_buffer_fill_ms": 48.5,
            "audio_resampler_ppm": -12.5, "audio_buffer_fill_min_ms": 31.5, "audio_playout_target_ms": 45,
            "audio_cushion_max_ms": 150, "audio_underrun_total": 4, "audio_underrun_deadair_total": 82,
            "audio_overrun_total": 1, "audio_trim_total": 75, "audio_trims_per_s": 0.75,
            "audio_reprime_total": 2, "audio_stall_recovery_total": 25, "audio_underruns_per_s": 0.25,
            "audio_overruns_per_s": 0.125, "audio_clock_drift_ms": -3.5, "av_skew_ms": -42.5,
            "av_clock_skew_ms": 1.75, "av_skew_rebase_total": 83, "audio_cushion_floor_ms": 35,
            "audio_cushion_seed_ms": 30, "audio_first_packet_ms": 310.5
        ])
    }

    @Test func linkAndWiFiFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        #expect(row["stream_link"] as? String == "wired")
        #expect(row["stream_if"] as? String == "en12")
        #expect(row["env_state_label"] as? String == "caution")
        #expect(row["awdl_suppressing"] as? Bool == true)
        #expect(row["wifi_link"] as? String == "wifi")
        #expect(row["wifi_ssid"] as? String == "Den \"5G\"")
        #expect(row["wifi_band"] as? String == "5GHz")
        check(row, [
            "env_state": 1, "env_state_changes_total": 3, "keepalive_interval_ms": 75,
            "pings_sent_video_total": 600, "pings_sent_audio_total": 590,
            "pings_video_per_s": 13.5, "pings_audio_per_s": 13, "awdl_resuppress_total": 8,
            "udp_fullsock_delta": 6, "wifi_rssi_dbm": -61, "wifi_tx_rate_mbps": 866.5,
            "wifi_noise_dbm": -92, "wifi_channel": 149
        ])
    }

    @Test func lifecycleFieldsCarryTheirOwnValues() throws {
        let row = try fullRow()
        check(row, [
            "handshake_rtsp_ms": 120.5, "handshake_control_setup_ms": 15,
            "handshake_enet_connect_ms": 80.25, "handshake_first_frame_ms": 210,
            "handshake_total_ms": 425.75, "reconnect_total": 2, "wake_total": 1,
            "disconnect_reason": 3, "idr_round_trip_request_total": 6,
            "idr_round_trip_matched_total": 5, "idr_round_trip_last_ms": 22.5,
            "corruption_heuristic_total": 3, "corruption_heuristic_per_s": 0.5
        ])
        #expect(row["disconnect_reason_label"] as? String == "host_error")
    }

    @Test func latencyFieldsAreQuantilesOfOnlyTheStagesThatHaveData() throws {
        let row = try fullRow()
        // 10 observations of 1 ms in the (0.75, 1] bucket, 10 of 8 ms in glass-to-glass's (6, 8].
        check(row, [
            "lat_recv_to_assemble_p50_ms": 0.875, "lat_recv_to_assemble_p95_ms": 0.9875,
            "lat_recv_to_assemble_p99_ms": 0.9975, "glass_to_glass_p50_ms": 7,
            "glass_to_glass_p95_ms": 7.9, "glass_to_glass_p99_ms": 7.98
        ])
        #expect(row["lat_end_to_end_p50_ms"] == nil)
        #expect(row["decode_idr_p95_ms"] == nil)
    }

    @Test func inputLatencyStagesRenderOnlyWhenPresent() {
        var snap = Fixtures.snapshot()
        let base = TelemetryRenderer.ndjsonLatencyFields(snap)
        #expect(!base.contains { $0.hasPrefix("\"lat_input_deliver_p50_ms\"") })
        snap.inputDeliverLatency = Fixtures.stage(1)
        snap.inputLocalLatency = Fixtures.stage(2)
        let fields = TelemetryRenderer.ndjsonLatencyFields(snap)
        #expect(fields.contains { $0.hasPrefix("\"lat_input_deliver_p50_ms\":0.875") })
        #expect(fields.contains { $0.hasPrefix("\"lat_input_queue_to_wire_p50_ms\":1.75") })
    }

    @Test func rolling60sFieldsCountFramesAndUseTheWindowedStages() {
        var extras = Fixtures.extras()
        #expect(TelemetryRenderer.ndjsonRollingLatencyFields(extras).isEmpty)
        extras.latencyRolling60s = Fixtures.histograms {
            for _ in 0..<10 { $0.endToEnd.observe(2) }
        }
        let fields = TelemetryRenderer.ndjsonRollingLatencyFields(extras)
        #expect(fields.first == "\"frames_in_window_60s\":10")
        #expect(fields.contains { $0.hasPrefix("\"lat_end_to_end_p50_60s_ms\":") })
        #expect(!fields.contains { $0.hasPrefix("\"glass_to_glass_p50_60s_ms\"") })
    }

    @Test func sparseSnapshotOmitsAbsentFieldsInsteadOfWritingNull() throws {
        var snap = TelemetrySnapshot()
        snap.sessionId = "s1"
        let line = TelemetryRenderer.ndjson(snap, extras: TelemetrySnapshot.Extras())
        let row = try Fixtures.row(line)
        #expect(!line.contains("null") && !line.contains("nan") && !line.contains("inf"))
        for absent in ["fps_received", "rtt_ms", "wifi_link", "stream_link", "threads", "decode_hw",
                       "audio_packets_total", "handshake_rtsp_ms", "lat_end_to_end_p50_ms", "host",
                       "build_commit", "vt_session_create_ms", "audio_cushion_floor_ms"] {
            #expect(row[absent] == nil, "\(absent) should be omitted")
        }
        #expect(row["session"] as? String == "s1")
        #expect(row["disconnect_reason_label"] as? String == "none")
        check(row, ["rfi_total": 0, "reconnect_total": 0, "disconnect_reason": 0])
    }

    @Test func nonFiniteDoublesAreDroppedNotWritten() throws {
        var snap = TelemetrySnapshot()
        snap.rttMs = .nan
        snap.goodputMbps = .infinity
        snap.recvJitterMs = 1.5
        let row = try Fixtures.row(TelemetryRenderer.ndjson(snap, extras: TelemetrySnapshot.Extras()))
        #expect(row["rtt_ms"] == nil && row["goodput_mbps"] == nil)
        check(row, ["recv_jitter_ms": 1.5])
    }

    @Test func wifiWithoutRadioOmitsRadioFieldsButKeepsLinkState() throws {
        var snap = TelemetrySnapshot()
        snap.wifi = WiFiSnapshot(linkState: .wired)
        let row = try Fixtures.row(TelemetryRenderer.ndjson(snap, extras: TelemetrySnapshot.Extras()))
        #expect(row["wifi_link"] as? String == "wired")
        for key in ["wifi_rssi_dbm", "wifi_tx_rate_mbps", "wifi_noise_dbm", "wifi_ssid", "wifi_channel", "wifi_band"] {
            #expect(row[key] == nil)
        }
    }

    @Test func emptyStringFieldsAreSkipped() {
        var builder = TelemetryRenderer.NDJSONBuilder()
        builder.addString("a", "")
        builder.addString("b", nil)
        builder.addString("c", "x")
        #expect(builder.line() == "{\"c\":\"x\"}")
    }

    @Test func stringEscapingCoversQuotesBackslashesAndControlCharacters() throws {
        #expect(TelemetryRenderer.jsonStringEscape("a\"b\\c\nd\re\tf") == "a\\\"b\\\\c\\nd\\re\\tf")
        #expect(TelemetryRenderer.jsonStringEscape("\u{01}\u{1f}") == "\\u0001\\u001f")
        #expect(TelemetryRenderer.jsonStringEscape("Café 日本") == "Café 日本")
        var snap = TelemetrySnapshot()
        snap.serverName = "pc\"1\\\n"
        let row = try Fixtures.row(TelemetryRenderer.ndjson(snap, extras: TelemetrySnapshot.Extras()))
        #expect(row["host"] as? String == "pc\"1\\\n")
    }

    @Test func thermalOrdinalsFollowSeverity() {
        #expect(ProcessMetrics.thermalOrdinal(.nominal) == 0)
        #expect(ProcessMetrics.thermalOrdinal(.fair) == 1)
        #expect(ProcessMetrics.thermalOrdinal(.serious) == 2)
        #expect(ProcessMetrics.thermalOrdinal(.critical) == 3)
    }

    @Test func processSampleReportsALiveThreadCount() {
        let sample = ProcessMetrics.sample()
        #expect(sample.threadCount > 0)
        #expect(sample.cpuPercent >= 0)
    }
}
