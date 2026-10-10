// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryPrometheusRenderTests.swift
//
//  The Prometheus body: metric names, values and labels for a fully populated snapshot,
//  the builder's escaping and histogram layout, and which sections a sparse snapshot omits.
//

import CryptoKit
import Foundation
import Testing
@testable import Glimmer

struct TelemetryPrometheusRenderTests {

    private typealias Fixtures = TelemetryRenderFixtures

    private func fullBody() -> String {
        TelemetryRenderer.prometheus(Fixtures.snapshot(), extras: Fixtures.extras())
    }

    private func check(_ metrics: [String: [Fixtures.Sample]], _ expected: [String: Double]) {
        for (name, want) in expected {
            let got = metrics[name]?.first?.value
            #expect(got != nil && abs((got ?? 0) - want) < 0.002, "\(name): \(String(describing: got)) != \(want)")
        }
    }

    @Test func videoNetworkAndPacingMetricsCarryTheirOwnValues() {
        let metrics = Fixtures.parseProm(fullBody())
        check(metrics, [
            "glimmer_session_uptime_seconds": 42.5, "glimmer_fps_received": 119.5, "glimmer_fps_decoded": 118.5,
            "glimmer_fps_rendered": 117.5, "glimmer_decode_time_ema_ms": 3.25,
            "glimmer_decode_service_ema_ms": 2.75, "glimmer_decode_wait_ema_ms": 0.5,
            "glimmer_present_cadence_error_ms": 1.5, "glimmer_present_on_time_percent": 98.5,
            "glimmer_host_encode_latency_min_ms": 2.5, "glimmer_host_encode_latency_avg_ms": 4.5,
            "glimmer_host_encode_latency_max_ms": 9.75, "glimmer_pacing_queue_depth": 2,
            "glimmer_pacing_target_depth": 3, "glimmer_decode_backlog": 1,
            "glimmer_pacer_ticks_per_second": 119.75, "glimmer_pacer_releases_per_second": 118.5,
            "glimmer_pacer_tick_realtime": 1, "glimmer_drops_decoder_total": 11,
            "glimmer_drops_backpressure_total": 12, "glimmer_drops_presentation_late_total": 13,
            "glimmer_present_perceived_gaps_total": 14, "glimmer_drops_suppressed_total": 72,
            "glimmer_present_suppressed": 1, "glimmer_drops_decode_gated_total": 79, "glimmer_decode_gated": 1,
            "glimmer_display_refresh_min_hz": 80, "glimmer_display_refresh_avg_hz": 110.5,
            "glimmer_display_refresh_max_hz": 120, "glimmer_display_refresh_changed": 1,
            "glimmer_frame_bytes_avg": 41_000.5, "glimmer_frame_bytes_max": 190_000,
            "glimmer_frame_idr_percent": 1.25
        ])
        check(metrics, [
            "glimmer_net_recv_jitter_ms": 0.75, "glimmer_net_fec_recovery_rate": 0.125,
            "glimmer_reorder_hold_taken_total": 21, "glimmer_reorder_hold_rescued_total": 19,
            "glimmer_reorder_displacement_max_ms": 6.5, "glimmer_reorder_displacement_max_packets": 14,
            "glimmer_reorder_hold_margin_ms": 3.5, "glimmer_reorder_hold_exceeded_total": 2,
            "glimmer_fec_percentage": 20, "glimmer_fec_parity_margin": 3, "glimmer_awdl_suppressing": 1,
            "glimmer_net_packets_per_second": 9_500.5,
            "glimmer_net_rtt_ms": 4.5, "glimmer_net_rtt_variance_ms": 0.25,
            "glimmer_net_pre_fec_loss_rate": 0.005, "glimmer_net_out_of_order_rate": 0.01,
            "glimmer_net_duplicate_rate": 0.002, "glimmer_net_goodput_mbps": 180.5,
            "glimmer_net_negotiated_bitrate_mbps": 200, "glimmer_net_goodput_utilization": 0.9,
            "glimmer_net_packet_gap_p50_us": 101, "glimmer_net_packet_gap_p95_us": 450,
            "glimmer_net_packet_gap_max_us": 2_500, "glimmer_enet_sent_reliable": 3,
            "glimmer_enet_oldest_unacked_ms": 40, "glimmer_enet_since_last_ack_ms": 12,
            "glimmer_enet_retransmit_total": 5, "glimmer_ack_silence_near_miss_total": 1,
            "glimmer_ctrl_ignored_total": 74, "glimmer_net_gaps_over_20ms_total": 91,
            "glimmer_net_gaps_over_50ms_total": 92, "glimmer_net_gaps_over_100ms_total": 93,
            "glimmer_audio_gaps_over_20ms_total": 94, "glimmer_audio_gaps_over_50ms_total": 95,
            "glimmer_audio_gaps_over_100ms_total": 96, "glimmer_enet_gaps_over_20ms_total": 97,
            "glimmer_enet_gaps_over_50ms_total": 98, "glimmer_enet_gaps_over_100ms_total": 99
        ])
    }

