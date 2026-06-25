//
//  TelemetryExporter+RenderNetwork.swift
//
//  The PROMETHEUS render for the NETWORK metric families: transport health
//  (jitter / RTT / FEC / ENet reliable-channel), the P1 receive-quality block
//  (pre-FEC loss, reordering, goodput, inter-packet gaps), and the Wi-Fi radio
//  gauges. Split from TelemetryExporter+Render.swift - pure move, same
//  file-split idiom as the FramePacer split - to keep that file under the length
//  budget. Each section appends to the SAME `PromBuilder` (declared there) so
//  the body stays one document.
//

import Foundation

extension TelemetryRenderer {

    // MARK: - Network families

    static func promNetwork(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.emit("glimmer_net_recv_jitter_ms", "RFC3550 smoothed receive jitter, ms.", snap.recvJitterMs)
        builder.emit("glimmer_net_fec_recovery_rate",
                     "Fraction of frames needing Reed-Solomon recovery this window.", snap.fecRecoveryRate)
        // FEC HEALTH (read-only observability): the FecHeadroomController's response
        // (reorder-hold + both headroom axes) and the per-frame parity headroom, so a
        // degrading link's escalation is visible, not only in the diag log. Clean-link
        // baseline: hold ≈ 24ms, both levels 0, a comfortable positive parity margin.
        builder.emit("glimmer_fec_reorder_hold_ms",
                     "Live FEC reorder-hold window the receiver applies, ms (base 24, cap 48).",
                     snap.fecReorderHoldMs)
        builder.emit("glimmer_fec_headroom_level",
                     "FEC headroom jitter/out-of-order/retransmit axis level (0 = clean link).",
                     snap.fecHeadroomLevel.map(Double.init))
        builder.emit("glimmer_fec_loss_level",
                     "FEC headroom direct-loss axis level (0 = clean link).",
                     snap.fecLossLevel.map(Double.init))
        builder.emit("glimmer_fec_percentage",
                     "Host-driven per-frame FEC percentage (latest frame).",
                     snap.fecPercentage.map(Double.init))
        builder.emit("glimmer_fec_parity_margin",
                     "Spare parity shards left on the worst FEC-RECOVERED frame this window "
                     + "(parity - data deficit); absent on windows with no recovery. Trends "
                     + "toward 0 before a frame goes unrecoverable.",
                     snap.fecParityMargin.map(Double.init))
        // AWDL helper: awdl0 parked + how hard macOS fights it back up (resuppress
        // climbs on a contested link, ~0 on a clean one). Emit 0 (not absent) when
        // the helper never engaged, so off != missing-data for degraded-link coverage.
        builder.emit("glimmer_awdl_suppressing",
                     "awdl0 parked by the Wi-Fi helper this stream (1 = parked, 0 = not/helper off).",
                     (snap.awdlSuppressing ?? false) ? 1.0 : 0.0)
        builder.emit("glimmer_awdl_resuppress_total",
                     "Times macOS re-raised awdl0 this stream - the AWDL-contention rate the helper fights "
                     + "(per-stream; high on a contested link).",
                     snap.awdlReSuppressTotal.map(Double.init))
        builder.emit("glimmer_net_packets_per_second", "Video packets received per second.", snap.packetsPerSecond)
        builder.emit("glimmer_net_rtt_ms", "ENet RTT estimate (high-res local clock), ms.", snap.rttMs)
        builder.emit("glimmer_net_rtt_variance_ms", "ENet RTT variance, ms.", snap.rttVarianceMs)
        promReceiveQuality(&builder, snap)
        builder.emit("glimmer_enet_sent_reliable",
                     "Outstanding reliable ENet commands (climbs before a stall).",
                     snap.enetSentReliable.map(Double.init))
        builder.emit("glimmer_enet_oldest_unacked_ms", "Age of the oldest unacked reliable command, ms.",
                     snap.enetOldestUnackedMs.map(Double.init))
        builder.emit("glimmer_enet_since_last_ack_ms", "Time since the last matched ACK, ms.",
                     snap.enetSinceLastAckMs.map(Double.init))
        builder.emitCounter("glimmer_enet_retransmit_total",
                            "Reliable-channel retransmits (climbs before a control-stream stall).",
                            snap.enetRetransmitTotal)
        builder.emitCounter("glimmer_ack_silence_near_miss_total",
                            "ACK-silence near-misses: silence crossed a deep RTT multiple short "
                            + "of the 10s dead-peer cutoff and recovered (near-death blip).",
                            snap.ackSilenceNearMissTotal)
        builder.emitCounter("glimmer_ctrl_ignored_total",
                            "Unknown inbound control datagrams ignored (ACKed, decrypted, discarded).",
                            extras.ctrlIgnoredTotal)
        promGapEvents(&builder, extras)
    }

