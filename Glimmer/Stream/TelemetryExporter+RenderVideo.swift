//
//  TelemetryExporter+RenderVideo.swift
//
//  The PROMETHEUS render for the VIDEO-PIPELINE metric families: frame/decode
//  rates, pacing, drops, display refresh, frame size/type, the pipeline event
//  counters, the per-stage latency histograms, the live decode state, and the
//  present/display health. Split from TelemetryExporter+Render.swift - pure
//  move, same file-split idiom as the FramePacer split - to keep that file
//  under the length budget. Each section appends to the SAME `PromBuilder`
//  (declared there) so the body stays one document; the naming conventions
//  live in that file's header.
//

import Foundation

extension TelemetryRenderer {

    // MARK: - Video pipeline families

    static func promFrames(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emit("glimmer_fps_received", "Frames received from the network per second.", snap.receivedFps)
        builder.emit("glimmer_fps_decoded", "Frames decoded (VT output) per second.", snap.decodedFps)
        builder.emit("glimmer_fps_rendered", "Frames enqueued to the renderer per second.", snap.renderedFps)
        // EMA of decode wall-clock (not a quantile). True p50/p95/max tails are
        // in glimmer_decode_time_p_ms / _idr_ms below.
        builder.emit("glimmer_decode_time_ema_ms", "Decode wall-clock EMA, ms.", snap.decodeEmaMs)
        builder.emit("glimmer_present_cadence_error_ms",
                     "Mean |present-vs-PTS| cadence error this window, ms.", snap.presentCadenceErrorMs)
        builder.emit("glimmer_present_on_time_percent",
                     "% of new-frame presents on-cadence (excl. stale fills) - the judder signal.",
                     snap.presentOnTimePercent)
        if let onTime = snap.presentOnTimeCount {
            builder.emitCounter("glimmer_present_on_time_total", "Presents that landed on-cadence.", onTime)
        }
        if let late = snap.presentLateCount {
            builder.emitCounter("glimmer_present_late_total", "Presents that landed off-cadence.", late)
        }
        builder.emit("glimmer_host_encode_latency_min_ms",
                     "Host capture+encode latency min this window, ms (host idle-ramp visible).",
                     snap.hostEncodeLatencyMinMs)
        builder.emit("glimmer_host_encode_latency_avg_ms",
                     "Host capture+encode latency avg this window, ms.", snap.hostEncodeLatencyAvgMs)
        builder.emit("glimmer_host_encode_latency_max_ms",
                     "Host capture+encode latency max this window, ms.", snap.hostEncodeLatencyMaxMs)
    }

    static func promPacing(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.emit("glimmer_pacing_queue_depth", "Frames buffered in the pacer awaiting a vsync.",
                     snap.pacingQueueDepth.map(Double.init))
        builder.emit("glimmer_pacing_target_depth", "Adaptive jitter-buffer target depth.",
                     snap.pacingAdaptiveTargetDepth.map(Double.init))
        builder.emit("glimmer_decode_backlog", "In-flight decode backlog (frames submitted, not yet output).",
                     snap.inFlightDecodeBacklog.map(Double.init))
        // Same Extras sample as the NDJSON pacer_ticks_per_s / pacer_releases_per_s
        // fields, so the two sinks of one tick can never disagree.
        builder.emit("glimmer_pacer_ticks_per_second",
                     "Pacer display-link ticks per second (a deficit below the refresh Hz "
                     + "= missed callbacks).",
                     extras.pacerTicksPerSecond)
        builder.emit("glimmer_pacer_releases_per_second",
                     "Pacer frame releases to the renderer per second.",
                     extras.pacerReleasesPerSecond)
    }