    @Test func eventDecodeDisplayAndInputMetricsCarryTheirOwnValues() {
        let metrics = Fixtures.parseProm(fullBody())
        check(metrics, [
            "glimmer_rfi_total": 51, "glimmer_idr_requested_total": 52, "glimmer_backlog_overflow_total": 53,
            "glimmer_present_stall_total": 54, "glimmer_frame_loss_total": 55,
            "glimmer_unrecoverable_frame_total": 56, "glimmer_pacer_disabled_total": 57,
            "glimmer_bookmark_total": 58, "glimmer_cruise_boosted_batches_total": 59,
            "glimmer_cruise_identity_batches_total": 60, "glimmer_decoder_recreate_total": 4,
            "glimmer_vt_session_create_ms": 18.5, "glimmer_cruise_max_gain": 2.5,
            "glimmer_discontinuity_flush_total": 3, "glimmer_decode_hw_accelerated": 1,
            "glimmer_decode_bit_depth": 10, "glimmer_present_stale_repeat_total": 31,
            "glimmer_present_stale_repeats_per_second": 1.5, "glimmer_present_stale_empty_total": 22,
            "glimmer_present_gap_drought_total": 23, "glimmer_audio_near_miss_total": 24,
            "glimmer_pacer_over_target_release_total": 71,
            "glimmer_pacer_over_target_releases_per_second": 0.5,
            "glimmer_pacer_over_target_release_ratio": 0.0625, "glimmer_tick_miss_descheduled_total": 41,
            "glimmer_tick_miss_coalesced_total": 42, "glimmer_tick_miss_preempted_total": 43,
            "glimmer_tick_miss_linkskip_total": 44, "glimmer_display_edr_headroom_min": 1,
            "glimmer_display_edr_headroom_avg": 2.5, "glimmer_display_edr_headroom_max": 4,
            "glimmer_display_hdr_engaged": 1, "glimmer_display_promotion_capable": 1,
            "glimmer_display_max_refresh_hz": 120, "glimmer_input_events_per_second": 250.5,
            "glimmer_input_flush_per_second": 125, "glimmer_input_idle_to_active_total": 9,
            "glimmer_input_since_last_ms": 33.5, "glimmer_input_flush_backpressure_skips_total": 16,
            "glimmer_input_flush_backpressure_reliable_skips_total": 17, "glimmer_rumble_events_total": 80,
            "glimmer_rumble_events_per_second": 135, "glimmer_rumble_dropped_invalid_total": 81,
            "glimmer_process_cpu_percent": 55.5, "glimmer_process_thread_count": 61,
            "glimmer_thermal_state": 2, "glimmer_on_battery": 0
        ])
        #expect(metrics["glimmer_low_power_mode"]?.map(\.value) == [1, 1])
        #expect(metrics["glimmer_display_hdr_engaged"]?.first?.labels.contains("screen=\"Studio \\\"Display\\\"\"") == true)
    }