    /// Per-socket inter-arrival GAP-EVENT counter families (video/audio/ENet ×
    /// 20/50/100ms): the honest link-health signal - the jitter EWMA and the
    /// windowed gap gauges are blind to rare 40-110ms blips, so these COUNT
    /// them. All three sockets emit from this one network section (not the
    /// audio family) so every socket is present from t=0 and the NIC-doze
    /// discriminator ("all sockets gapped together" vs one path stalled) is a
    /// same-section query.
    private static func promGapEvents(
        _ builder: inout PromBuilder, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.emitCounter("glimmer_net_gaps_over_20ms_total",
                            "Video-socket inter-arrival gaps over 20ms.", extras.videoGapOver20msTotal)
        builder.emitCounter("glimmer_net_gaps_over_50ms_total",
                            "Video-socket inter-arrival gaps over 50ms.", extras.videoGapOver50msTotal)
        builder.emitCounter("glimmer_net_gaps_over_100ms_total",
                            "Video-socket inter-arrival gaps over 100ms.", extras.videoGapOver100msTotal)
        builder.emitCounter("glimmer_audio_gaps_over_20ms_total",
                            "Audio-socket inter-arrival gaps over 20ms.", extras.audioGapOver20msTotal)
        builder.emitCounter("glimmer_audio_gaps_over_50ms_total",
                            "Audio-socket inter-arrival gaps over 50ms.", extras.audioGapOver50msTotal)
        builder.emitCounter("glimmer_audio_gaps_over_100ms_total",
                            "Audio-socket inter-arrival gaps over 100ms.", extras.audioGapOver100msTotal)
        builder.emitCounter("glimmer_enet_gaps_over_20ms_total",
                            "ENet-socket inter-arrival gaps over 20ms (host PINGs et al).",
                            extras.enetGapOver20msTotal)
        builder.emitCounter("glimmer_enet_gaps_over_50ms_total",
                            "ENet-socket inter-arrival gaps over 50ms.", extras.enetGapOver50msTotal)
        builder.emitCounter("glimmer_enet_gaps_over_100ms_total",
                            "ENet-socket inter-arrival gaps over 100ms.", extras.enetGapOver100msTotal)
    }

    /// P1 NETWORK receive-quality: pre-FEC loss / out-of-order / duplicate rates,
    /// received goodput vs the negotiated ceiling, and the inter-packet-gap
    /// distribution (microburst detector) - all derived purely from the RTP
    /// seq/arrival of packets WE receive (no host tool).
    private static func promReceiveQuality(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emit("glimmer_net_pre_fec_loss_rate",
                     "Pre-FEC packet-loss rate (lost/expected from RTP seq, before recovery).",
                     snap.preFecLossRate)
        builder.emit("glimmer_net_out_of_order_rate",
                     "Out-of-order (reorder) packet rate this window (reordered/received).",
                     snap.outOfOrderRate)
        builder.emit("glimmer_net_duplicate_rate",
                     "Duplicate packet rate this window (duplicates/received).", snap.duplicateRate)
        builder.emit("glimmer_net_goodput_mbps",
                     "Measured received goodput (bytes/s into the pipeline), Mbps.", snap.goodputMbps)
        builder.emit("glimmer_net_negotiated_bitrate_mbps",
                     "Negotiated stream bitrate ceiling, Mbps (goodput baseline).",
                     snap.negotiatedBitrateMbps)
        builder.emit("glimmer_net_goodput_utilization",
                     "Received goodput as a fraction of the negotiated ceiling (0..1+).",
                     snap.goodputUtilization)
        builder.emit("glimmer_net_packet_gap_p50_us",
                     "Inter-packet arrival gap p50 this window, microseconds.", snap.packetGapP50Us)
        builder.emit("glimmer_net_packet_gap_p95_us",
                     "Inter-packet arrival gap p95 this window, microseconds (microburst tell).",
                     snap.packetGapP95Us)
        builder.emit("glimmer_net_packet_gap_max_us",
                     "Inter-packet arrival gap max this window, microseconds.", snap.packetGapMaxUs)
    }