    static func promDrops(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        if let value = snap.dropsDecoder {
            builder.emitCounter("glimmer_drops_decoder_total", "Frames dropped by the decoder (VT rejected).", value)
        }
        if let value = snap.dropsBackpressure {
            builder.emitCounter("glimmer_drops_backpressure_total", "Frames dropped (renderer queue full).", value)
        }
        if let value = snap.dropsPresentationLate {
            builder.emitCounter("glimmer_drops_presentation_late_total",
                                "Frames dropped (pacer could not present in time).", value)
        }
        builder.emitCounter("glimmer_drops_suppressed_total",
                            "Frames dropped-to-newest while presentation was suppressed (designed).",
                            extras.suppressedDropTotal)
        // The 0/1 context gauge for the counter above - which samples were taken
        // in suppressed mode. Same Extras sample as the NDJSON present_suppressed.
        builder.emit("glimmer_present_suppressed",
                     "1 while presentation is deliberately suppressed (window backgrounded/"
                     + "occluded), else 0.",
                     extras.presentSuppressed ? 1 : 0)
        // The THIRD hidden-window state - decode stopped entirely after ~2s of
        // continuous suppression - and its quiet drops, so a gated zero-decode
        // span never reads as a decode wedge. Same Extras sample as the NDJSON
        // decode_gated / drops_decode_gated_total.
        builder.emitCounter("glimmer_drops_decode_gated_total",
                            "Frames dropped without decode while the decode gate was engaged "
                            + "(designed).",
                            extras.decodeGatedDropTotal)
        builder.emit("glimmer_decode_gated",
                     "1 while the decode gate is engaged (decode stopped after sustained "
                     + "suppression), else 0.",
                     extras.decodeGated ? 1 : 0)
    }

    /// Display-refresh cadence (min/avg/max derived Hz + a change marker). The
    /// ProMotion ramp-down detector: a low refreshMinHz while the scene is static
    /// confirms the panel ramped the link interval up (Hz down), the leading
    /// idle-spike hypothesis.
    static func promRefresh(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emit("glimmer_display_refresh_min_hz",
                     "Lowest realized display refresh this window, Hz (ProMotion ramp-down).",
                     snap.refreshMinHz)
        builder.emit("glimmer_display_refresh_avg_hz",
                     "Average realized display refresh this window, Hz.", snap.refreshAvgHz)
        builder.emit("glimmer_display_refresh_max_hz",
                     "Highest realized display refresh this window, Hz.", snap.refreshMaxHz)
        builder.emit("glimmer_display_refresh_changed",
                     "1 if the realized refresh changed this window (ramp edge), else 0.",
                     snap.refreshChanged ? 1 : 0)
    }

    /// Frame size + type - avg/max bytes + %IDR. Positively excludes (or catches)
    /// the big-frame / recurring-IDR hypothesis behind the idle-resume spike.
    static func promFrameSize(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emit("glimmer_frame_bytes_avg", "Average network-delivered frame size this window, bytes.",
                     snap.avgFrameBytes)
        builder.emit("glimmer_frame_bytes_max", "Largest network-delivered frame this window, bytes.",
                     snap.maxFrameBytes.map(Double.init))
        builder.emit("glimmer_frame_idr_percent", "Percentage of frames this window that were IDR keyframes.",
                     snap.idrFramePercent)
    }

    static func promEventCounters(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emitCounter("glimmer_rfi_total", "Reference-frame-invalidation requests sent.", snap.rfiTotal)
        builder.emitCounter("glimmer_idr_requested_total", "IDR frame requests sent.", snap.idrRequestedTotal)
        builder.emitCounter("glimmer_backlog_overflow_total", "Decode-backlog overflow events.",
                            snap.backlogOverflowTotal)
        builder.emitCounter("glimmer_present_stall_total", "Present-path stall episodes detected.",
                            snap.presentStallTotal)
        builder.emitCounter("glimmer_frame_loss_total", "Frames declared lost (genuine packet loss).",
                            snap.frameLossTotal)
        builder.emitCounter("glimmer_unrecoverable_frame_total",
                            "Frames unrecoverable even after FEC.", snap.unrecoverableFrameTotal)
        builder.emitCounter("glimmer_pacer_disabled_total",
                            "Times the pacer was disabled (present-path give-up).", snap.pacerDisabledTotal)
        builder.emitCounter("glimmer_bookmark_total",
                            "User \"that felt bad\" bookmark presses (jank markers).", snap.bookmarkTotal)
    }

