//
//  TelemetryExporter+RenderP2.swift
//
//  The PROMETHEUS render for the P2 SESSION-LIFECYCLE signals, split out of
//  TelemetryExporter+Render.swift to keep that file under the length budget. It
//  appends to the SAME `PromBuilder` (made module-internal there) so the body
//  stays one document; the NDJSON half lives in TelemetryExporter+RenderNDJSON.swift
//  and the session report in TelemetrySessionReport.swift.
//
//  Four signals: the CONNECT-HANDSHAKE breakdown (per-stage gauges), the
//  RECONNECT count + disconnect REASON (counter + ordinal gauge + info label),
//  the IDR/RFI ROUND-TRIP counts + last RTT (the distribution rides the latency
//  histogram in the main render), and the CORRUPTION/ARTIFACT heuristic (counter +
//  per-second rate). All numbers/labels - no secrets.
//

import Foundation

extension TelemetryRenderer {

    /// Render the P2 session-lifecycle section onto the shared builder.
    static func promSessionLifecycle(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        promHandshake(&builder, snap)
        promReconnectDisconnect(&builder, snap)
        promIdrRoundTrip(&builder, snap)
        promCorruption(&builder, snap)
    }

    /// CONNECT-HANDSHAKE breakdown: per-stage connect timing as gauges (the
    /// one-shot whole-session view; the NDJSON also carries an explicit one-time
    /// `event:"handshake"` line for a grep). Each leg is absent when its stage
    /// never fired (an aborted-early connect).
    private static func promHandshake(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard let handshake = snap.handshake else { return }
        builder.emit("glimmer_handshake_rtsp_ms",
                     "RTSP/SDP handshake duration this session, ms (connect breakdown).",
                     handshake.rtspMs)
        builder.emit("glimmer_handshake_pairing_ms",
                     "Pairing/auth leg (RTSP-done → ENet-connect start) this session, ms.",
                     handshake.pairingMs)
        builder.emit("glimmer_handshake_enet_connect_ms",
                     "ENet control-channel connect (CONNECT → START_A/B ACKed) this session, ms.",
                     handshake.enetConnectMs)
        builder.emit("glimmer_handshake_first_frame_ms",
                     "Connection-established → first decoded video frame this session, ms.",
                     handshake.firstFrameMs)
        builder.emit("glimmer_handshake_total_ms",
                     "Whole cold-open: connect start → first decoded frame this session, ms.",
                     handshake.totalMs)
    }

    /// RECONNECT count + disconnect REASON. The reason is BOTH an ordinal gauge
    /// (for thresholding) and an info gauge carrying the label (for a glanceable
    /// scrape).
    private static func promReconnectDisconnect(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emitCounter("glimmer_reconnect_total",
                            "Reconnects this run (a connection re-established after a drop).",
                            snap.reconnectTotal)
        builder.emit("glimmer_disconnect_reason",
                     "Disconnect reason ordinal (0 none, 1 user, 2 host-clean, 3 host-error, "
                     + "4 watchdog-stall, 5 connect-failed).",
                     Double(snap.disconnectReason.rawValue))
        builder.emitInfo("glimmer_disconnect_reason_info",
                         "Disconnect reason as a label (value always 1).",
                         labels: [("reason", snap.disconnectReason.label)])
        // PROCESS-GLOBAL per-reason tally: the durable disconnect record. The
        // per-session ordinal/info above is latched then torn down <1ms later (vs a
        // 1s scrape), so this monotonic counter family - kept out of the session
        // reset - is what a scrape actually catches the reason from.
        builder.emitCounterFamily(
            "glimmer_disconnect_total",
            "Disconnects this PROCESS by reason (monotonic; survives session resets).",
            key: "reason",
            rows: snap.disconnectByReason.map { (label: $0.label, value: $0.total) })
    }

    /// IDR ROUND-TRIP counts + last measured RTT (the distribution is the
    /// `glimmer_idr_round_trip_ms` histogram in the main render). EXPLICIT
    /// REQUEST_IDR sends only - RFIs ride `glimmer_rfi_total` and don't arm
    /// round-trips (conflating them made requests/matched unreadable).
    private static func promIdrRoundTrip(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard let idr = snap.idrRoundTrip else { return }
        builder.emitCounter("glimmer_idr_round_trip_request_total",
                            "Explicit IDR requests that started a round-trip measurement "
                            + "(RFIs ride rfi_total; they don't arm round-trips).",
                            idr.requestsTotal)
        builder.emitCounter("glimmer_idr_round_trip_matched_total",
                            "Explicit IDR requests matched to an arriving IDR/recovery frame.",
                            idr.matchedTotal)
        builder.emit("glimmer_idr_round_trip_last_ms",
                     "Most recent measured IDR round-trip (request-send → arrival), ms.",
                     idr.lastRoundTripMs)
    }

    /// CORRUPTION/ARTIFACT heuristic: the cheap white/purple-flash-class detector
    /// (VT decode-status error / depacketizer discontinuity - no per-pixel scan).
    private static func promCorruption(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emitCounter("glimmer_corruption_heuristic_total",
                            "Corruption/artifact heuristic hits (VT decode-status error or "
                            + "depacketizer discontinuity - the white/purple-flash class).",
                            snap.corruptionTotal)
        builder.emit("glimmer_corruption_heuristic_per_second",
                     "Corruption/artifact heuristic hits per second (spike = visible artifacting).",
                     snap.corruptionPerSecond)
    }
}