    /// ENV-SIGNAL shadow state + the conditional-keepalive judge family: the
    /// CLEAR/CAUTION/DISTRESS ordinal (with its label), the transition count,
    /// the LIVE keepalive cadence, and the per-socket pings_sent counters -
    /// the counters that make a keepalive-cadence change judgeable from data.
    /// Absent before the controller's first fed tick.
    static func promEnvSignal(
        _ builder: inout PromBuilder, _ extras: TelemetrySnapshot.Extras
    ) {
        if let ordinal = extras.envStateOrdinal {
            builder.emitLabeled(
                "glimmer_env_state",
                "Env-signal link state ordinal (0 clear, 1 caution, 2 distress) - SHADOW mode.",
                Double(ordinal), labels: [("state", extras.envStateLabel ?? "unknown")])
        }
        if let changes = extras.envStateChangesTotal {
            builder.emitCounter("glimmer_env_state_changes_total",
                                "Env-signal state transitions this session.", changes)
        }
        builder.emit("glimmer_keepalive_interval_ms",
                     "Live steady keepalive ping cadence, ms (75 fast / 500 relaxed, conditional).",
                     extras.keepaliveIntervalMs)
        if let pings = extras.videoPingsSentTotal {
            builder.emitCounter("glimmer_video_pings_sent_total",
                                "Video-socket keepalive pings sent (the cadence judge).", pings)
        }
        if let pings = extras.audioPingsSentTotal {
            builder.emitCounter("glimmer_audio_pings_sent_total",
                                "Audio-socket keepalive pings sent (the cadence judge).", pings)
        }
    }

    /// Wi-Fi radio (signal 3): RSSI / PHY tx-rate / noise gauges with ssid+band
    /// labels, plus a link-state gauge so a dashboard tells associated-Wi-Fi from
    /// wired/unassociated. On Ethernet the radio gauges are absent (no radio) and
    /// only the link-state gauge is emitted - the honest "there is no radio here".
    static func promWiFi(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard let wifi = snap.wifi else { return }
        // link-state is always emitted (even wired) so "wired" is distinguishable
        // from "telemetry never sampled the radio".
        builder.emitLabeled(
            "glimmer_wifi_link_state",
            "Wi-Fi link state ordinal (0 associated, 1 unassociated, 2 wired).",
            Double(wifi.linkState.rawValue), labels: [("link", wifi.linkState.label)])
        // Radio physics carry ssid+band labels (both omitted when unknown - e.g.
        // SSID needs Location auth on macOS 14+, band resolves regardless).
        var labels: [(String, String)] = []
        if let ssid = wifi.ssid { labels.append(("ssid", ssid)) }
        if let band = wifi.band { labels.append(("band", band)) }
        if let channel = wifi.channel { labels.append(("channel", String(channel))) }
        builder.emitLabeled(
            "glimmer_wifi_rssi_dbm", "Wi-Fi received signal strength, dBm (closer to 0 = stronger).",
            wifi.rssiDbm.map(Double.init), labels: labels)
        builder.emitLabeled(
            "glimmer_wifi_tx_rate_mbps", "Wi-Fi negotiated PHY / transmit rate, Mbps.",
            wifi.txRateMbps, labels: labels)
        builder.emitLabeled(
            "glimmer_wifi_noise_dbm", "Wi-Fi noise floor, dBm (RSSI − noise = effective SNR).",
            wifi.noiseDbm.map(Double.init), labels: labels)
    }
}
