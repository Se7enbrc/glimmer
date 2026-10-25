// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS) || GLIMMER_DIAGNOSTICS

//
//  TelemetryLatency+Trace.swift
//
//  Per-frame NDJSON trace rendering for the latency rig, split out of
//  TelemetryLatency.swift so that file stays under the length budget and focused on
//  the live histograms + the per-frame timing tracker. This is the rendering half:
//  the bundled per-frame record and the hand-built NDJSON line emitter the tracker
//  appends off the hot path. SECRET-FREE: every value is a nanosecond delta or a
//  frame index - nothing that could carry a secret, key, or host identity.
//

import CoreMedia
import Foundation

extension FrameTimingTracker {

    package enum RendererStatePhase: String, Sendable {
        case backpressureBegan = "backpressure_began"
        case backpressureEnded = "backpressure_ended"
        case flushBegan = "flush_began"
        case flushReturned = "flush_returned"
    }

    package struct RendererState {
        package let phase: RendererStatePhase
        package let status: Int
        package let ready: Bool
        package let requiresFlush: Bool
        package let generation: UInt64?
        package let rejectedFrames: Int?
        package let pts: CMTime?
        package let displayImmediately: Bool?

        package init(phase: RendererStatePhase, status: Int, ready: Bool, requiresFlush: Bool,
                     generation: UInt64?, rejectedFrames: Int? = nil, pts: CMTime? = nil,
                     displayImmediately: Bool? = nil) {
            self.phase = phase
            self.status = status
            self.ready = ready
            self.requiresFlush = requiresFlush
            self.generation = generation
            self.rejectedFrames = rejectedFrames
            self.pts = pts
            self.displayImmediately = displayImmediately
        }
    }

    /// Transition-only observations; a flush returning is not proof that pixels reached the display.
    package func recordRendererState(_ state: RendererState) {
        var row = TelemetryRenderer.NDJSONBuilder()
        row.addString("session", sessionId)
        row.addString("event", "renderer_state")
        row.addString("phase", state.phase.rawValue)
        row.add("t_ms", Double(now()) / 1_000_000.0)
        row.addInt("status", state.status)
        row.addBool("ready", state.ready)
        row.addBool("requires_flush", state.requiresFlush)
        row.addCount("generation", state.generation)
        row.addInt("rejected_frames", state.rejectedFrames)
        row.addBool("display_immediately", state.displayImmediately)
        row.addBool("suppressed", counters.presentSuppressed)
        row.addBool("decode_gated", counters.decodeGated)
        if let pts = state.pts {
            row.addInt("pts_value", Int(pts.value))
            row.addInt("pts_timescale", Int(pts.timescale))
            row.addInt("pts_epoch", Int(pts.epoch))
            row.addInt("pts_flags", Int(pts.flags.rawValue))
            row.addBool("pts_numeric", pts.isValid && pts.isNumeric)
        }
        traceWriter.append(row.line())
    }

    package enum RendererDecision: String, CaseIterable, Sendable {
        case frameRejectedFailed = "frame_rejected_failed"
        case frameRejectedNotReady = "frame_rejected_not_ready"
        case repaintRejectedFailed = "repaint_rejected_failed"
        case repaintRejectedNotReady = "repaint_rejected_not_ready"
        case repaintCopyFailed = "repaint_copy_failed"
        case repaintEnqueued = "repaint_enqueued"
    }

    /// Renderer decisions share the bookmark clock but never enter frame-rate or latency histograms.
    package func recordRendererDecision(_ decision: RendererDecision, rtpTimestamp: UInt32) {
        let time = Double(now()) / 1_000_000.0
        traceWriter.append("{\"session\":\"\(sessionId)\",\"event\":\"renderer_decision\","
            + "\"decision\":\"\(decision.rawValue)\",\"rtp\":\(rtpTimestamp),"
            + "\"t_ms\":\(TelemetryRenderer.jsonNumber(time)),"
            + "\"suppressed\":\(counters.presentSuppressed),\"decode_gated\":\(counters.decodeGated)}")
    }