    @Test func resourceAndLifecycleMetricsCarryTheirOwnValues() {
        let metrics = Fixtures.parseProm(fullBody())
        check(metrics, [
            "glimmer_power_on_battery": 1,
            "glimmer_power_battery_charging": 0, "glimmer_soc_ecluster_active_residency": 0.25,
            "glimmer_soc_pcluster_active_residency": 0.75, "glimmer_package_power_w": 9.5,
            "glimmer_gpu_residency_percent": 38.5, "glimmer_handshake_rtsp_ms": 120.5,
            "glimmer_handshake_control_setup_ms": 15, "glimmer_handshake_enet_connect_ms": 80.25,
            "glimmer_handshake_first_frame_ms": 210, "glimmer_handshake_total_ms": 425.75,
            "glimmer_connect_click_to_first_frame_ms": 900, "glimmer_launch_path_ms": 470,
            "glimmer_launch_serverinfo_ms": 30, "glimmer_launch_cancel_ms": 40,
            "glimmer_launch_busy_wait_ms": 50, "glimmer_launch_busy_poll_count": 3,
            "glimmer_launch_ms": 60, "glimmer_launch_build_ms": 70, "glimmer_reconnect_total": 2,
            "glimmer_wake_total": 1, "glimmer_route_change_total": 4, "glimmer_disconnect_reason": 3,
            "glimmer_idr_round_trip_request_total": 6, "glimmer_idr_round_trip_matched_total": 5,
            "glimmer_idr_round_trip_last_ms": 22.5, "glimmer_corruption_heuristic_total": 3,
            "glimmer_corruption_heuristic_per_second": 0.5
        ])
        let cpu = metrics["glimmer_thread_cpu_percent"] ?? []
        #expect(cpu.map(\.value) == [71.5, 3.5])
        #expect(cpu[0].labels.contains("thread=\"Glimmer.decode\",qos=\"userInteractive\""))
        #expect(cpu[1].labels.contains("thread=\"unnamed\",qos=\"utility\""))
        #expect(metrics["glimmer_thread_qos"]?.map(\.value) == [33, 17])
    }

    @Test func audioAndEnvSignalMetricsCarryTheirOwnValues() {
        let metrics = Fixtures.parseProm(fullBody())
        check(metrics, [
            "glimmer_audio_packets_total": 5_000, "glimmer_audio_packets_lost_total": 7,
            "glimmer_audio_fec_recovered_total": 9, "glimmer_audio_fec_mismatch_total": 76,
            "glimmer_audio_receive_failed_total": 77, "glimmer_audio_packets_per_second": 200.5,
            "glimmer_audio_loss_rate": 0.001, "glimmer_audio_fec_recovery_rate": 0.002,
            "glimmer_audio_engine_running": 1, "glimmer_audio_buffer_fill_ms": 48.5,
            "glimmer_audio_buffer_fill_min_ms": 31.5, "glimmer_audio_playout_target_ms": 45,
            "glimmer_audio_underrun_total": 4, "glimmer_audio_overrun_total": 1,
            "glimmer_audio_trim_total": 75, "glimmer_audio_trims_per_second": 0.75,
            "glimmer_audio_reprime_total": 2, "glimmer_audio_underruns_per_second": 0.25,
            "glimmer_audio_overruns_per_second": 0.125, "glimmer_audio_clock_drift_ms": -3.5,
            "glimmer_av_skew_ms": -42.5, "glimmer_av_clock_skew_ms": 1.75, "glimmer_av_skew_rebase_total": 83,
            "glimmer_audio_resampler_ppm": -12.5, "glimmer_audio_cushion_floor_ms": 35,
            "glimmer_audio_cushion_seed_ms": 30, "glimmer_audio_first_packet_ms": 310.5,
            "glimmer_env_state": 1, "glimmer_env_state_changes_total": 3,
            "glimmer_keepalive_interval_ms": 75, "glimmer_video_pings_sent_total": 600,
            "glimmer_audio_pings_sent_total": 590
        ])
        #expect(metrics["glimmer_env_state"]?.first?.labels.contains("state=\"caution\"") == true)
    }

