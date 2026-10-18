// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

import Foundation

extension FrameTimingTracker {

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
    package struct TraceRecord {

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
            inputToPhoton: Double? = nil
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
        }

        package let frameIndex: Int32
        package let rtpTimestamp: UInt32
        package let frameBytes: Int32
        package let isIDR: Bool
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

    /// Frames-file DROP STUBS (`event:"frame_drop"`) for frames evicted unpresented;
    /// `stage` is the last stage reached; assemble and eviction times locate the hitch.
    /// Called off the mapLock.
    package func emitDropStubs(_ evicted: [(rtp: UInt32, timing: Timing)]) {
        let lines = dropStubLines(
            evicted, hiddenNow: counters.presentSuppressed || counters.decodeGated,
            evictMs: Double(now()) / 1_000_000.0)
        for line in lines { traceWriter.append(line) }
    }

    /// Stub lines minus DESIGNED drops (hidden window; the suppressed/gated counters
    /// own those): everything while hidden now, and frames assembled while hidden,
    /// since eviction trails a gate lift by ~1.5 s.
    package func dropStubLines(
        _ evicted: [(rtp: UInt32, timing: Timing)],
        hiddenNow: Bool,
        evictMs: Double
    ) -> [String] {
        guard !hiddenNow else { return [] }
        return evicted.filter { !$0.timing.assembledHidden }.map { drop in
            let stage = drop.timing.outputNanos != 0 ? "decoded"
                : drop.timing.submitNanos != 0 ? "submitted" : "assembled"
            return "{\"session\":\"\(sessionId)\",\"event\":\"frame_drop\","
                + "\"frame\":\(drop.timing.frameIndex),\"rtp\":\(drop.rtp),"
                + "\"type\":\"\(drop.timing.isIDR ? "idr" : "p")\","
                + "\"stage\":\"\(stage)\","
                + "\"t_assemble_ms\":\(TelemetryRenderer.jsonNumber(Double(drop.timing.assembleNanos) / 1_000_000.0)),"
                + "\"t_evict_ms\":\(TelemetryRenderer.jsonNumber(evictMs))}"
        }
    }

    /// The ⌃B bookmark as a trace row on the input rows' clock (`t_ms`), so the
    /// input sent just before it is one search away.
    package func bookmarkLine(total: UInt64, uptimeNanos: UInt64) -> String {
        "{\"session\":\"\(sessionId)\",\"event\":\"bookmark\",\"bookmark_total\":\(total),"
            + "\"t_ms\":\(TelemetryRenderer.jsonNumber(Double(uptimeNanos) / 1_000_000.0))}"
    }
}