    /// One presented frame's identity + size/type + the five stage deltas (ms),
    /// bundled so the trace renderer takes one value instead of nine params.
    package struct TraceRecord: Sendable {

        package init(
            frameIndex: Int32,
            rtpTimestamp: UInt32,
            frameBytes: Int32,
            isIDR: Bool,
            presentUptimeMs: Double,
            isResumePresent: Bool,
            receiveToAssemble: Double? = nil,
            assembleToSubmit: Double? = nil,
            submitToOutput: Double? = nil,
            outputToPresent: Double? = nil,
            endToEnd: Double? = nil,
            glassToGlass: Double? = nil,
            inputToPhoton: Double? = nil,
            attemptID: String? = nil
        ) {
            self.frameIndex = frameIndex
            self.rtpTimestamp = rtpTimestamp
            self.frameBytes = frameBytes
            self.isIDR = isIDR
            self.presentUptimeMs = presentUptimeMs
            self.isResumePresent = isResumePresent
            self.receiveToAssemble = receiveToAssemble
            self.assembleToSubmit = assembleToSubmit
            self.submitToOutput = submitToOutput
            self.outputToPresent = outputToPresent
            self.endToEnd = endToEnd
            self.glassToGlass = glassToGlass
            self.inputToPhoton = inputToPhoton
            self.attemptID = attemptID
        }

        package let frameIndex: Int32
        package let rtpTimestamp: UInt32
        package let frameBytes: Int32
        package let isIDR: Bool
        package let attemptID: String?
        /// PRESENT-CLOCK timestamp (monotonic uptime, ms): makes present
        /// intervals - and so the felt-judder metric |present-interval −
        /// content-interval| - computable straight off this file, instead of
        /// reconstructing present time offline from rtp + g2g deltas.
        package let presentUptimeMs: Double
        /// First present after un-suppress: carries the retained frame's
        /// designed hold time, so it is excluded from histogram ingestion and
        /// tagged here (`resume:true`) for the same exclusion offline.
        package let isResumePresent: Bool
        package let receiveToAssemble: Double?
        package let assembleToSubmit: Double?
        package let submitToOutput: Double?
        package let outputToPresent: Double?
        package let endToEnd: Double?
        /// Glass-to-glass (signal 1) + input-to-photon estimate (signal 2),
        /// per-frame. nil when the inputs for that frame weren't available (no
        /// host-encode measurement + no RTT yet; no recent input).
        package let glassToGlass: Double?
        package let inputToPhoton: Double?
    }

    /// Render one per-frame NDJSON line. Hand-built (matches the exporter's
    /// renderer) so nil deltas are simply omitted. Every value is a number - no
    /// secrets. ROW DISCRIMINATION for line-oriented consumers: frame SAMPLE
    /// rows never carry an `event` key; event rows (idr_round_trip, frame_drop)
    /// always do - test `event`'s presence, not `type`'s (the null-`type`
    /// misread that cost a digest correction).
    package func renderTraceLine(_ record: TraceRecord) -> String {
        Self.renderTraceLine(record, sessionId: sessionId)
    }

    package static func renderTraceLine(_ record: TraceRecord, sessionId: String) -> String {
        var fields: [String] = []
        fields.append("\"session\":\"\(sessionId)\"")
        fields.append("\"frame\":\(record.frameIndex)")
        fields.append("\"rtp\":\(record.rtpTimestamp)")
        // Per-frame size + type: the big-frame / IDR signal alongside the latency
        // breakdown. Only emit bytes when known (>0); the type is "idr"/"p".
        if record.frameBytes > 0 { fields.append("\"bytes\":\(record.frameBytes)") }
        fields.append("\"type\":\"\(record.isIDR ? "idr" : "p")\"")
        fields.append("\"t_present_ms\":\(TelemetryRenderer.jsonNumber(record.presentUptimeMs))")
        if record.isResumePresent { fields.append("\"resume\":true") }
        func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            fields.append("\"\(key)\":\(TelemetryRenderer.jsonNumber(value))")
        }
        add("recv_to_assemble_ms", record.receiveToAssemble)
        add("assemble_to_submit_ms", record.assembleToSubmit)
        add("submit_to_output_ms", record.submitToOutput)
        add("output_to_present_ms", record.outputToPresent)
        add("end_to_end_ms", record.endToEnd)
        // The two headline composite signals, per frame. input_to_photon is an
        // ESTIMATE (the host doesn't mark which frame reflects an input); `_est`
        // keeps a reader from mistaking it for a measured number.
        add("glass_to_glass_ms", record.glassToGlass)
        add("input_to_photon_est_ms", record.inputToPhoton)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Expiry is unresolved bookkeeping, not a measured drop decision. Keep all known stage times.
    package func emitDropStubs(_ evicted: [(rtp: UInt32, timing: Timing)]) {
        let records = expiryRecords(evicted, hiddenNow: counters.presentSuppressed || counters.decodeGated,
                                    uptimeNanos: now())
        for record in records { traceWriter.appendStage(record, sessionId: sessionId) }
    }

