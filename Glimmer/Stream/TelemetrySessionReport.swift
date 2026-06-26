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
//  Two pieces live here:
//    * `SessionAggregate` - the running per-tick rollup the exporter folds each
//      1Hz snapshot into (fps min/avg/max, peak depth, worst windows), GATE-
//      AWARE: each tick is classified active/gated/bring-up/resume and
//      the headline numbers cover ACTIVE seconds only (see the type doc). The
//      raw session-wide latency percentiles still come from the cumulative
//      histograms at stop (lossless); the aggregate additionally stitches an
//      ACTIVE-seconds histogram out of the per-tick deltas for the headline.
//    * `SessionReport` - assembled at stop from the aggregate + the final
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

/// Per-session running rollup, folded one snapshot at a time on the exporter
/// queue. Tracks the things the cumulative latency histograms don't: fps
/// min/avg/max, peak pacing depth, and the worst single 1s windows for the
/// signals where a transient spike is the story.
///
/// GATE-AWARE: every tick is classified ACTIVE / GATED / BRING-UP /
/// RESUME before folding, and the HEADLINE numbers (fps min/avg/max, worst
/// windows, latency percentiles) are computed over ACTIVE seconds only. The
/// all-session versions lie: a long decode-gated AFK window working as designed
/// dragged a scorecard's fps-min to 0 and its worst cadence to tens of seconds,
/// and a cold-open bring-up era polluted the cumulative percentiles for minutes
/// after behavior normalized. The raw all-session values stay under
/// explicitly-named `*_raw` keys (with the worst second's segment tag), so
/// nothing is hidden - it is labeled.
struct SessionAggregate {

    /// One 1Hz tick's segment. Priority order is the classification order:
    /// a hidden (suppressed/gated) second is GATED even inside bring-up; a
    /// visible second inside the first ~10s is BRING-UP; a visible second
    /// within ~5s of an un-gate edge is RESUME; everything else is ACTIVE.
    enum TickSegment: String {
        case active
        case gated
        case bringUp = "bring_up"
        case resume
    }

    /// Bring-up era: connect-relative seconds treated as cold-open settling
    /// (game load / encoder ramp / cushion ratchet - content legitimately
    /// wild, not stream quality).
    static let bringUpSeconds = 10.0
    /// Resume corridor: seconds after an un-gate/un-suppress edge during
    /// which drops/cadence are designed catch-up (queued-frame drain, IDR
    /// resync), not steady-state quality.
    static let resumeCorridorSeconds = 5.0

