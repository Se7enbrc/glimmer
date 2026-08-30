//
//  TelemetryLatencyHistograms.swift
//
//  The fixed-bucket, atomic-increment LATENCY HISTOGRAMS behind the per-stage
//  breakdown: one family per pipeline stage plus the composite glass-to-glass /
//  input-to-photon stages, recorded as a branchless bucket find and a single
//  locked add so a stage record costs no allocation on the hot path. Split out
//  of TelemetryLatency.swift (pure move, same file-split idiom as the rest of
//  the telemetry rig) to keep both units under the length limit; see that file
//  for the stage definitions, the gate/hot-path contract, and the per-frame
//  tracker that feeds these, and TelemetryLatencySnapshot.swift for the
//  per-tick value type they snapshot into.
//

import Foundation
import os

// MARK: - Latency histograms

/// Fixed-bucket, atomic-increment histograms for the five latency stages. We use
/// real Prometheus histograms (`_bucket`/`_sum`/`_count`) rather than
/// pre-computed `_p50/_p95/_p99` gauges because it is BOTH lower-overhead on the
/// hot path AND more queryable: a record is a branchless bucket find + a single
/// locked add (no sorted reservoir / live-quantile maintenance per frame), and
/// Grafana derives p50/p95/p99 from the cumulative buckets with
/// `histogram_quantile(0.95, rate(..._bucket[1m]))`. Cardinality stays low - five
/// families, ~12 buckets each, one `{session}` label.
///
/// `@unchecked Sendable`: every counter is its own `os_unfair_lock`-guarded
/// UInt64 (the same discipline as `TelemetryCounters.Counter`), safe from the
/// receive thread, the decode queue, and the pacer's serial queue.
final class LatencyHistograms: @unchecked Sendable {

    /// One stage's cumulative histogram: per-bucket counts (Prometheus `le`
    /// semantics - bucket[i] counts observations ≤ bounds[i]), plus running sum
    /// (ms) and total count. One lock per stage keeps the five stages
    /// contention-free against each other.
    final class Stage: @unchecked Sendable {
        /// Upper bounds in MILLISECONDS. Chosen to span the realistic per-stage
        /// range for 60-240fps streaming: sub-ms assemble/submit jitter through
        /// to multi-frame decode/pace stalls. The implicit `+Inf` bucket (count
        /// vs total) is emitted by the renderer.
        ///
        /// FINE LOW/MID RESOLUTION where it matters: the e2e pipeline lands at
        /// ~5-6ms, and the old [4,8,16] spacing left a 4→8→16 gap (a ~12ms-wide
        /// "blur" bucket) right across that range, so p50/p95/p99 had no real
        /// resolution exactly where the signal lives. The bounds below add
        /// sub-ms and few-ms edges (0.1...6) so quantiles resolve to sub-ms / few-ms
        /// precision, while the coarse tail (8...528) still captures multi-frame
        /// stalls. boundsMs is read by both the Prometheus render and the NDJSON
        /// quantile estimator, so this single edit propagates to all consumers.
        static let boundsMs: [Double] = [
            0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 33, 66, 132, 264, 528
        ]

        /// COARSE bounds for the wide-range composite stages (glass-to-glass,
        /// input-to-photon). These span the realistic end-user latency budget:
        /// a few ms (LAN, light host encode) through tens of ms (host AV1
        /// two-pass encode) into the hundreds (a saturated link or a stalled
        /// frame). Resolution is concentrated in the 5-60ms zone where "feels
        /// great" turns into "feels laggy", with a coarse tail to 1056ms so a
        /// pathological stall still lands in a bucket rather than overflowing to
        /// +Inf with no shape.
        static let glassToGlassBoundsMs: [Double] = [
            1, 2, 4, 6, 8, 10, 12, 16, 20, 25, 30, 40, 50, 66, 90, 132, 200, 300, 528, 1056
        ]

        /// OUTPUT→PRESENT (pacing) bounds. The default `boundsMs` jumps 16→33→66, a
        /// blind ~30ms bucket right where the pacing tail lives (multi-vsync holds land
        /// at 17-42ms), so p95/p99 had no resolution there. Adds 20/25/40/50 across it.
        static let outputToPresentBoundsMs: [Double] = [
            0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 25, 33, 40, 50, 66, 132, 264, 528
        ]

        /// The bounds THIS stage buckets against. Per-stage so the fine sub-stage
        /// histograms and the coarse composite ones share one observe/snapshot
        /// path; read by both the Prometheus render and the NDJSON quantile
        /// estimator (carried on the snapshot) so they stay consistent.
        let bounds: [Double]

        private let lock = os_unfair_lock_t.allocate(capacity: 1)
        private var bucketCounts: [UInt64]
        private var sumMs: Double = 0
        private var totalCount: UInt64 = 0

        init(bounds: [Double] = Stage.boundsMs) {
            self.bounds = bounds
            lock.initialize(to: os_unfair_lock_s())
            bucketCounts = [UInt64](repeating: 0, count: bounds.count)
        }
        deinit { lock.deallocate() }

        /// Record one observation (a stage delta, in ms). Branchless-ish bucket
        /// find over a 12-element ascending array, then a single locked update of
        /// the matching cumulative buckets + sum + count.
        func observe(_ valueMs: Double) {
            guard valueMs.isFinite, valueMs >= 0 else { return }
            os_unfair_lock_lock(lock)
            // Cumulative ("le") semantics: increment every bucket whose bound is
            // ≥ the value. Walk from the smallest bound up; once we pass the
            // value, all remaining (larger) buckets also count it.
            var index = 0
            let bounds = self.bounds
            while index < bounds.count {
                if valueMs <= bounds[index] {
                    // From here up, every bucket's bound is larger, so all of
                    // them include this observation.
                    while index < bounds.count {
                        bucketCounts[index] &+= 1
                        index += 1
                    }
                    break
                }
                index += 1
            }
            sumMs += valueMs
            totalCount &+= 1
            os_unfair_lock_unlock(lock)
        }

