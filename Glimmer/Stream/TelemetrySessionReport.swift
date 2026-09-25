//
//  TelemetrySessionReport.swift
//
//  The one-shot SESSION REPORT (signal 5b) for the opt-in telemetry exporter: a
//  single glanceable scorecard written next to the per-second NDJSON when a stream
//  stops.
//  It answers "how was THIS run?" in one file - duration, the p50/p95/p99 of every
//  latency stage (incl. the headline glass-to-glass + the input-to-photon
//  estimate), fps stats, event counts (rfi/idr/loss/freeze/recovery/stall/
//  overflow/bookmark), the worst 1s windows, peak pacing depth, and the build SHA
//  so a run is attributable to a build for regression tracking.
//
//  Two pieces make up the report:
//    * `SessionAggregate` - the running per-tick rollup the exporter folds each
//      1Hz snapshot into (fps min/avg/max, peak depth, worst windows), GATE-
//      AWARE: each tick is classified active/gated/bring-up/resume and
//      the headline numbers cover ACTIVE seconds only (see the type doc). The
//      raw session-wide latency percentiles still come from the cumulative
//      histograms at stop (lossless); the aggregate additionally stitches an
//      ACTIVE-seconds histogram out of the per-tick deltas for the headline.
//      It is a pure move into TelemetrySessionAggregate.swift, so both units
//      stay under the file-length budget.
//    * `SessionReport` (this file) - assembled at stop from the aggregate + the final
//      histograms + the counters, and rendered to JSON by hand (same
//      integer/decimal discipline as the rest of the exporter; nil fields
//      omitted).
//
//  GATING + SAFETY: this is built/used only on the gate-on path (the exporter
//  that owns it exists only when telemetry is opt-in ON). The accumulation runs
//  on the exporter's serial queue per 1Hz tick - never a hot path. Secret-free:
//  every field is a performance number, an event count, the opaque session id,
//  or the build SHA/date.
//

import Foundation

/// The assembled scorecard, rendered to JSON at stop. Plain value type built on
/// the exporter queue from the aggregate + final histograms + counters.
struct SessionReport {
    let sessionId: String
    let client: String
    let host: String
    let buildCommit: String
    let buildDate: String
    let generatedISO8601: String
    let durationSeconds: Double
    let aggregate: SessionAggregate
    let histograms: LatencyHistogramSnapshot?
    let counters: TelemetryCounters
    /// Stages kept outside the per-tick snapshot (input legs, RFI recovery), so
    /// they have no active-seconds form and ride `latency_raw` only.
    var sessionWideStages: [(String, LatencyHistogramSnapshot.Stage)] = []