    /// min / avg / max accumulator for a per-tick gauge. avg is the mean across
    /// ticks that had a value (a divide-by-`samples`), which for a 1Hz cadence is
    /// the per-second-averaged session mean.
    struct Stat {
        var min: Double?
        var max: Double?
        var sum: Double = 0
        var samples: Int = 0
        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            min = min.map { Swift.min($0, value) } ?? value
            max = max.map { Swift.max($0, value) } ?? value
            sum += value
            samples += 1
        }
        var avg: Double? { samples > 0 ? sum / Double(samples) : nil }
    }

    // ---- fps stats: HEADLINE over ACTIVE seconds, raw over every tick ----
    var receivedFps = Stat()
    var decodedFps = Stat()
    var renderedFps = Stat()
    var receivedFpsRaw = Stat()
    var decodedFpsRaw = Stat()
    var renderedFpsRaw = Stat()

    /// Peak pacing-queue depth seen across the whole session (the deepest the
    /// jitter buffer ever rode) - a latency-creep tell the live gauge misses.
    var peakPacingDepth: Int = 0

    // ---- Worst single 1s windows (the transient that defined the run) ----
    // Headline pair = worst ACTIVE second; `*Raw` = worst second of the whole
    // session, with the segment it landed in (a raw worst tagged `gated` or
    // `resume` is the instrument seeing a designed window, not the stream).
    /// Worst per-tick mean present-cadence error (ms) + the connect-relative
    /// second it happened on - the hitch a user feels, and exactly when.
    var worstPresentCadenceErrorMs: Double?
    var worstPresentCadenceErrorAtSeconds: Double?
    var worstPresentCadenceErrorRawMs: Double?
    var worstPresentCadenceErrorRawAtSeconds: Double?
    var worstPresentCadenceErrorRawSegment: TickSegment?
    /// Worst per-tick glass-to-glass p95 (ms) + when - the second the headline
    /// "how good is it" number was at its worst.
    var worstGlassToGlassP95Ms: Double?
    var worstGlassToGlassP95AtSeconds: Double?
    var worstGlassToGlassP95RawMs: Double?
    var worstGlassToGlassP95RawAtSeconds: Double?
    var worstGlassToGlassP95RawSegment: TickSegment?

    /// How many 1Hz ticks were folded in - a sanity/coverage count.
    var tickCount: Int = 0
    // ---- Per-segment second counts (ticks ≈ seconds at the 1Hz cadence) ----
    var activeTicks = 0
    var gatedTicks = 0
    var bringUpTicks = 0
    var resumeTicks = 0
    /// Previous tick's hidden (suppressed-or-gated) state - the edge detector
    /// that arms the resume corridor.
    private var prevTickHidden = false
    /// Connect-relative end of the live resume corridor, nil when none.
    private var resumeCorridorUntilSeconds: Double?

    // ---- ACTIVE-seconds latency accumulation ----
    /// Cumulative histogram snapshot from the PREVIOUS tick - the baseline the
    /// per-tick delta is sliced against.
    private var prevLatencyCumulative: LatencyHistogramSnapshot?
    /// Sum of the per-tick histogram deltas folded on ACTIVE ticks only - the
    /// scorecard's headline percentile source. The cumulative histograms stay
    /// the raw truth (`latency_raw`); this is the same data minus the
    /// gated/bring-up/resume seconds that polluted the cold-open reads.
    private(set) var activeLatency: LatencyHistogramSnapshot?

    /// Classify this tick AND advance the corridor state. Called once per
    /// capture tick, BEFORE `accumulate`, on the exporter queue.
    mutating func classifyTick(atSeconds seconds: Double, hidden: Bool) -> TickSegment {
        // Arm the resume corridor at the un-hide edge (gated/suppressed →
        // visible); a re-hide simply re-arms on its own next clear edge.
        if prevTickHidden && !hidden {
            resumeCorridorUntilSeconds = seconds + Self.resumeCorridorSeconds
        }
        prevTickHidden = hidden
        let segment: TickSegment
        if hidden {
            segment = .gated
        } else if seconds <= Self.bringUpSeconds {
            segment = .bringUp
        } else if let until = resumeCorridorUntilSeconds, seconds < until {
            segment = .resume
        } else {
            segment = .active
        }
        switch segment {
        case .active: activeTicks += 1
        case .gated: gatedTicks += 1
        case .bringUp: bringUpTicks += 1
        case .resume: resumeTicks += 1
        }
        return segment
    }

    /// Fold one tick's CUMULATIVE histogram snapshot: slice the per-tick delta
    /// off the previous tick's baseline and add it to the active accumulation
    /// iff this tick is ACTIVE. Must be called EVERY tick (the baseline has to
    /// advance through gated spans too, or the first active tick after one
    /// would swallow the whole hidden era's observations).
    mutating func foldLatency(_ current: LatencyHistogramSnapshot, active: Bool) {
        defer { prevLatencyCumulative = current }
        guard active else { return }
        // First-ever active tick with no baseline can't happen in practice
        // (bring-up ticks precede it and arm the baseline), but fall back to
        // the cumulative-so-far rather than dropping the tick if it does.
        let delta = prevLatencyCumulative.map {
            LatencyRollingWindow.difference(current, minus: $0)
        } ?? current
        activeLatency = activeLatency.map { LatencyRollingWindow.sum($0, plus: delta) } ?? delta
    }

    // ---- ENV-SIGNAL shadow-session judge inputs ----
    /// Ticks (~seconds) spent in each env state (index = the state ordinal:
    /// clear/caution/distress) + the final transition count - "how long was
    /// each state, and how often did it move" is the scorecard half of
    /// judging the shadow state machine against felt events.
    var envStateSeconds = [Int](repeating: 0, count: 3)
    var envStateChangesTotal: UInt64 = 0

    /// Fold one tick's env state. Called on the exporter queue right after
    /// `accumulate` (the env fields ride Extras, not the snapshot).
    mutating func noteEnvState(ordinal: Int, changesTotal: UInt64) {
        if envStateSeconds.indices.contains(ordinal) { envStateSeconds[ordinal] += 1 }
        envStateChangesTotal = changesTotal
    }

    /// Fold one per-second snapshot into the rollup. Called on the exporter
    /// queue, after `classifyTick` decided this tick's segment.
    mutating func accumulate(_ snap: TelemetrySnapshot, segment: TickSegment) {
        tickCount += 1
        let isActive = segment == .active
        if let value = snap.receivedFps {
            receivedFpsRaw.add(value)
            if isActive { receivedFps.add(value) }
        }
        if let value = snap.decodedFps {
            decodedFpsRaw.add(value)
            if isActive { decodedFps.add(value) }
        }
        if let value = snap.renderedFps {
            renderedFpsRaw.add(value)
            if isActive { renderedFps.add(value) }
        }
        if let depth = snap.pacingQueueDepth { peakPacingDepth = Swift.max(peakPacingDepth, depth) }

        if let err = snap.presentCadenceErrorMs {
            if err > (worstPresentCadenceErrorRawMs ?? -1) {
                worstPresentCadenceErrorRawMs = err
                worstPresentCadenceErrorRawAtSeconds = snap.sinceConnectSeconds
                worstPresentCadenceErrorRawSegment = segment
            }
            if isActive, err > (worstPresentCadenceErrorMs ?? -1) {
                worstPresentCadenceErrorMs = err
                worstPresentCadenceErrorAtSeconds = snap.sinceConnectSeconds
            }
        }
        // Worst glass-to-glass: use the per-tick p95 from the histogram so a
        // single bad second stands out (the cumulative session p95 would smear
        // it). Cheap - the histogram snapshot is already on the snapshot.
        if let histograms = snap.latencyHistograms,
           let p95 = TelemetryRenderer.histogramQuantile(0.95, stage: histograms.glassToGlass) {
            if p95 > (worstGlassToGlassP95RawMs ?? -1) {
                worstGlassToGlassP95RawMs = p95
                worstGlassToGlassP95RawAtSeconds = snap.sinceConnectSeconds
                worstGlassToGlassP95RawSegment = segment
            }
            if isActive, p95 > (worstGlassToGlassP95Ms ?? -1) {
                worstGlassToGlassP95Ms = p95
                worstGlassToGlassP95AtSeconds = snap.sinceConnectSeconds
            }
        }
    }
}

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

    /// Render the report as a single pretty-ish JSON object (hand-built so field
    /// order is stable + readable, and nil fields are simply omitted - same
    /// discipline as the NDJSON renderer). One file, one glance.
    func renderJSON() -> String {
        var top: [String] = []
        top.append("\"schema\":\"glimmer.session_report.v1\"")
        top.append("\"session\":\"\(sessionId)\"")
        top.append("\"client\":\"\(client)\"")
        top.append("\"host\":\"\(host)\"")
        top.append("\"generated\":\"\(generatedISO8601)\"")
        top.append("\"build\":{\"commit\":\"\(buildCommit)\",\"date\":\"\(buildDate)\"}")
        top.append("\"duration_s\":\(num(durationSeconds))")
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
        top.append("\"latency_raw\":\(latencyObject(histograms))")
        top.append("\"events\":\(eventsObject())")
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
        // ENV-SIGNAL shadow scorecard: seconds-in-state + transition count -
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
            if let value = stat.min { parts.append("\"min\":\(num(value))") }
            if let value = stat.avg { parts.append("\"avg\":\(num(value))") }
            if let value = stat.max { parts.append("\"max\":\(num(value))") }
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
    /// estimate sit alongside the sub-stages.
    private func latencyObject(_ histograms: LatencyHistogramSnapshot?) -> String {
        guard let histograms else { return "{}" }
        func stage(_ name: String, _ stage: LatencyHistogramSnapshot.Stage) -> String? {
            guard stage.hasObservations else { return nil }
            var parts: [String] = []
            if let value = TelemetryRenderer.histogramQuantile(0.50, stage: stage) {
                parts.append("\"p50_ms\":\(num(value))")
            }
            if let value = TelemetryRenderer.histogramQuantile(0.95, stage: stage) {
                parts.append("\"p95_ms\":\(num(value))")
            }
            if let value = TelemetryRenderer.histogramQuantile(0.99, stage: stage) {
                parts.append("\"p99_ms\":\(num(value))")
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
        ].compactMap { $0 }
        return "{" + entries.joined(separator: ",") + "}"
    }

    /// P2 CONNECT-HANDSHAKE breakdown - per-stage cold-open timing (ms). Read off
    /// the always-live `p2` state captured during the handshake. nil legs omitted.
    private func handshakeObject() -> String {
        let breakdown = counters.p2.handshakeBreakdown()
        var parts: [String] = []
        func add(_ key: String, _ value: Double?) {
            if let value, value.isFinite { parts.append("\"\(key)\":\(num(value))") }
        }
        add("rtsp_ms", breakdown.rtspMs)
        add("pairing_ms", breakdown.pairingMs)
        add("enet_connect_ms", breakdown.enetConnectMs)
        add("first_frame_ms", breakdown.firstFrameMs)
        add("total_ms", breakdown.totalMs)
        add("click_to_first_frame_ms", breakdown.clickToFirstFrameMs)
        add("launch_path_ms", breakdown.launchPathMs)
        return "{" + parts.joined(separator: ",") + "}"
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
            parts.append("\"idr_round_trip_last_ms\":\(num(last))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// AUDIO-TTF scorecard line: the one-shot time-to-first-decoded-audio plus
    /// the warm/cold host-bring-up classification (keyed on ping→first-RTP vs
    /// `AudioTtfContext.warmPingToRtpThresholdMs`), the host-idle covariate
    /// behind it, and the startup-pacing verdict. Read off the always-live TTF
    /// context the audio receive path latched; empty object when audio never
    /// arrived (absent fields, never a fake 0).
    private func audioTtfObject() -> String {
        var parts: [String] = []
        if let ttf = counters.audioFirstPacketMs { parts.append("\"ttf_ms\":\(num(ttf))") }
        if let record = counters.audioTtf.latched {
            parts.append("\"ttf_class\":\"\(record.ttfClass)\"")
            if let ping = record.pingToRtpMs { parts.append("\"ping_to_rtp_ms\":\(num(ping))") }
            if let idle = record.hostIdleSeconds { parts.append("\"host_idle_s\":\(num(idle))") }
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
            "\"min\":\(num(skew.minMs))",
            "\"avg\":\(num(skew.avgMs))",
            "\"p50\":\(num(skew.p50Ms))",
            "\"p95\":\(num(skew.p95Ms))",
            "\"p99\":\(num(skew.p99Ms))",
            "\"max\":\(num(skew.maxMs))",
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
            "\"min\":\(num(skew.minMs))",
            "\"avg\":\(num(skew.avgMs))",
            "\"p50\":\(num(skew.p50Ms))",
            "\"p95\":\(num(skew.p95Ms))",
            "\"p99\":\(num(skew.p99Ms))",
            "\"max\":\(num(skew.maxMs))"
        ]
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// ENV-SIGNAL shadow scorecard: per-state tick counts (~seconds at the
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
            ("audio_overrun", counters.audioOverrunTotal.value),
            ("audio_trim", counters.audioTrimTotal.value),
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
            var inner = "\"value_ms\":\(num(value))"
            if let at { inner += ",\"at_t_connect_s\":\(num(at))" }
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

    /// Same integer/decimal discipline as the NDJSON/Prometheus renderers so the
    /// report reads consistently and no NDJSON reader chokes on exponent form.
    private func num(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }
}
