//
//  TelemetryExporter+RenderNDJSON.swift
//
//  The NDJSON half of the telemetry renderer (the Prometheus half + the shared
//  histogram-quantile estimator live in TelemetryExporter+Render.swift), plus the
//  process-level CPU/thread sampler. Split out to keep each unit focused and under
//  the file-length budget; see TelemetryExporter.swift for the exporter, gate,
//  counters, and the snapshot type.
//
//  Hand-built (no Codable) so the field order is stable + readable in a tail and
//  nil fields are simply omitted. Every value is a number, a bool, the opaque
//  session id, or a label (wifi ssid/band, build SHA/date) - nothing that could
//  be a secret.
//

import Foundation
import Darwin

extension TelemetryRenderer {

    /// A tiny field accumulator so the section renderers below stay flat (no giant
    /// nested-closure function). `value`-type, mutated in place; `line()` joins.
    struct NDJSONBuilder {
        var fields: [String] = []
        mutating func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            fields.append("\"\(key)\":\(TelemetryRenderer.jsonNumber(value))")
        }
        mutating func addInt(_ key: String, _ value: Int?) {
            guard let value else { return }
            fields.append("\"\(key)\":\(value)")
        }
        mutating func addCount(_ key: String, _ value: UInt64?) {
            guard let value else { return }
            fields.append("\"\(key)\":\(value)")
        }
        mutating func addBool(_ key: String, _ value: Bool?) {
            guard let value else { return }
            fields.append("\"\(key)\":\(value)")
        }
        mutating func addString(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append("\"\(key)\":\"\(TelemetryRenderer.jsonStringEscape(value))\"")
        }
        mutating func addRaw(_ raw: [String]) { fields.append(contentsOf: raw) }
        func line() -> String { "{" + fields.joined(separator: ",") + "}" }
    }

    /// Render one NDJSON object line from a per-second snapshot + its sidecar
    /// Extras (sampled together on the capture tick). Delegates to focused
    /// section helpers so this stays a readable table of contents.
    static func ndjson(_ snap: TelemetrySnapshot, extras: TelemetrySnapshot.Extras) -> String {
        var builder = NDJSONBuilder()
        builder.fields.append("\"ts\":\"\(snap.wallClockISO8601)\"")
        builder.fields.append("\"session\":\"\(snap.sessionId)\"")
        // Identity: which Mac (`client`) streaming from which Sunshine PC
        // (`host`) - mirrors the Prometheus label pair so the NDJSON splits the
        // same way offline.
        builder.addString("client", TelemetryRenderer.clientNameRaw)
        builder.addString("host", snap.serverName)
        // Build attribution (signal 5a) as an NDJSON header field on every line,
        // so a single line is enough to tie a sample to a build.
        builder.addString("build_commit", snap.buildCommit)
        builder.addString("build_date", snap.buildDate)
        builder.add("t_connect_s", snap.sinceConnectSeconds)
        ndjsonFrames(&builder, snap)
        ndjsonNetwork(&builder, snap, extras)
        ndjsonPacingDrops(&builder, snap, extras)
        ndjsonInputRefresh(&builder, snap, extras)
        ndjsonFrameSizeThermalProcess(&builder, snap)
        ndjsonResource(&builder, snap)
        ndjsonEventCounters(&builder, snap)
        builder.addRaw(ndjsonLatencyFields(snap))
        builder.addRaw(ndjsonRollingLatencyFields(extras))
        ndjsonDecodeDisplay(&builder, snap, extras)
        ndjsonAudio(&builder, snap, extras)
        ndjsonLink(&builder, snap, extras)
        ndjsonSessionLifecycle(&builder, snap)
        return builder.line()
    }

    /// P2 SESSION-LIFECYCLE fields on the per-second line: handshake breakdown
    /// legs, reconnect count + disconnect reason, IDR/RFI round-trip counts + last
    /// RTT, and the corruption heuristic total + per-second rate. (The handshake
    /// ALSO gets a one-shot explicit `event:"handshake"` line - see the exporter.)
    /// Numbers, the reason label, nil legs omitted.
    private static func ndjsonSessionLifecycle(_ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot) {
        if let handshake = snap.handshake {
            builder.add("handshake_rtsp_ms", handshake.rtspMs)
            builder.add("handshake_pairing_ms", handshake.pairingMs)
            builder.add("handshake_enet_connect_ms", handshake.enetConnectMs)
            builder.add("handshake_first_frame_ms", handshake.firstFrameMs)
            builder.add("handshake_total_ms", handshake.totalMs)
        }
        builder.addCount("reconnect_total", snap.reconnectTotal)
        builder.addInt("disconnect_reason", snap.disconnectReason.rawValue)
        builder.addString("disconnect_reason_label", snap.disconnectReason.label)
        if let idr = snap.idrRoundTrip {
            // EXPLICIT-IDR-only (RFIs ride rfi_total and don't arm round-trips)
            // - see IdrRoundTripSnapshot.
            builder.addCount("idr_round_trip_request_total", idr.requestsTotal)
            builder.addCount("idr_round_trip_matched_total", idr.matchedTotal)
            builder.add("idr_round_trip_last_ms", idr.lastRoundTripMs)
        }
        builder.addCount("corruption_heuristic_total", snap.corruptionTotal)
        builder.add("corruption_heuristic_per_s", snap.corruptionPerSecond)
    }

    /// P1 AUDIO (the other stream): receive-quality totals + rates, output health
    /// (buffer fill / under-runs / over-runs), A/V sync drift, and the cold-start
    /// first-packet time. Numbers only; omitted entirely when no audio this tick.
    private static func ndjsonAudio(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        guard let audio = snap.audio else { return }
        builder.addCount("audio_packets_total", audio.packetsTotal)
        builder.addCount("audio_packets_lost_total", audio.packetsLostTotal)
        builder.addCount("audio_fec_recovered_total", audio.fecRecoveredTotal)
        // FEC blocks dropped on a parity/data size mismatch (counted, never a
        // silent permanent give-up).
        builder.addCount("audio_fec_mismatch_total", extras.audioFecMismatchTotal)
        builder.add("audio_pkts_per_s", audio.packetsPerSecond)
        builder.add("audio_loss_rate", audio.lossRate)
        builder.add("audio_fec_recovery_rate", audio.fecRecoveryRate)
        builder.add("audio_buffer_fill_ms", audio.bufferFillMs)
        builder.add("audio_resampler_ppm", audio.resamplerPpm)
        builder.add("audio_buffer_fill_min_ms", audio.bufferFillMinMs)
        // The adaptive target the fill is steered toward - fill vs target is
        // the cushion judge (base 30 / cap 150 / ceiling 190).
        builder.add("audio_playout_target_ms", extras.audioPlayoutTargetMs)
        builder.addCount("audio_underrun_total", audio.underrunTotal)
        builder.addCount("audio_overrun_total", audio.overrunTotal)
        // Designed playout-backlog trims (5ms chops), split out so the overrun
        // total above stays ceiling-backstop-only.
        builder.addCount("audio_trim_total", extras.audioTrimTotal)
        builder.add("audio_trims_per_s", extras.audioTrimsPerSecond)
        builder.addCount("audio_reprime_total", audio.rePrimeTotal)
        builder.add("audio_underruns_per_s", audio.underrunsPerSecond)
        builder.add("audio_overruns_per_s", audio.overrunsPerSecond)
        builder.add("audio_clock_drift_ms", audio.audioClockDriftMs)
        // av_skew_ms - the true CROSS-STREAM A/V alignment, deliberately next
        // to the wall-clock drift it must never be confused with. SIGN: + =
        // audio late (behind video). Derived per the formerly-deferred recipe
        // (both streams ride the host capture clock; the two hot-path stores
        // now exist - last-presented video RTP at the renderer-enqueue site,
        // last-scheduled audio RTP at the decode hand-off) with the buffer
        // fill converting schedule-head to playhead. Pair-anchored epoch: a
        // small constant bias rides along - trend and steps are the signal.
        // Absent (not 0) while either stream is dark/stale or re-anchoring;
        // rebase_total makes every mid-session re-baseline countable. THIS
        // call is the accumulating one (the scorecard percentiles feed at
        // exactly this 1Hz cadence; the prom render derives without feeding).
        builder.add("av_skew_ms", AudioVideoSkewStore.shared.deriveSkewMs(
            bufferFillMs: audio.bufferFillMs, accumulate: true))
        builder.addCount("av_skew_rebase_total", AudioVideoSkewStore.shared.rebaseTotal)
        // The live learned LOSS FLOOR under the playout target (the decay
        // limit-cycle fix) - absent until first learned, so a floor-held
        // target is legible against the evidence holding it.
        let cushionFloorMs = AudioCushionTelemetry.shared.floorMs
        builder.add("audio_cushion_floor_ms", cushionFloorMs > 0 ? cushionFloorMs : nil)
        let cushionSeedMs = AudioCushionTelemetry.shared.seedMs
        builder.add("audio_cushion_seed_ms", cushionSeedMs > 0 ? cushionSeedMs : nil)
        builder.add("audio_first_packet_ms", audio.firstPacketMs)
    }

    /// P1 DECODE/VT state + PRESENT/DISPLAY fields. Decode: the (re)create count +
    /// the live state (hw-decode / pixel format / bit depth / colorspace). Present:
    /// the stale-frame-repeat total + per-second rate, the EDR-headroom trend, and
    /// the HDR-engaged / screen / ProMotion state. Numbers, bools, and labels only.
    private static func ndjsonDecodeDisplay(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.addCount("decoder_recreate_total", snap.decoderRecreateTotal)
        if let state = snap.decodeState {
            builder.addBool("decode_hw", state.hwDecode)
            builder.addString("decode_pixel_format", state.pixelFormat)
            builder.addInt("decode_bit_depth", state.bitDepth)
            builder.addString("decode_colorspace", state.colorSpaceKey)
        }
        builder.addCount("present_stale_repeat_total", snap.staleFrameRepeatTotal)
        builder.add("present_stale_repeats_per_s", snap.staleRepeatsPerSecond)
        // Over-target force-releases (zero in steady state; a per-second spike
        // is the due-gate self-oscillation signature).
        builder.addCount("pacer_over_target_release_total", extras.pacerOverTargetReleaseTotal)
        builder.add("pacer_over_target_releases_per_s", extras.pacerOverTargetReleasesPerSecond)
        builder.add("edr_headroom_min", snap.edrHeadroomMin)
        builder.add("edr_headroom_avg", snap.edrHeadroomAvg)
        builder.add("edr_headroom_max", snap.edrHeadroomMax)
        if let display = snap.displayState {
            builder.addBool("hdr_engaged", display.hdrEngaged)
            builder.addString("screen", display.screenName)
            builder.addBool("promotion_capable", display.proMotionCapable)
            builder.addInt("max_refresh_hz", display.maxRefreshHz)
        }
    }

    private static func ndjsonFrames(_ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot) {
        builder.add("fps_received", snap.receivedFps)
        builder.add("fps_decoded", snap.decodedFps)
        builder.add("fps_rendered", snap.renderedFps)
        builder.add("decode_ema_ms", snap.decodeEmaMs)
        builder.add("present_cadence_err_ms", snap.presentCadenceErrorMs)
        builder.addCount("present_on_time", snap.presentOnTimeCount)
        builder.addCount("present_late", snap.presentLateCount)
        builder.add("host_encode_min_ms", snap.hostEncodeLatencyMinMs)
        builder.add("host_encode_avg_ms", snap.hostEncodeLatencyAvgMs)
        builder.add("host_encode_max_ms", snap.hostEncodeLatencyMaxMs)
    }

    private static func ndjsonNetwork(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.add("recv_jitter_ms", snap.recvJitterMs)
        builder.add("fec_recovery_rate", snap.fecRecoveryRate)
        builder.add("fec_reorder_hold_ms", snap.fecReorderHoldMs)
        builder.add("fec_headroom_level", snap.fecHeadroomLevel.map(Double.init))
        builder.add("fec_loss_level", snap.fecLossLevel.map(Double.init))
        builder.add("fec_percentage", snap.fecPercentage.map(Double.init))
        builder.add("fec_parity_margin", snap.fecParityMargin.map(Double.init))
        builder.add("pkts_per_s", snap.packetsPerSecond)
        // FRACTIONAL ms (high-res local clock): emit the Double with decimals via
        // `add` (jsonNumber → %.3f) instead of truncating to Int, so a sub-ms RTT
        // like 8.73 ms is preserved in the telemetry stream.
        builder.add("rtt_ms", snap.rttMs)
        builder.add("rtt_var_ms", snap.rttVarianceMs)
        // P1 receive-quality (derived from the RTP seq/arrival of packets WE get).
        builder.add("pre_fec_loss_rate", snap.preFecLossRate)
        builder.add("out_of_order_rate", snap.outOfOrderRate)
        builder.add("duplicate_rate", snap.duplicateRate)
        builder.add("goodput_mbps", snap.goodputMbps)
        builder.add("negotiated_bitrate_mbps", snap.negotiatedBitrateMbps)
        builder.add("goodput_utilization", snap.goodputUtilization)
        builder.add("packet_gap_p50_us", snap.packetGapP50Us)
        builder.add("packet_gap_p95_us", snap.packetGapP95Us)
        builder.add("packet_gap_max_us", snap.packetGapMaxUs)
        builder.addInt("enet_sent_reliable", snap.enetSentReliable)
        builder.addInt("enet_oldest_unacked_ms", snap.enetOldestUnackedMs.map(Int.init))
        builder.addInt("enet_since_last_ack_ms", snap.enetSinceLastAckMs.map(Int.init))
        builder.addCount("enet_retransmit_total", snap.enetRetransmitTotal)
        // Unknown inbound control datagrams ignored (the volume the
        // once-per-type log suppression would otherwise hide).
        builder.addCount("ctrl_ignored_total", extras.ctrlIgnoredTotal)
        // Per-socket GAP-EVENT totals (video=net_ / audio_ / enet_ × the
        // 20/50/100ms thresholds): the honest link-health counters - the
        // jitter EWMA and the windowed gap gauges above are provably blind to
        // rare 40-110ms blips. All three sockets ride this one section so the
        // NIC-doze discriminator ("all sockets gapped together" vs one path)
        // is a single row query, present from t=0 even before audio flows.
        // The enet_ family counts reliable-ACK DELAYS (first send → matched
        // ACK, measured in handleAcknowledge), not raw arrival gaps: the
        // control channel is quiet by design between messages (its idle cadence
        // otherwise reads as a flood of fake >100ms "gaps" on a clean link),
        // and arrival-gap gating was blind during input-idle - exactly where
        // NIC doze lives. ACK-delay data is the comparable "host answered late"
        // leg beside net_/audio_.
        builder.addCount("net_gaps_over_20ms_total", extras.videoGapOver20msTotal)
        builder.addCount("net_gaps_over_50ms_total", extras.videoGapOver50msTotal)
        builder.addCount("net_gaps_over_100ms_total", extras.videoGapOver100msTotal)
        builder.addCount("audio_gaps_over_20ms_total", extras.audioGapOver20msTotal)
        builder.addCount("audio_gaps_over_50ms_total", extras.audioGapOver50msTotal)
        builder.addCount("audio_gaps_over_100ms_total", extras.audioGapOver100msTotal)
        builder.addCount("enet_gaps_over_20ms_total", extras.enetGapOver20msTotal)
        builder.addCount("enet_gaps_over_50ms_total", extras.enetGapOver50msTotal)
        builder.addCount("enet_gaps_over_100ms_total", extras.enetGapOver100msTotal)
    }

    private static func ndjsonPacingDrops(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.addInt("pacing_depth", snap.pacingQueueDepth)
        builder.addInt("pacing_target_depth", snap.pacingAdaptiveTargetDepth)
        builder.addInt("decode_backlog", snap.inFlightDecodeBacklog)
        // Pacer tick/release rates - the direct display-link-callback-miss
        // measure (a ticks/s deficit below the refresh Hz is missed callbacks).
        builder.add("pacer_ticks_per_s", extras.pacerTicksPerSecond)
        builder.add("pacer_releases_per_s", extras.pacerReleasesPerSecond)
        builder.addCount("drops_decoder", snap.dropsDecoder)
        builder.addCount("drops_backpressure", snap.dropsBackpressure)
        builder.addCount("drops_presentation_late", snap.dropsPresentationLate)
        // Designed suppressed-mode drops + the 0/1 context gauge, split from
        // drops_presentation_late so that counter stays a genuine-lateness
        // signal while the window is backgrounded.
        builder.addCount("drops_suppressed_total", extras.suppressedDropTotal)
        builder.addBool("present_suppressed", extras.presentSuppressed)
        // The THIRD hidden-window state: gated (decode stopped after ~2s of
        // continuous suppression) + its quiet drops, so fps_decoded=0 with
        // drops_suppressed flat self-labels instead of reading as a wedge.
        builder.addBool("decode_gated", extras.decodeGated)
        builder.addCount("drops_decode_gated_total", extras.decodeGatedDropTotal)
    }

    private static func ndjsonInputRefresh(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.add("input_events_per_s", snap.inputEventsPerSecond)
        builder.add("input_flush_per_s", snap.inputFlushPerSecond)
        builder.addCount("input_idle_to_active_total", snap.inputIdleToActiveTotal)
        builder.add("input_since_last_ms", snap.timeSinceLastInputMs)
        // Host rumble RECEIVED at dispatch (pre-guard) + the invalid-drop
        // sibling - the shipped feature's volume signal, riding the input
        // section it correlates with. events − dropped = deposited.
        builder.addCount("rumble_events_total", extras.rumbleEventTotal)
        builder.add("rumble_events_per_s", extras.rumbleEventsPerSecond)
        builder.addCount("rumble_dropped_invalid_total", extras.rumbleDroppedInvalidTotal)
        builder.add("refresh_min_hz", snap.refreshMinHz)
        builder.add("refresh_avg_hz", snap.refreshAvgHz)
        builder.add("refresh_max_hz", snap.refreshMaxHz)
        builder.addBool("refresh_changed", snap.refreshChanged)
    }

    private static func ndjsonFrameSizeThermalProcess(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot
    ) {
        builder.add("frame_bytes_avg", snap.avgFrameBytes)
        builder.addInt("frame_bytes_max", snap.maxFrameBytes)
        builder.add("frame_idr_percent", snap.idrFramePercent)
        builder.addInt("thermal_state", snap.thermalState)
        builder.addBool("low_power_mode", snap.lowPowerModeEnabled)
        builder.add("cpu_percent", snap.processCpuPercent)
        builder.addInt("thread_count", snap.threadCount)
    }

    /// P1 RESOURCE (the P-vs-E-core visibility signal): the per-thread CPU/QoS view
    /// (as a nested `threads` array so each hot line keeps name+cpu+qos together),
    /// the SoC P-cluster vs E-cluster active residency, the memory footprint, and
    /// the AC/battery flags. The threads array is the one nested structure the
    /// flat builder emits as a raw field; it is capped upstream
    /// (`ResourceTelemetry.maxThreadsEmitted`) so a line stays bounded.
    private static func ndjsonResource(_ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot) {
        if let resource = snap.resource {
            if !resource.threads.isEmpty {
                let entries = resource.threads.map { thread -> String in
                    "{\"name\":\"\(jsonStringEscape(resource.threadLabel(thread)))\","
                        + "\"cpu_percent\":\(jsonNumber(thread.cpuPercent)),"
                        + "\"qos\":\(thread.qos),"
                        + "\"qos_label\":\"\(jsonStringEscape(thread.qosLabel))\"}"
                }
                builder.addRaw(["\"threads\":[\(entries.joined(separator: ","))]"])
            }
            builder.addCount("phys_footprint_bytes", resource.physFootprintBytes)
            builder.addBool("on_battery", resource.onBattery)
            builder.addBool("battery_charging", resource.batteryCharging)
        }
        if let cluster = snap.clusterResidency {
            builder.add("soc_ecluster_active", cluster.eClusterActive)
            builder.add("soc_pcluster_active", cluster.pClusterActive)
            builder.addInt("soc_ecluster_channels", cluster.eClusterCount)
            builder.addInt("soc_pcluster_channels", cluster.pClusterCount)
            // IOReport bring-up #2 (T2 export keys): package watts + GPU
            // residency (0..100, unlike the 0..1 cluster fields above) off the
            // same once-per-tick sampler delta the prom family reads. A nil
            // gauge (group unavailable / first-tick baseline) omits its key -
            // fail-quiet, absent ≠ 0.
            builder.add("package_power_w", cluster.packagePowerW)
            builder.add("gpu_residency_percent", cluster.gpuResidencyPercent)
        }
    }

    private static func ndjsonEventCounters(_ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot) {
        builder.addCount("rfi_total", snap.rfiTotal)
        builder.addCount("idr_requested_total", snap.idrRequestedTotal)
        builder.addCount("backlog_overflow_total", snap.backlogOverflowTotal)
        builder.addCount("present_stall_total", snap.presentStallTotal)
        builder.addCount("frame_loss_total", snap.frameLossTotal)
        builder.addCount("unrecoverable_frame_total", snap.unrecoverableFrameTotal)
        builder.addCount("pacer_disabled_total", snap.pacerDisabledTotal)
        builder.addCount("bookmark_total", snap.bookmarkTotal)
    }

    /// LINK fields: the stream ROUTE pair first, then the Wi-Fi radio (signal
    /// 3). Two truths, deliberately distinct keys:
    ///   * stream_link / stream_if - the interface the stream's packets
    ///     actually traverse (StreamRouteProbe). THE field that gates the
    ///     env-signal layer; "wired" here with wifi_link:"wifi" below is the
    ///     normal docked-laptop case, not a contradiction.
    ///   * wifi_* - the ASSOCIATED RADIO's state, whether or not the stream
    ///     rides it (a wired session still reads wifi_link:"wifi" on every
    ///     row, truthfully - about the radio). Kept as-is for continuity.
    /// Radio physics + ssid/band only when associated; addString skips nil.
    private static func ndjsonLink(
        _ builder: inout NDJSONBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        if let routeSnapshot = extras.streamRoute {
            builder.addString("stream_link", routeSnapshot.linkLabel)
            builder.addString("stream_if", routeSnapshot.interfaceName)
        }
        // ENV-SIGNAL shadow state + the conditional-keepalive judge fields -
        // they ride the link section because the link IS their evidence.
        // Transitions additionally get their own `event:"env_state"` row with
        // the full evidence vector (see EnvSignalController).
        builder.addInt("env_state", extras.envStateOrdinal)
        builder.addString("env_state_label", extras.envStateLabel)
        builder.addCount("env_state_changes_total", extras.envStateChangesTotal)
        builder.add("keepalive_interval_ms", extras.keepaliveIntervalMs)
        builder.addCount("pings_sent_video_total", extras.videoPingsSentTotal)
        builder.addCount("pings_sent_audio_total", extras.audioPingsSentTotal)
        builder.add("pings_video_per_s", extras.videoPingsPerSecond)
        builder.add("pings_audio_per_s", extras.audioPingsPerSecond)
        guard let wifi = snap.wifi else { return }
        builder.addString("wifi_link", wifi.linkState.label)
        builder.addInt("wifi_rssi_dbm", wifi.rssiDbm)
        builder.add("wifi_tx_rate_mbps", wifi.txRateMbps)
        builder.addInt("wifi_noise_dbm", wifi.noiseDbm)
        builder.addString("wifi_ssid", wifi.ssid)
        builder.addInt("wifi_channel", wifi.channel)
        builder.addString("wifi_band", wifi.band)
    }

    /// Per-stage latency NDJSON fields: p50/p95/p99 derived from the histogram
    /// buckets for a quick tail (the Prometheus side ships raw _bucket/_sum/_count
    /// so Grafana can compute its own quantiles over any window). Includes the
    /// headline glass-to-glass (signal 1) + the input-to-photon estimate (signal
    /// 2). Returns the rendered `"key":value` fields (empty when no histogram
    /// data this tick).
    static func ndjsonLatencyFields(_ snap: TelemetrySnapshot) -> [String] {
        guard let histograms = snap.latencyHistograms else { return [] }
        var fields: [String] = []
        func addStage(_ prefix: String, _ stage: LatencyHistogramSnapshot.Stage) {
            func add(_ key: String, _ value: Double?) {
                guard let value, value.isFinite else { return }
                fields.append("\"\(key)\":\(jsonNumber(value))")
            }
            add("\(prefix)_p50_ms", histogramQuantile(0.50, stage: stage))
            add("\(prefix)_p95_ms", histogramQuantile(0.95, stage: stage))
            add("\(prefix)_p99_ms", histogramQuantile(0.99, stage: stage))
        }
        addStage("lat_recv_to_assemble", histograms.receiveToAssemble)
        addStage("lat_assemble_to_submit", histograms.assembleToSubmit)
        addStage("lat_decode_submit_to_output", histograms.submitToOutput)
        addStage("lat_output_to_present", histograms.outputToPresent)
        addStage("lat_end_to_end", histograms.endToEnd)
        addStage("glass_to_glass", histograms.glassToGlass)
        addStage("input_to_photon_est", histograms.inputToPhoton)
        // DECODE time split by frame type (signal: DECODE).
        addStage("decode_idr", histograms.decodeIDR)
        addStage("decode_p", histograms.decodeP)
        // IDR/RFI round-trip distribution (signal: IDR-RTT).
        addStage("idr_round_trip", histograms.idrRoundTrip)
        return fields
    }

    /// ROLLING 60s latency NDJSON fields: the same p50/p95/p99 derivation as
    /// `ndjsonLatencyFields`, but over the 60s windowed difference the exporter
    /// folds per tick - so the offline forensics can tell "is bad" from "was
    /// bad" without Grafana's `rate()` windows. Cumulative fields stay; only
    /// the five `lat_*` pipeline stages and the headline glass-to-glass get the
    /// `_60s` variant to bound row bloat. A stage with zero observations in the
    /// window emits nothing (absent, not a stale number - a suppressed/gated
    /// minute stays honest). Empty when the rig has no data this tick.
    ///
    /// READ SEMANTICS: (1) after presents stop,
    /// the windowed values hold near their last numbers for up to ~60s (the
    /// window still covers an AGING population) before the keys go absent -
    /// `frames_in_window_60s` makes that staleness machine-detectable: a
    /// shrinking count means the percentiles describe ever-older frames; (2)
    /// presented-frame percentiles are SURVIVOR-BIASED - dropped frames never
    /// enter the histograms, so a stall barely moves them. Alert on tick
    /// deficit / late-drop deltas, never on percentile flatness.
    static func ndjsonRollingLatencyFields(_ extras: TelemetrySnapshot.Extras) -> [String] {
        guard let rolling = extras.latencyRolling60s else { return [] }
        var fields: [String] = []
        // Emitted even at 0 (unlike the stages) - 0 is exactly the signal that
        // distinguishes "stale window" from "live but quiet". endToEnd is the
        // per-present spine, so its count IS the presented-frames-in-window.
        fields.append("\"frames_in_window_60s\":\(rolling.endToEnd.observationCount)")
        func addStage(_ prefix: String, _ stage: LatencyHistogramSnapshot.Stage) {
            func add(_ key: String, _ value: Double?) {
                guard let value, value.isFinite else { return }
                fields.append("\"\(key)\":\(jsonNumber(value))")
            }
            add("\(prefix)_p50_60s_ms", histogramQuantile(0.50, stage: stage))
            add("\(prefix)_p95_60s_ms", histogramQuantile(0.95, stage: stage))
            add("\(prefix)_p99_60s_ms", histogramQuantile(0.99, stage: stage))
        }
        addStage("lat_recv_to_assemble", rolling.receiveToAssemble)
        addStage("lat_assemble_to_submit", rolling.assembleToSubmit)
        addStage("lat_decode_submit_to_output", rolling.submitToOutput)
        addStage("lat_output_to_present", rolling.outputToPresent)
        addStage("lat_end_to_end", rolling.endToEnd)
        addStage("glass_to_glass", rolling.glassToGlass)
        return fields
    }

    /// Escape a string for a JSON value (NDJSON). Backslash, double-quote, and
    /// control chars an SSID or label could carry. Kept minimal - the rig only
    /// ever emits ASCII labels (SSIDs, band names) plus the build SHA/date.
    static func jsonStringEscape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// JSON number with the same integer/decimal discipline as the Prometheus
    /// formatter - avoids exponent notation that some NDJSON readers choke on.
    static func jsonNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }
}

// MARK: - Process metrics

/// Process-level CPU% (sum of thread CPU usage, in percent of one core) + live
/// thread count, via the Mach task threads port. Sampled at 1Hz from the
/// exporter - cheap (one `task_threads` + per-thread `thread_info`); not on any
/// hot path. Mirrors the approach `MacSystemStats` uses for system CPU but
/// scoped to THIS process so the rig measures Glimmer's own footprint.
enum ProcessMetrics {

    /// Map `ProcessInfo.ThermalState` to a 0...3 ordinal (nominal/fair/serious/
    /// critical) so it plots as a gauge and a Grafana threshold (≥2 = serious) is
    /// trivial. Unknown future cases map to 0 (nominal) defensively.
    static func thermalOrdinal(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    /// One CPU% + thread-count sample for the current process.
    static func sample() -> (cpuPercent: Double, threadCount: Int) {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else {
            return (0, 0)
        }
        defer {
            // Release the thread port rights + the array allocation.
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT is a C macro (struct size in integer_t units),
        // not bridged to Swift - derive it from the type layout.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var totalCpu: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = basicInfoCount
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if infoResult == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                totalCpu += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return (totalCpu, Int(threadCount))
    }
}