    /// Render the report as a single pretty-ish JSON object (hand-built so field
    /// order is stable + readable, and nil fields are simply omitted - same
    /// discipline as the NDJSON renderer). One file, one glance.
    func renderJSON() -> String {
        var top: [String] = []
        top.append("\"schema\":\"glimmer.session_report.v1\"")
        top.append("\"session\":\"\(sessionId)\"")
        top.append("\"client\":\"\(TelemetryRenderer.jsonStringEscape(client))\"")
        top.append("\"host\":\"\(TelemetryRenderer.jsonStringEscape(host))\"")
        top.append("\"generated\":\"\(generatedISO8601)\"")
        top.append("\"build\":{\"commit\":\"\(buildCommit)\",\"date\":\"\(buildDate)\"}")
        top.append("\"duration_s\":\(TelemetryRenderer.jsonNumber(durationSeconds))")
        top.append("\"ticks\":\(aggregate.tickCount)")
        // GATE-AWARE segmentation: per-segment second counts first, so
        // every headline below reads against its denominator. `fps`/`latency`/
        // `worst_windows` are ACTIVE-seconds; the `*_raw` keys are all-session.
        top.append("\"segments\":\(segmentsObject())")
        top.append("\"fps\":\(fpsObject(active: true))")
        top.append("\"fps_raw\":\(fpsObject(active: false))")
        top.append("\"peak_pacing_depth\":\(aggregate.peakPacingDepth)")
        top.append("\"latency_basis\":\"\(aggregate.activeLatency != nil ? "active_seconds" : "all_session")\"")
        top.append("\"latency\":\(latencyObject(aggregate.activeLatency ?? histograms))")
        top.append("\"latency_raw\":\(latencyObject(histograms, extra: sessionWideStages))")
        top.append("\"events\":\(eventsObject())")
        // REORDER-DISPLACEMENT invariant: how late reorders arrived vs the hold
        // that must outlast them. hold_exceeded > 0 is the only alertable value;
        // an empty block (wired, no reorders) omits the quantiles cleanly.
        top.append("\"reorder_displacement\":\(reorderDisplacementObject())")
        top.append("\"worst_windows\":\(worstWindowsObject())")
        // P2 SESSION-LIFECYCLE: the connect-handshake breakdown + the disconnect
        // reason - the "how did this run open and why did it end" line.
        top.append("\"handshake\":\(handshakeObject())")
        top.append("\"lifecycle\":\(lifecycleObject())")
        // AUDIO-TTF: the cold-start span + warm/cold classification + the
        // host-idle covariate, so cross-session comparison is one jq over
        // report files instead of re-parsing event rows.
        top.append("\"audio_ttf\":\(audioTtfObject())")
        // A/V SKEW percentiles (SIGN: + = audio late/behind video), from the
        // 1Hz pair-anchored RTP derivation - the lip-sync cost the adaptive
        // cushion silently trades; the cushion-ceiling policy reads THIS line.
        // NB: av_skew is cushion-INCLUSIVE (its magnitude is mostly the playout
        // cushion); the cushion-free TRUE sync signal is av_clock_skew_ms below.
        top.append("\"av_skew_ms\":\(avSkewObject())")
        // A/V CLOCK SKEW percentiles (cushion SUBTRACTED) - the genuine host↔Mac
        // sync error (~±15ms), vs the cushion-dominated av_skew_ms above.
        top.append("\"av_clock_skew_ms\":\(avClockSkewObject())")
        // Per-TYPE ignored-control totals - durable here (the teardown Diag
        // NOTICE is lossy: a crash or a still-running session loses it).
        top.append("\"ctrl_ignored_by_type\":\(ctrlIgnoredByTypeObject())")
        // ENV-SIGNAL scorecard: seconds-in-state + transition count -
        // the per-session judge for the state machine (DISTRESS seconds are
        // EXCLUDED from present-path quality reads, never added).
        top.append("\"env\":\(envObject())")
        return "{" + top.joined(separator: ",") + "}\n"
    }

    // MARK: - Sub-objects