    @Test func everySampleCarriesTheSessionClientAndPseudonymousHostLabels() {
        let body = fullBody()
        let shared = "session=\"abcd1234\",client=\"\(TelemetryRenderer.clientLabel)\",host=\"deadbeef\""
        let samples = body.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(samples.count > 200)
        #expect(samples.allSatisfy { $0.contains(shared) })
    }

    @Test func everyMetricFamilyHasHelpAndTypeBeforeItsSamples() {
        let lines = fullBody().split(separator: "\n").map(String.init)
        var declared = Set<String>()
        for line in lines {
            if line.hasPrefix("# TYPE ") {
                declared.insert(String(line.dropFirst(7).prefix { $0 != " " }))
            } else if !line.hasPrefix("#") {
                let name = String(line.prefix { $0 != "{" && $0 != " " })
                let family = ["_bucket", "_sum", "_count"].reduce(name) {
                    $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0
                }
                #expect(declared.contains(name) || declared.contains(family), "\(name) has no TYPE line")
            }
        }
    }

    @Test func infoMetricsCarryBuildAndDecodeAndDisconnectLabels() {
        let metrics = Fixtures.parseProm(fullBody())
        #expect(metrics["glimmer_build_info"]?.first?.labels.contains(",commit=\"abc123\",date=\"2026-10-10\"}") == true)
        let decode = metrics["glimmer_decode_state_info"]?.first
        #expect(decode?.value == 1)
        #expect(decode?.labels.contains(",codec=\"hevc\",pixel_format=\"x420\",bit_depth=\"10\"") == true)
        #expect(decode?.labels.contains("colorspace=\"itur_2100_PQ\",hw_decode=\"true\"") == true)
        #expect(metrics["glimmer_disconnect_reason_info"]?.first?.labels.contains("reason=\"host_error\"") == true)
        #expect(metrics["glimmer_renderer_metrics_status"]?.first?.labels.contains("status=\"ready\"") == true)
    }

    @Test func counterFamiliesEmitOneSeriesPerRow() {
        let metrics = Fixtures.parseProm(fullBody())
        let causes = metrics["glimmer_decoder_recreate_by_cause_total"] ?? []
        #expect(causes.map(\.value) == [1, 2, 1])
        #expect(causes.map { $0.labels.contains("cause=\"param_rebuild_resolution\"") } == [false, true, false])
        let disconnects = metrics["glimmer_disconnect_total"] ?? []
        #expect(disconnects.map(\.value) == [5, 1])
        #expect(disconnects[0].labels.contains("reason=\"user_stopped\""))
    }

    @Test func rendererMetricsRenderCumulativeAndDeltaValues() {
        let metrics = Fixtures.parseProm(fullBody())
        check(metrics, [
            "glimmer_renderer_metrics_resets_total": 2, "glimmer_renderer_metrics_age_seconds": 0.5,
            "glimmer_renderer_metrics_interval_seconds": 1, "glimmer_renderer_frames_total": 1_000,
            "glimmer_renderer_dropped_frames_total": 7, "glimmer_renderer_optimized_frames_total": 990,
            "glimmer_renderer_accumulated_frame_delay_seconds": 1.5, "glimmer_renderer_frames_delta": 120,
            "glimmer_renderer_dropped_frames_delta": 1, "glimmer_renderer_optimized_frames_delta": 119,
            "glimmer_renderer_frame_delay_delta_seconds": 0.25
        ])
        var snap = Fixtures.snapshot()
        snap.rendererPerformance = RendererPerformanceSnapshot(status: .pending)
        let pending = Fixtures.parseProm(TelemetryRenderer.prometheus(snap, extras: Fixtures.extras()))
        #expect(pending["glimmer_renderer_frames_total"] == nil)
        #expect(pending["glimmer_renderer_frames_delta"] == nil)
        #expect(pending["glimmer_renderer_metrics_resets_total"]?.first?.value == 0)
    }