        /// Snapshot the cumulative buckets + sum + count for rendering. Taken on
        /// the exporter's serial queue (1Hz), not the hot path.
        func snapshot() -> (buckets: [UInt64], sumMs: Double, count: UInt64) {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return (bucketCounts, sumMs, totalCount)
        }

        /// Snapshot as the renderer's value type. Used by standalone stages (e.g.
        /// the input-local-latency histogram) that aren't part of the composite
        /// `LatencyHistogramSnapshot`.
        func snapshotValue() -> LatencyHistogramSnapshot.Stage {
            let captured = snapshot()
            return LatencyHistogramSnapshot.Stage(
                buckets: captured.buckets, boundsMs: bounds,
                sumMs: captured.sumMs, observationCount: captured.count)
        }

        func reset() {
            os_unfair_lock_lock(lock)
            for index in bucketCounts.indices { bucketCounts[index] = 0 }
            sumMs = 0
            totalCount = 0
            os_unfair_lock_unlock(lock)
        }
    }

    let receiveToAssemble = Stage()
    let assembleToSubmit = Stage()
    let submitToOutput = Stage()
    let outputToPresent = Stage(bounds: Stage.outputToPresentBoundsMs)
    let endToEnd = Stage()

    /// DECODE time split by frame type (signal: DECODE). The submit→output
    /// (VTDecompressionSessionDecodeFrame → output callback) delta, bucketed
    /// SEPARATELY for IDR keyframes vs P-frames. An IDR is a full-resolution
    /// intra frame and decodes much slower than a delta P-frame, so the combined
    /// `submitToOutput` histogram blurs two distributions; splitting them shows
    /// the true per-type decode cost and catches an IDR-decode-cost spike (the
    /// recurring-IDR-on-idle-resume hypothesis) that the blended view hides. Both
    /// use the fine sub-stage bounds (decode lands in the few-ms range).
    let decodeIDR = Stage()
    let decodeP = Stage()

    /// IDR/RFI ROUND-TRIP (signal: IDR-RTT). Time from our requestIdrFrame/RFI
    /// SEND to the matching IDR/recovery frame ARRIVING (both client-side). Spans
    /// a network round trip plus the host's encode of a full intra frame, so it
    /// uses the coarse composite bounds (a recovery on a bad link is tens to
    /// hundreds of ms). Fed once per matched request from the depacketizer.
    let idrRoundTrip = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// GLASS-TO-GLASS: the "how good is it" number - host capture+encode
    /// (Sunshine `frameHostProcessingLatency`) + network transit (~RTT/2) + our
    /// pipeline (receive→present, the endToEnd stage). Computed per frame at
    /// present and recorded here so the exporter publishes p50/p95/p99 over time.
    /// Spans a much wider range than any single sub-stage (host AV1 encode alone
    /// can be tens of ms), so it gets its own coarse-tailed bound set below.
    let glassToGlass = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// INPUT-TO-PHOTON (estimate): felt input latency, composed from the SAME
    /// legs as glass-to-glass (host-encode + ~RTT/2 + client pipeline) for the
    /// frame that carries an input's response, recorded once per input stamp.
    /// It therefore reads >= glass_to_glass by construction. Labelled an estimate
    /// because the host doesn't mark which frame reflects an input. (The prior
    /// form measured time-to-next-present and read 4-5x BELOW g2g - bounded by
    /// the frame interval, not the round trip.) Shares the coarse bounds.
    let inputToPhoton = Stage(bounds: Stage.glassToGlassBoundsMs)

    func reset() {
        receiveToAssemble.reset()
        assembleToSubmit.reset()
        submitToOutput.reset()
        outputToPresent.reset()
        endToEnd.reset()
        glassToGlass.reset()
        inputToPhoton.reset()
        decodeIDR.reset()
        decodeP.reset()
        idrRoundTrip.reset()
    }

    /// Capture all stages into a plain value snapshot for the exporter to render.
    /// Taken on the exporter's serial queue (1Hz) - never the hot path.
    func snapshot() -> LatencyHistogramSnapshot {
        func stage(_ source: Stage) -> LatencyHistogramSnapshot.Stage {
            let captured = source.snapshot()
            return LatencyHistogramSnapshot.Stage(
                buckets: captured.buckets, boundsMs: source.bounds,
                sumMs: captured.sumMs, observationCount: captured.count)
        }
        return LatencyHistogramSnapshot(
            receiveToAssemble: stage(receiveToAssemble),
            assembleToSubmit: stage(assembleToSubmit),
            submitToOutput: stage(submitToOutput),
            outputToPresent: stage(outputToPresent),
            endToEnd: stage(endToEnd),
            glassToGlass: stage(glassToGlass),
            inputToPhoton: stage(inputToPhoton),
            decodeIDR: stage(decodeIDR),
            decodeP: stage(decodeP),
            idrRoundTrip: stage(idrRoundTrip))
    }
}

// The `LatencyHistogramSnapshot` plain value type (the per-tick snapshot of every
// stage's cumulative buckets) lives in TelemetryLatencySnapshot.swift, split out
// so this file stays under the length budget and focused on the live histograms +
// the per-frame tracker.