    /// Per-segment second counts - the denominators that make the
    /// headline-vs-raw split legible at a glance: a session that was 90%
    /// gated AFK self-describes as such on the first line.
    private func segmentsObject() -> String {
        let parts = [
            "\"active_s\":\(aggregate.activeTicks)",
            "\"gated_s\":\(aggregate.gatedTicks)",
            "\"bring_up_s\":\(aggregate.bringUpTicks)",
            "\"resume_s\":\(aggregate.resumeTicks)"
        ]
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func fpsObject(active: Bool) -> String {
        func stat(_ name: String, _ stat: SessionAggregate.Stat) -> String? {
            var parts: [String] = []
            if let value = stat.min { parts.append("\"min\":\(TelemetryRenderer.jsonNumber(value))") }
            if let value = stat.avg { parts.append("\"avg\":\(TelemetryRenderer.jsonNumber(value))") }
            if let value = stat.max { parts.append("\"max\":\(TelemetryRenderer.jsonNumber(value))") }
            guard !parts.isEmpty else { return nil }
            return "\"\(name)\":{" + parts.joined(separator: ",") + "}"
        }
        let entries = [
            stat("received", active ? aggregate.receivedFps : aggregate.receivedFpsRaw),
            stat("decoded", active ? aggregate.decodedFps : aggregate.decodedFpsRaw),
            stat("rendered", active ? aggregate.renderedFps : aggregate.renderedFpsRaw)
        ].compactMap { $0 }
        return "{" + entries.joined(separator: ",") + "}"
    }

    /// p50/p95/p99 per latency stage from the given snapshot - called with the
    /// ACTIVE-seconds accumulation for the headline `latency` key (basis under
    /// `latency_basis`; falls back to cumulative for a session too short to
    /// have any active seconds) and with the FINAL cumulative histograms for
    /// `latency_raw`. The headline glass-to-glass + the input-to-photon
    /// estimate sit alongside the sub-stages; `extra` appends standalone stages.
    private func latencyObject(
        _ histograms: LatencyHistogramSnapshot?,
        extra: [(String, LatencyHistogramSnapshot.Stage)] = []
    ) -> String {
        guard let histograms else { return "{}" }
        func stage(_ name: String, _ stage: LatencyHistogramSnapshot.Stage) -> String? {
            guard stage.hasObservations else { return nil }
            var parts: [String] = []
            if let value = TelemetryRenderer.histogramQuantile(0.50, stage: stage) {
                parts.append("\"p50_ms\":\(TelemetryRenderer.jsonNumber(value))")
            }
            if let value = TelemetryRenderer.histogramQuantile(0.95, stage: stage) {
                parts.append("\"p95_ms\":\(TelemetryRenderer.jsonNumber(value))")
            }
            if let value = TelemetryRenderer.histogramQuantile(0.99, stage: stage) {
                parts.append("\"p99_ms\":\(TelemetryRenderer.jsonNumber(value))")
            }
            parts.append("\"count\":\(stage.observationCount)")
            return "\"\(name)\":{" + parts.joined(separator: ",") + "}"
        }
        let entries = [
            stage("recv_to_assemble", histograms.receiveToAssemble),
            stage("assemble_to_submit", histograms.assembleToSubmit),
            stage("decode_submit_to_output", histograms.submitToOutput),
            stage("output_to_present", histograms.outputToPresent),
            stage("end_to_end", histograms.endToEnd),
            stage("glass_to_glass", histograms.glassToGlass),
            stage("input_to_photon_est", histograms.inputToPhoton),
            // DECODE time split by frame type (signal: DECODE).
            stage("decode_idr", histograms.decodeIDR),
            stage("decode_p", histograms.decodeP),
            // IDR/RFI round-trip (signal: IDR-RTT).
            stage("idr_round_trip", histograms.idrRoundTrip)
        ].compactMap { $0 } + extra.compactMap { stage($0.0, $0.1) }
        return "{" + entries.joined(separator: ",") + "}"
    }

    /// REORDER-DISPLACEMENT block: quantiles from the tracker's displacement
    /// histogram (present only when reorders occurred - a wired session emits
    /// counts + hold + exceeded with no quantiles, so downstream jq never
    /// divides by zero), plus the always-live session maxes and the invariant
    /// violation counter.
    private func reorderDisplacementObject() -> String {
        var parts: [String] = []
        if let disp = counters.reorderDisplacement {
            parts.append("\"hold_ms\":\(TelemetryRenderer.jsonNumber(disp.holdMs))")
            parts.append("\"max_ms\":\(TelemetryRenderer.jsonNumber(disp.maxMs))")
            parts.append("\"max_packets\":\(disp.maxPackets)")
        }
        parts.append("\"hold_exceeded\":\(counters.reorderHoldExceededTotal.value)")
        if let stage = FrameTimingTracker.shared?.reorderDisplacementMs.snapshotValue(),
           stage.hasObservations {
            parts.append("\"count\":\(stage.observationCount)")
            if let value = TelemetryRenderer.histogramQuantile(0.50, stage: stage) {
                parts.append("\"p50_ms\":\(TelemetryRenderer.jsonNumber(value))")
            }
            if let value = TelemetryRenderer.histogramQuantile(0.999, stage: stage) {
                parts.append("\"p999_ms\":\(TelemetryRenderer.jsonNumber(value))")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// P2 CONNECT-HANDSHAKE breakdown - the session's FIRST connect, per-stage
    /// (ms); after an in-place reconnect the latest connect's legs ride
    /// `reconnect_last`. nil legs omitted.
    private func handshakeObject() -> String {
        let current = counters.p2.handshakeBreakdown()
        guard let first = counters.p2.firstConnect else {
            return "{" + handshakeLegs(current).joined(separator: ",") + "}"
        }
        let last = "\"reconnect_last\":{" + handshakeLegs(current).joined(separator: ",") + "}"
        return "{" + (handshakeLegs(first.handshake) + [last]).joined(separator: ",") + "}"
    }

    private func handshakeLegs(_ breakdown: HandshakeBreakdown) -> [String] {
        var parts: [String] = []
        func add(_ key: String, _ value: Double?) {
            if let value, value.isFinite { parts.append("\"\(key)\":\(TelemetryRenderer.jsonNumber(value))") }
        }
        add("rtsp_ms", breakdown.rtspMs)
        add("control_setup_ms", breakdown.controlSetupMs)
        add("enet_connect_ms", breakdown.enetConnectMs)
        add("first_frame_ms", breakdown.firstFrameMs)
        add("total_ms", breakdown.totalMs)
        add("click_to_first_frame_ms", breakdown.clickToFirstFrameMs)
        add("launch_path_ms", breakdown.launchPathMs)
        return parts
    }

    /// P2 lifecycle summary - the disconnect reason (ordinal + label), the
    /// reconnect count, and the IDR round-trip request/matched tally
    /// (EXPLICIT IDRs only; RFIs ride `events.rfi`).
    private func lifecycleObject() -> String {
        let reason = counters.p2.disconnectReason
        var parts: [String] = [
            "\"disconnect_reason\":\(reason.rawValue)",
            "\"disconnect_reason_label\":\"\(reason.label)\"",
            "\"reconnects\":\(counters.reconnectTotal.value)",
            "\"wakes\":\(counters.wakeTotal.value)",
            "\"idr_round_trip_requests\":\(counters.idrRoundTripRequestTotal.value)",
            "\"idr_round_trip_matched\":\(counters.idrRoundTripMatchedTotal.value)"
        ]
        if let last = counters.p2.lastIdrRoundTripMs {
            parts.append("\"idr_round_trip_last_ms\":\(TelemetryRenderer.jsonNumber(last))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// AUDIO-TTF line: time to first audio, warm/cold class, host idle and startup
    /// verdict: the first connect's, or the latest's if the first heard none. A
    /// session that heard none says `never` with the audio ping count.
    private func audioTtfObject() -> String {
        let first = counters.p2.firstConnect.flatMap { $0.audioTtfMs != nil ? $0 : nil }
        let ttfMs = first?.audioTtfMs ?? counters.audioFirstPacketMs
        let latched = first.map(\.audioTtf) ?? counters.audioTtf.latched
        if ttfMs == nil, counters.audioPacketsTotal.value == 0 {
            return "{\"never\":true,\"pings\":\(EnvSignalController.shared.audioPingsSentTotal.value)}"
        }
        var parts: [String] = []
        if let ttfMs { parts.append("\"ttf_ms\":\(TelemetryRenderer.jsonNumber(ttfMs))") }
        if let record = latched {
            parts.append("\"ttf_class\":\"\(record.ttfClass)\"")
            if let ping = record.pingToRtpMs { parts.append("\"ping_to_rtp_ms\":\(TelemetryRenderer.jsonNumber(ping))") }
            if let idle = record.hostIdleSeconds { parts.append("\"host_idle_s\":\(TelemetryRenderer.jsonNumber(idle))") }
            if let startup = record.startup { parts.append("\"startup\":\"\(startup)\"") }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// A/V-SKEW scorecard line (SIGN: + = audio late/behind video): session
    /// percentiles of the 1Hz `av_skew_ms` derivation, read off the
    /// self-locked skew store the NDJSON tick feeds. `rebases` counts
    /// mid-session pair re-anchors so a stepped baseline self-describes.
    /// Empty object when the meter never had both streams flowing.
    private func avSkewObject() -> String {
        guard let skew = AudioVideoSkewStore.shared.sessionSummary() else { return "{}" }
        let parts: [String] = [
            "\"samples\":\(skew.samples)",
            "\"min\":\(TelemetryRenderer.jsonNumber(skew.minMs))",
            "\"avg\":\(TelemetryRenderer.jsonNumber(skew.avgMs))",
            "\"p50\":\(TelemetryRenderer.jsonNumber(skew.p50Ms))",
            "\"p95\":\(TelemetryRenderer.jsonNumber(skew.p95Ms))",
            "\"p99\":\(TelemetryRenderer.jsonNumber(skew.p99Ms))",
            "\"max\":\(TelemetryRenderer.jsonNumber(skew.maxMs))",
            "\"rebases\":\(skew.rebases)"
        ]
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// A/V CLOCK-SKEW scorecard line: session percentiles of the CUSHION-FREE
    /// true clock skew (the genuine host↔Mac sync error the drift resampler
    /// corrects), from the same pair-anchored derivation as av_skew_ms but
    /// without the playout cushion baked in. Empty object when the meter never
    /// had both streams flowing.
    private func avClockSkewObject() -> String {
        guard let skew = AudioVideoSkewStore.shared.clockSkewSessionSummary() else { return "{}" }
        let parts: [String] = [
            "\"samples\":\(skew.samples)",
            "\"min\":\(TelemetryRenderer.jsonNumber(skew.minMs))",
            "\"avg\":\(TelemetryRenderer.jsonNumber(skew.avgMs))",
            "\"p50\":\(TelemetryRenderer.jsonNumber(skew.p50Ms))",
            "\"p95\":\(TelemetryRenderer.jsonNumber(skew.p95Ms))",
            "\"p99\":\(TelemetryRenderer.jsonNumber(skew.p99Ms))",
            "\"max\":\(TelemetryRenderer.jsonNumber(skew.maxMs))"
        ]
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// ENV-SIGNAL scorecard: per-state tick counts (~seconds at the
    /// 1Hz cadence) + the transition total, plus the final per-socket
    /// pings_sent counts (the keepalive cadence judge).
    private func envObject() -> String {
        let parts: [String] = [
            "\"clear_s\":\(aggregate.envStateSeconds[0])",
            "\"caution_s\":\(aggregate.envStateSeconds[1])",
            "\"distress_s\":\(aggregate.envStateSeconds[2])",
            "\"state_changes\":\(aggregate.envStateChangesTotal)",
            "\"pings_sent_video\":\(EnvSignalController.shared.videoPingsSentTotal.value)",
            "\"pings_sent_audio\":\(EnvSignalController.shared.audioPingsSentTotal.value)"
        ]
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Per-TYPE ignored-control totals, keyed by the control type word as hex
    /// ("0x5502") to match the Diag first-sighting lines. Bounded upstream
    /// (`CtrlIgnoredPerType.maxTrackedTypes`); sorted so the report is stable
    /// across runs. Empty object when nothing was ignored.
    private func ctrlIgnoredByTypeObject() -> String {
        let entries = counters.ctrlIgnoredPerType.totals
            .sorted { $0.key < $1.key }
            .map { "\"\(String(format: "0x%04x", $0.key))\":\($0.value)" }
        return "{" + entries.joined(separator: ",") + "}"
    }

    /// Final monotonic event counts - the run's tally of every notable event,
    /// including the user's "that felt bad" bookmark presses.
    private func eventsObject() -> String {
        let pairs: [(String, UInt64)] = [
            ("rfi", counters.rfiTotal.value),
            ("idr_requested", counters.idrRequestedTotal.value),
            ("frame_loss", counters.frameLossTotal.value),
            ("unrecoverable_frame", counters.unrecoverableFrameTotal.value),
            ("backlog_overflow", counters.backlogOverflowTotal.value),
            ("present_stall", counters.presentStallTotal.value),
            ("pacer_disabled", counters.pacerDisabledTotal.value),
            ("bookmark", counters.bookmarkTotal.value),
            ("cruise_boosted_batches", counters.cruiseBoostedBatchesTotal.value),
            ("cruise_identity_batches", counters.cruiseIdentityBatchesTotal.value),
            // P1 NETWORK session tallies: the run's on-the-wire receive-quality
            // totals (all from the RTP seq of packets WE received) + the reliable
            // retransmit count - the "how was the link this run" line.
            ("pre_fec_packets_lost", counters.videoPacketsLostPreFecTotal.value),
            ("packets_out_of_order", counters.videoPacketsOutOfOrderTotal.value),
            ("packets_duplicate", counters.videoPacketsDuplicateTotal.value),
            ("enet_retransmit", counters.enetRetransmitTotal.value),
            ("ctrl_ignored", counters.ctrlIgnoredTotal.value),
            // P1 DECODE/PRESENT session tallies: VT (re)creates this run + the
            // stale-frame repeat count (the invisible-stutter total) + the
            // over-target force-releases and the designed suppressed-mode /
            // decode-gated drops.
            ("decoder_recreate", counters.decoderRecreateTotal.value),
            ("discontinuity_flush", counters.discontinuityFlushTotal.value),
            ("present_stale_repeat", counters.staleFrameRepeatTotal.value),
            ("pacer_over_target_release", counters.pacerOverTargetReleaseTotal.value),
            ("tick_miss_descheduled", counters.tickMissDescheduledTotal.value),
            ("tick_miss_coalesced", counters.tickMissCoalescedTotal.value),
            // The finer direct-promptness split (starved thread vs skipped vsync).
            ("tick_miss_preempted", counters.tickMissPreemptedTotal.value),
            ("tick_miss_linkskip", counters.tickMissLinkskipTotal.value),
            ("suppressed_drop", counters.suppressedDropTotal.value),
            ("drops_decode_gated", counters.decodeGatedDropTotal.value),
            // Per-socket GAP-EVENT tallies (the honest link-health counts the
            // jitter EWMA was blind to) + host rumble dispatched to actuators.
            ("net_gaps_over_20ms", counters.videoGapOver20msTotal.value),
            ("net_gaps_over_50ms", counters.videoGapOver50msTotal.value),
            ("net_gaps_over_100ms", counters.videoGapOver100msTotal.value),
            ("audio_gaps_over_20ms", counters.audioGapOver20msTotal.value),
            ("audio_gaps_over_50ms", counters.audioGapOver50msTotal.value),
            ("audio_gaps_over_100ms", counters.audioGapOver100msTotal.value),
            ("enet_gaps_over_20ms", counters.enetGapOver20msTotal.value),
            ("enet_gaps_over_50ms", counters.enetGapOver50msTotal.value),
            ("enet_gaps_over_100ms", counters.enetGapOver100msTotal.value),
            ("rumble_events", counters.rumbleEventTotal.value),
            ("rumble_dropped_invalid", counters.rumbleDroppedInvalidTotal.value),
            // P1 AUDIO session tallies (the other stream): the run's on-the-wire
            // audio loss + FEC recovery (+ mismatch-dropped blocks) + the output
            // under-run/over-run/designed-trim counts - the "how was audio this
            // run" line alongside the video tallies.
            ("audio_packets", counters.audioPacketsTotal.value),
            ("audio_packets_lost", counters.audioPacketsLostTotal.value),
            ("audio_fec_recovered", counters.audioFecRecoveredTotal.value),
            ("audio_fec_mismatch", counters.audioFecMismatchTotal.value),
            ("audio_underrun", counters.audioUnderrunTotal.value),
            ("audio_underrun_deadair", counters.audioUnderrunDeadairTotal.value),
            ("audio_overrun", counters.audioOverrunTotal.value),
            ("audio_trim", counters.audioTrimTotal.value),
            ("audio_receive_failed", counters.audioReceiveFailedTotal.value),
            // P2 session tallies: the run's reconnect count + the corruption/
            // artifact heuristic total (the white/purple-flash-class tally).
            ("reconnect", counters.reconnectTotal.value),
            ("wake", counters.wakeTotal.value),
            ("corruption_heuristic", counters.corruptionHeuristicTotal.value)
        ]
        let entries = pairs.map { "\"\($0.0)\":\($0.1)" }
        return "{" + entries.joined(separator: ",") + "}"
    }

    /// The worst single 1s windows + the connect-relative second they hit - jump
    /// straight to the moment the run was at its worst. Headline entries cover
    /// ACTIVE seconds; the `*_raw` siblings cover every second and carry the
    /// worst second's segment, so a 41s "worst cadence" that was really an AFK
    /// decode-gate window arrives pre-labeled instead of pre-alarming.
    private func worstWindowsObject() -> String {
        var parts: [String] = []
        func entry(
            _ key: String, _ value: Double?, at: Double?,
            segment: SessionAggregate.TickSegment? = nil
        ) {
            guard let value else { return }
            var inner = "\"value_ms\":\(TelemetryRenderer.jsonNumber(value))"
            if let at { inner += ",\"at_t_connect_s\":\(TelemetryRenderer.jsonNumber(at))" }
            if let segment { inner += ",\"segment\":\"\(segment.rawValue)\"" }
            parts.append("\"\(key)\":{\(inner)}")
        }
        entry("present_cadence_error", aggregate.worstPresentCadenceErrorMs,
              at: aggregate.worstPresentCadenceErrorAtSeconds)
        entry("present_cadence_error_raw", aggregate.worstPresentCadenceErrorRawMs,
              at: aggregate.worstPresentCadenceErrorRawAtSeconds,
              segment: aggregate.worstPresentCadenceErrorRawSegment)
        entry("glass_to_glass_p95", aggregate.worstGlassToGlassP95Ms,
              at: aggregate.worstGlassToGlassP95AtSeconds)
        entry("glass_to_glass_p95_raw", aggregate.worstGlassToGlassP95RawMs,
              at: aggregate.worstGlassToGlassP95RawAtSeconds,
              segment: aggregate.worstGlassToGlassP95RawSegment)
        return "{" + parts.joined(separator: ",") + "}"
    }
}