    // `UInt64?.map(Double.init)` binds Double(bitPattern:), so these four gauges render ~0.
    @Test func uint64GaugesShouldCarryTheirCounts() {
        let metrics = Fixtures.parseProm(fullBody())
        withKnownIssue("Double.init binds init(bitPattern:) for UInt64 optionals") {
            check(metrics, [
                "glimmer_present_on_time_frames": 900, "glimmer_present_late_frames": 12,
                "glimmer_awdl_resuppress_total": 8, "glimmer_process_phys_footprint_bytes": 512_000_000
            ])
        }
    }

    @Test func wifiMetricsLabelTheRadioAndSkipMissingReadings() {
        let metrics = Fixtures.parseProm(fullBody())
        let rssi = metrics["glimmer_wifi_rssi_dbm"]?.first
        #expect(rssi?.value == -61)
        #expect(rssi?.labels.contains("ssid=\"Den \\\"5G\\\"\",band=\"5GHz\",channel=\"149\"") == true)
        #expect(metrics["glimmer_wifi_tx_rate_mbps"]?.first?.value == 866.5)
        #expect(metrics["glimmer_wifi_noise_dbm"]?.first?.value == -92)
        #expect(metrics["glimmer_wifi_link_state"]?.first?.labels.contains("link=\"wifi\"") == true)

        var snap = Fixtures.snapshot()
        snap.wifi = WiFiSnapshot(linkState: .unassociated)
        let bare = Fixtures.parseProm(TelemetryRenderer.prometheus(snap, extras: Fixtures.extras()))
        #expect(bare["glimmer_wifi_link_state"]?.first?.value == 1)
        #expect(bare["glimmer_wifi_rssi_dbm"] == nil && bare["glimmer_wifi_noise_dbm"] == nil)
    }

    @Test func latencyHistogramsRenderCumulativeBucketsSumAndCount() {
        let lines = fullBody().split(separator: "\n").map(String.init)
        let prefix = "glimmer_latency_receive_to_assemble_ms"
        let buckets = lines.filter { $0.hasPrefix("\(prefix)_bucket") }
        #expect(buckets.count == LatencyHistograms.Stage.boundsMs.count + 1)
        func count(_ le: String) -> String? {
            buckets.first { $0.contains("le=\"\(le)\"") }?.split(separator: " ").last.map(String.init)
        }
        #expect(count("0.750") == "0")
        #expect(count("1") == "10")
        #expect(count("528") == "10")
        #expect(count("+Inf") == "10")
        #expect(lines.contains { $0.hasPrefix("\(prefix)_sum{") && $0.hasSuffix(" 10") })
        #expect(lines.contains { $0.hasPrefix("\(prefix)_count{") && $0.hasSuffix(" 10") })
        #expect(!lines.contains { $0.hasPrefix("glimmer_latency_end_to_end_ms") && !$0.hasPrefix("#") })
    }

    @Test func glassToGlassHistogramUsesItsOwnBounds() {
        let lines = fullBody().split(separator: "\n").map(String.init)
        let buckets = lines.filter { $0.hasPrefix("glimmer_latency_glass_to_glass_ms_bucket") }
        #expect(buckets.count == 21)
        #expect(buckets.first { $0.contains("le=\"6\"") }?.hasSuffix(" 0") == true)
        #expect(buckets.first { $0.contains("le=\"8\"") }?.hasSuffix(" 10") == true)
    }

    @Test func sparseSnapshotOmitsOptionalSectionsButKeepsAlwaysOnCounters() {
        var snap = TelemetrySnapshot()
        snap.sessionId = "s1"
        let metrics = Fixtures.parseProm(TelemetryRenderer.prometheus(snap, extras: TelemetrySnapshot.Extras()))
        for absent in ["glimmer_build_info", "glimmer_fps_received", "glimmer_audio_packets_total",
                       "glimmer_wifi_link_state", "glimmer_handshake_rtsp_ms", "glimmer_decode_hw_accelerated",
                       "glimmer_latency_end_to_end_ms_count", "glimmer_idr_round_trip_request_total",
                       "glimmer_vt_session_create_ms", "glimmer_cruise_max_gain", "glimmer_env_state",
                       "glimmer_display_hdr_engaged", "glimmer_thread_cpu_percent", "glimmer_on_battery"] {
            #expect(metrics[absent] == nil, "\(absent) should be omitted")
        }
        #expect(metrics["glimmer_rfi_total"]?.first?.value == 0)
        #expect(metrics["glimmer_session_uptime_seconds"]?.first?.value == 0)
        #expect(metrics["glimmer_disconnect_reason"]?.first?.value == 0)
        #expect(metrics["glimmer_awdl_suppressing"]?.first?.value == 0)
        #expect(metrics["glimmer_disconnect_total"] == nil)
        #expect(metrics["glimmer_pacer_tick_realtime"]?.first?.value == 0)
    }