    /// Per-stage latency HISTOGRAMS (_bucket/_sum/_count). Real Prometheus
    /// histograms - chosen over pre-computed _p50/_p95/_p99 gauges because they're
    /// BOTH lower-overhead on the hot path (a record is a branchless bucket find +
    /// one atomic add, no live-quantile reservoir per frame) AND fully queryable:
    /// Grafana derives any quantile across any window with
    /// `histogram_quantile(0.95, rate(glimmer_latency_..._ms_bucket[1m]))`.
    static func promLatency(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        guard let histograms = snap.latencyHistograms else { return }
        builder.emitHistogram(
            "glimmer_latency_receive_to_assemble_ms",
            "Receive→assemble stage latency histogram, ms.",
            stage: histograms.receiveToAssemble)
        builder.emitHistogram(
            "glimmer_latency_assemble_to_submit_ms",
            "Assemble→decode-submit stage latency histogram, ms.",
            stage: histograms.assembleToSubmit)
        builder.emitHistogram(
            "glimmer_latency_decode_submit_to_output_ms",
            "Decode-submit→VT-output (decode) stage latency histogram, ms.",
            stage: histograms.submitToOutput)
        builder.emitHistogram(
            "glimmer_latency_output_to_present_ms",
            "VT-output→present (pacing) stage latency histogram, ms.",
            stage: histograms.outputToPresent)
        builder.emitHistogram(
            "glimmer_latency_end_to_end_ms",
            "End-to-end receive→present latency histogram, ms.",
            stage: histograms.endToEnd)
        // THE headline number (signal 1): host-encode + ~RTT/2 + our pipeline.
        builder.emitHistogram(
            "glimmer_latency_glass_to_glass_ms",
            "Glass-to-glass latency histogram (host encode + ~RTT/2 + receive→present), ms.",
            stage: histograms.glassToGlass)
        // Input-to-photon ESTIMATE (signal 2): first-present-after-input −
        // input-sent, consume-once per input stamp (see TelemetryLatency+
        // Composites). A lower bound on felt input latency (the host doesn't
        // mark which frame reflects an input) - the help text says estimate so
        // a reader can't misread it as measured. UNCAPPED up to the ~1s
        // plausibility ceiling; an earlier 38ms freshness cap pinned max/p99 at
        // the cap itself.
        builder.emitHistogram(
            "glimmer_latency_input_to_photon_ms",
            "Input-to-photon latency ESTIMATE histogram (first present after an input, "
            + "one observation per input stamp), ms.",
            stage: histograms.inputToPhoton)
        // DECODE time split by frame type (signal: DECODE) - the submit→output
        // decode delta bucketed separately for IDR keyframes vs P-frames, so the
        // slow full-intra IDR doesn't blur the fast P-frame distribution.
        builder.emitHistogram(
            "glimmer_decode_time_idr_ms",
            "Decode time (submit→VT-output) for IDR keyframes, ms.",
            stage: histograms.decodeIDR)
        builder.emitHistogram(
            "glimmer_decode_time_p_ms",
            "Decode time (submit→VT-output) for P-frames, ms.",
            stage: histograms.decodeP)
        // IDR ROUND-TRIP (signal: IDR-RTT) - explicit request-sent → matching
        // IDR/recovery frame arrived (both client-side; RFIs don't arm, see
        // EnetControlChannel+Send). The distribution; the counts + last RTT
        // are in the P2 lifecycle section.
        builder.emitHistogram(
            "glimmer_idr_round_trip_ms",
            "Explicit-IDR round-trip histogram (our request-send → resulting IDR/recovery frame), ms.",
            stage: histograms.idrRoundTrip)
    }

    /// P1 DECODE/VT: the decoder (re)create counter + the live DECODE state info
    /// gauge (HW-decode confirmation + pixel format + bit depth + colorspace carried
    /// in labels). The bit-depth is also a plain gauge so a Grafana threshold is
    /// trivial; hw-decode is a 0/1 gauge so a software fallback alarms.
    static func promDecode(_ builder: inout PromBuilder, _ snap: TelemetrySnapshot) {
        builder.emitCounter("glimmer_decoder_recreate_total",
                            "VTDecompressionSession (re)creates (first create + param-rebuilds).",
                            snap.decoderRecreateTotal)
        // Same recreates split by CAUSE (sums to the total above): the one-time
        // first create, a real resolution change, or a colorspace/HDR/profile
        // param-rebuild that kept the dimensions - so a recreate STORM names its
        // driver. Cause read from the format-description dimensions at rebuild.
        builder.emitCounterFamily(
            "glimmer_decoder_recreate_by_cause_total",
            "Decoder (re)creates by cause (sums to glimmer_decoder_recreate_total).",
            key: "cause",
            rows: [("first_create", snap.decoderRecreateFirstTotal),
                   ("param_rebuild_resolution", snap.decoderRecreateResolutionTotal),
                   ("param_rebuild_colorspace", snap.decoderRecreateColorspaceTotal)])
        // VT-session create wall-clock (ms): the HW-decoder bring-up on the
        // first-frame leg. 0 before the first create (the emit drops the 0).
        builder.emit("glimmer_vt_session_create_ms",
                     "VTDecompressionSessionCreate wall-clock cost, ms (first-frame-leg startup).",
                     snap.vtSessionCreateMs > 0 ? snap.vtSessionCreateMs : nil)
        builder.emitCounter("glimmer_discontinuity_flush_total",
                            "Stream-discontinuity flushes (param-set rebuilds that flushed the "
                            + "renderer + cleared the pacer queue - a real multi-frame skip). 0 on "
                            + "a healthy wired link; a delta is a mid-stream format change.",
                            snap.discontinuityFlushTotal)
        guard let state = snap.decodeState else { return }
        builder.emit("glimmer_decode_hw_accelerated",
                     "1 if VideoToolbox confirmed a hardware-accelerated decoder, else 0.",
                     state.hwDecode ? 1 : 0)
        builder.emit("glimmer_decode_bit_depth", "Decoded output bit depth (8 or 10).",
                     Double(state.bitDepth))
        // Info gauge: the discrete decode state carried in labels (the standard
        // `_info` constant-1 pattern), so a scrape attributes the pipeline to a
        // pixel format + colorspace + hw-decode at a glance.
        builder.emitInfo(
            "glimmer_decode_state_info",
            "Live decode state - codec, pixel format, bit depth, colorspace, hw-decode (value always 1).",
            labels: [("codec", state.codec),
                     ("pixel_format", state.pixelFormat),
                     ("bit_depth", String(state.bitDepth)),
                     ("colorspace", state.colorSpaceKey),
                     ("hw_decode", state.hwDecode ? "true" : "false")])
    }