    package func dropStubLines(_ evicted: [(rtp: UInt32, timing: Timing)],
                               hiddenNow: Bool, evictMs: Double) -> [String] {
        expiryRecords(evicted, hiddenNow: hiddenNow, uptimeNanos: UInt64(evictMs * 1_000_000))
            .map { Self.renderStageLine($0, sessionId: sessionId) }
    }

    private func expiryRecords(_ evicted: [(rtp: UInt32, timing: Timing)],
                               hiddenNow: Bool, uptimeNanos: UInt64) -> [StageRecord] {
        guard !hiddenNow else { return [] }
        return evicted.filter { !$0.timing.assembledHidden }.map {
            StageRecord(event: .unresolvedExpiry, rtpTimestamp: $0.rtp,
                        uptimeNanos: uptimeNanos, timing: $0.timing)
        }
    }

    /// The ⌃B bookmark as a trace row on the input rows' clock (`t_ms`), so the
    /// input sent just before it is one search away.
    package func bookmarkLine(total: UInt64, uptimeNanos: UInt64) -> String {
        "{\"session\":\"\(sessionId)\",\"event\":\"bookmark\",\"bookmark_total\":\(total),"
            + "\"t_ms\":\(TelemetryRenderer.jsonNumber(Double(uptimeNanos) / 1_000_000.0))}"
    }

    package func recordPresent(rtpTimestamp: UInt32, uptimeNanos: UInt64? = nil) {
        guard rtpTimestamp != 0 else { return }
        let presentNanos = uptimeNanos ?? now()

        guard let timing = takeTiming(rtpTimestamp: rtpTimestamp) else { return }
        let hostFrameIntervalMs = self.hostFrameIntervalMs

        // Compute the five sub-stage deltas in ms. A stage timestamp of 0 means
        // the frame skipped that stage (shouldn't happen for a presented frame,
        // but guard so a partial entry can't emit a garbage delta).
        let receiveToAssemble = msBetween(timing.receiveNanos, timing.assembleNanos)
        let assembleToSubmit = msBetween(timing.assembleNanos, timing.submitNanos)
        let submitToOutput = msBetween(timing.submitNanos, timing.outputNanos)
        let outputToPresent = msBetween(timing.outputNanos, presentNanos)
        let endToEnd = msBetween(timing.receiveNanos, presentNanos)

        let resumePresent = takeResumePresentTag()
        let warmingUp = isWithinWarmup(presentNanos: presentNanos) || resumePresent

        if !warmingUp {
            if let value = receiveToAssemble { histograms.receiveToAssemble.observe(value) }
            if let value = assembleToSubmit { histograms.assembleToSubmit.observe(value) }
            if let value = outputToPresent { histograms.outputToPresent.observe(value) }
            if let value = endToEnd { histograms.endToEnd.observe(value) }
        }

        let glassToGlass = computeGlassToGlass(hostEncodeMs: timing.hostEncodeMs, pipelineMs: endToEnd)
        if !warmingUp, let value = glassToGlass { histograms.glassToGlass.observe(value) }

        // INPUT-TO-PHOTON estimate (signal 2): client legs + uplink + the wait for
        // the host's next frame + this frame's glass-to-glass, once per input
        // stamp (see the Composites split).
        let inputToPhoton = computeInputToPhoton(
            presentNanos: presentNanos, glassToGlassMs: glassToGlass, hostFrameIntervalMs: hostFrameIntervalMs)
        if !warmingUp, let value = inputToPhoton { histograms.inputToPhoton.observe(value) }

        traceWriter.appendFrame(TraceRecord(
            frameIndex: timing.frameIndex,
            rtpTimestamp: rtpTimestamp,
            frameBytes: timing.frameBytes,
            isIDR: timing.isIDR,
            presentUptimeMs: Double(presentNanos) / 1_000_000.0,
            isResumePresent: resumePresent,
            receiveToAssemble: receiveToAssemble,
            assembleToSubmit: assembleToSubmit,
            submitToOutput: submitToOutput,
            outputToPresent: outputToPresent,
            endToEnd: endToEnd,
            glassToGlass: glassToGlass,
            inputToPhoton: inputToPhoton, attemptID: timing.attemptID), sessionId: sessionId)
    }
}

#endif
