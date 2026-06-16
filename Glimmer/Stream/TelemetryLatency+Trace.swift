//
//  TelemetryLatency+Trace.swift
//
//  Per-frame NDJSON trace rendering for the latency rig, split out of
//  TelemetryLatency.swift so that file stays under the length budget and focused on
//  the live histograms + the per-frame timing tracker. This is the rendering half:
//  the bundled per-frame record and the hand-built NDJSON line emitter the tracker
//  appends off the hot path. SECRET-FREE: every value is a nanosecond delta or a
//  frame index — nothing that could carry a secret, key, or host identity.
//

import Foundation

extension FrameTimingTracker {

    /// One presented frame's identity + size/type + the five stage deltas (ms),
    /// bundled so the trace renderer takes one value instead of nine params.
    struct TraceRecord {
        let frameIndex: Int32
        let rtpTimestamp: UInt32
        let frameBytes: Int32
        let isIDR: Bool
        /// PRESENT-CLOCK timestamp (monotonic uptime, ms): makes present
        /// intervals — and so the felt-judder metric |present-interval −
        /// content-interval| — computable straight off this file, instead of
        /// reconstructing present time offline from rtp + g2g deltas.
        let presentUptimeMs: Double
        /// First present after un-suppress: carries the retained frame's
        /// designed hold time, so it is excluded from histogram ingestion and
        /// tagged here (`resume:true`) for the same exclusion offline.
        let isResumePresent: Bool
        let receiveToAssemble: Double?
        let assembleToSubmit: Double?
        let submitToOutput: Double?
        let outputToPresent: Double?
        let endToEnd: Double?
        /// Glass-to-glass (signal 1) + input-to-photon estimate (signal 2),
        /// per-frame. nil when the inputs for that frame weren't available (no
        /// host-encode measurement + no RTT yet; no recent input).
        let glassToGlass: Double?
        let inputToPhoton: Double?
    }

    /// Render one per-frame NDJSON line. Hand-built (matches the exporter's
    /// renderer) so nil deltas are simply omitted. Every value is a number — no
    /// secrets. ROW DISCRIMINATION for line-oriented consumers: frame SAMPLE
    /// rows never carry an `event` key; event rows (idr_round_trip, frame_drop)
    /// always do — test `event`'s presence, not `type`'s (the null-`type`
    /// misread that cost a digest correction).
    func renderTraceLine(_ record: TraceRecord) -> String {
        var fields: [String] = []
        fields.append("\"session\":\"\(sessionId)\"")
        fields.append("\"frame\":\(record.frameIndex)")
        fields.append("\"rtp\":\(record.rtpTimestamp)")
        // Per-frame size + type: the big-frame / IDR signal alongside the latency
        // breakdown. Only emit bytes when known (>0); the type is "idr"/"p".
        if record.frameBytes > 0 { fields.append("\"bytes\":\(record.frameBytes)") }
        fields.append("\"type\":\"\(record.isIDR ? "idr" : "p")\"")
        fields.append("\"t_present_ms\":\(jsonNumber(record.presentUptimeMs))")
        if record.isResumePresent { fields.append("\"resume\":true") }
        func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            fields.append("\"\(key)\":\(jsonNumber(value))")
        }
        add("recv_to_assemble_ms", record.receiveToAssemble)
        add("assemble_to_submit_ms", record.assembleToSubmit)
        add("submit_to_output_ms", record.submitToOutput)
        add("output_to_present_ms", record.outputToPresent)
        add("end_to_end_ms", record.endToEnd)
        // The two headline composite signals, per frame. input_to_photon is a
        // lower-bound ESTIMATE (the host doesn't mark which frame reflects an
        // input) — the key name keeps `_est` so a reader never mistakes it for a
        // measured number.
        add("glass_to_glass_ms", record.glassToGlass)
        add("input_to_photon_est_ms", record.inputToPhoton)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Emit frames-file DROP STUBS (`event:"frame_drop"`) for frames the
    /// in-flight map evicted: received + assembled but never presented — i.e.
    /// dropped somewhere downstream. The stage the frame DID reach narrows the
    /// drop site ("assembled" = died pre-decode, "submitted" = in decode,
    /// "decoded" = died at the pacer — the late-drop class that makes judder).
    /// Honesty notes baked into the format: (a) stubs surface ~maxInFlight
    /// frames AFTER the drop (eviction lag, ~1.5s at 170fps) — `t_evict_ms` is
    /// the eviction instant, NOT the drop instant; (b) DESIGNED drops while
    /// suppressed/gated are skipped (no judder to attribute, and a hidden
    /// window would otherwise spray ~200 stubs/s of noise — the suppressed/
    /// gated counters already account those), with the state read at eviction
    /// time so a drop racing a suppression edge can rarely be mis-skipped.
    /// Called off the mapLock on the (gate-on-only) telemetry path.
    func emitDropStubs(_ evicted: [(rtp: UInt32, timing: Timing)]) {
        let counters = TelemetryCounters.shared
        guard !counters.presentSuppressed, !counters.decodeGated else { return }
        let evictMs = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
        for drop in evicted {
            let stage = drop.timing.outputNanos != 0 ? "decoded"
                : drop.timing.submitNanos != 0 ? "submitted" : "assembled"
            traceWriter.append("{\"session\":\"\(sessionId)\",\"event\":\"frame_drop\","
                + "\"frame\":\(drop.timing.frameIndex),\"rtp\":\(drop.rtp),"
                + "\"type\":\"\(drop.timing.isIDR ? "idr" : "p")\","
                + "\"stage\":\"\(stage)\",\"t_evict_ms\":\(jsonNumber(evictMs))}")
        }
    }

    /// Same integer/decimal discipline as TelemetryRenderer.jsonNumber so the
    /// per-frame trace and the per-second snapshot read consistently.
    func jsonNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }
}