    /// P1 PRESENT/DISPLAY: the stale-frame REPEAT rate/total (the invisible
    /// stutter), the EDR-headroom trend (min/avg/max), and the HDR-engaged /
    /// ProMotion state with the screen as a label.
    static func promDisplay(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        builder.emitCounter("glimmer_present_stale_repeat_total",
                            "Pacer ticks that presented no new frame (layer re-showed the last).",
                            snap.staleFrameRepeatTotal)
        builder.emit("glimmer_present_stale_repeats_per_second",
                     "Stale-frame repeats per second (spike at fps≈refresh = micro-judder).",
                     snap.staleRepeatsPerSecond)
        builder.emitCounter("glimmer_pacer_over_target_release_total",
                            "Over-target force-releases (zero in steady state; the due-gate "
                            + "self-oscillation breaker).",
                            extras.pacerOverTargetReleaseTotal)
        builder.emit("glimmer_pacer_over_target_releases_per_second",
                     "Over-target force-releases per second (a spike = the no-network "
                     + "present-stall signature).",
                     extras.pacerOverTargetReleasesPerSecond)
        builder.emit("glimmer_pacer_over_target_release_ratio",
                     "Over-target force-releases ÷ total releases this window "
                     + "(<0.1 steady-state; sustained-high = fps≈refresh self-oscillation).",
                     extras.pacerOverTargetReleaseRatio)
        builder.emitCounter("glimmer_tick_miss_descheduled_total",
                            "Stretched present ticks where handleTick itself ran late "
                            + "(the tick thread was descheduled - the CPU starved it).",
                            snap.tickMissDescheduledTotal)
        builder.emitCounter("glimmer_tick_miss_coalesced_total",
                            "Stretched present ticks where handleTick ran on time but the "
                            + "vsync delta jumped (macOS coalesced the callback delivery).",
                            snap.tickMissCoalescedTotal)
        builder.emit("glimmer_display_edr_headroom_min",
                     "EDR headroom min this window (1.0 = SDR, >1.0 = HDR engaged).",
                     snap.edrHeadroomMin)
        builder.emit("glimmer_display_edr_headroom_avg",
                     "EDR headroom avg this window.", snap.edrHeadroomAvg)
        builder.emit("glimmer_display_edr_headroom_max",
                     "EDR headroom max this window.", snap.edrHeadroomMax)
        guard let state = snap.displayState else { return }
        let screenLabels = [("screen", state.screenName)]
        builder.emitLabeled("glimmer_display_hdr_engaged",
                            "1 if HDR is engaged end-to-end on this screen, else 0.",
                            state.hdrEngaged ? 1 : 0, labels: screenLabels)
        builder.emitLabeled("glimmer_display_promotion_capable",
                            "1 if the compositing screen supports ProMotion (>60Hz), else 0.",
                            state.proMotionCapable ? 1 : 0, labels: screenLabels)
        builder.emitLabeled("glimmer_display_max_refresh_hz",
                            "Compositing screen's advertised max refresh, Hz (ProMotion ceiling).",
                            Double(state.maxRefreshHz), labels: screenLabels)
    }
}