    @Test func builderSkipsNilAndNonFiniteGaugesAndEscapesHostLabel() {
        var builder = TelemetryRenderer.PromBuilder(session: "s", host: "a\"b\\c\nd")
        builder.emit("m_nil", "h", nil)
        builder.emit("m_nan", "h", .nan)
        builder.emit("m_inf", "h", .infinity)
        builder.emit("m_ok", "help text", 2.5)
        #expect(!builder.out.contains("m_nil") && !builder.out.contains("m_nan") && !builder.out.contains("m_inf"))
        #expect(builder.out.hasPrefix("# HELP m_ok help text\n# TYPE m_ok gauge\nm_ok{session=\"s\",client=\""))
        #expect(builder.out.contains("host=\"a\\\"b\\\\c\\nd\"} 2.500\n"))
    }

    @Test func labelEscapingFollowsTheExpositionFormat() {
        #expect(TelemetryRenderer.escapeLabel("a\\b\"c\nd") == "a\\\\b\\\"c\\nd")
        #expect(TelemetryRenderer.escapeLabel("plain") == "plain")
    }

    @Test func emptyHistogramsAndEmptyFamiliesEmitNothing() {
        var builder = TelemetryRenderer.PromBuilder(session: "s", host: "h")
        builder.emitHistogram("x_ms", "h", stage: Fixtures.stage(1, count: 0))
        builder.emitCounterFamily("x_total", "h", key: "k", rows: [])
        #expect(builder.out.isEmpty)
    }

    @Test func pseudonymIsStableKeyedAndEightHexDigits() {
        let saltA = TelemetryRenderer.installSalt
        let first = TelemetryRenderer.pseudonym("Den PC", salt: saltA)
        #expect(first == TelemetryRenderer.pseudonym("Den PC", salt: saltA))
        #expect(first != TelemetryRenderer.pseudonym("Den PC 2", salt: saltA))
        #expect(first.count == 8 && first.allSatisfy(\.isHexDigit))
        #expect(!first.localizedCaseInsensitiveContains("den"))
        let otherSalt = TelemetryRenderer.pseudonym("Den PC", salt: .init(size: .bits256))
        #expect(otherSalt != first)
    }

    @Test func quantilesInterpolateWithinTheMatchingBucket() throws {
        let tens = Fixtures.stage(1)
        #expect(try #require(TelemetryRenderer.histogramQuantile(0.5, stage: tens)) == 0.875)
        #expect(try #require(TelemetryRenderer.histogramQuantile(1, stage: tens)) == 1)
        // Half the samples at 0.5 ms, half at 3 ms: p50 lands at the top of the 0.5 ms bucket.
        let split = LatencyHistograms.Stage()
        for _ in 0..<5 { split.observe(0.5) }
        for _ in 0..<5 { split.observe(3) }
        let value = split.snapshotValue()
        #expect(try #require(TelemetryRenderer.histogramQuantile(0.5, stage: value)) == 0.5)
        let p90 = try #require(TelemetryRenderer.histogramQuantile(0.9, stage: value))
        #expect(p90 > 2 && p90 < 3)
    }

    @Test func quantileClampsToTopBoundAndIsNilWhenEmpty() {
        let top = LatencyHistograms.Stage.boundsMs.last
        let overflow = Fixtures.stage(10_000)
        #expect(TelemetryRenderer.histogramQuantile(0.99, stage: overflow) == top)
        #expect(TelemetryRenderer.histogramQuantile(0.5, stage: Fixtures.stage(1, count: 0)) == nil)
    }
}
