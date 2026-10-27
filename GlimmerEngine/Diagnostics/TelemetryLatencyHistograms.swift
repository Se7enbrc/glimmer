// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)

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

/// Cumulative atomic buckets, sums and counts support session and windowed percentiles.
/// Snapshot once per capture tick, never once per frame.
package final class LatencyHistograms: @unchecked Sendable {

    package init() {}

    /// One stage stores cumulative counts at each inclusive upper bound.
    package final class Stage: @unchecked Sendable {
        /// Fine sub-stage bounds preserve small latency differences without losing long stalls.
        /// The snapshot carries these same bounds to the quantile estimator.
        package static let boundsMs: [Double] = [
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
        package static let glassToGlassBoundsMs: [Double] = [
            1, 2, 4, 6, 8, 10, 12, 16, 20, 25, 30, 40, 50, 66, 90, 132, 200, 300, 528, 1056
        ]

        /// OUTPUT→PRESENT (pacing) bounds. The default `boundsMs` jumps 16→33→66, a
        /// blind ~30ms bucket right where the pacing tail lives (multi-vsync holds land
        /// at 17-42ms), so p95/p99 had no resolution there. Adds 20/25/40/50 across it.
        package static let outputToPresentBoundsMs: [Double] = [
            0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 25, 33, 40, 50, 66, 132, 264, 528
        ]

        /// Stage-specific bounds keep fine pipeline and coarse composite histograms consistent.
        package let bounds: [Double]

        private let lock = os_unfair_lock_t.allocate(capacity: 1)
        private var bucketCounts: [UInt64]
        private var sumMs: Double = 0
        private var totalCount: UInt64 = 0

        package init(bounds: [Double] = Stage.boundsMs) {
            self.bounds = bounds
            lock.initialize(to: os_unfair_lock_s())
            bucketCounts = [UInt64](repeating: 0, count: bounds.count)
        }
        deinit { lock.deallocate() }

        /// Record one observation (a stage delta, in ms). Branchless-ish bucket
        /// find over a 12-element ascending array, then a single locked update of
        /// the matching cumulative buckets + sum + count.
        package func observe(_ valueMs: Double) {
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
        package func snapshot() -> (buckets: [UInt64], sumMs: Double, count: UInt64) {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            // Copy on the exporter thread so the next real-time observation cannot trigger Array COW.
            return (bucketCounts.map { $0 }, sumMs, totalCount)
        }

        /// Snapshot as the renderer's value type. Used by standalone stages (e.g.
        /// the input-local-latency histogram) that aren't part of the composite
        /// `LatencyHistogramSnapshot`.
        package func snapshotValue() -> LatencyHistogramSnapshot.Stage {
            let captured = snapshot()
            return LatencyHistogramSnapshot.Stage(
                buckets: captured.buckets, boundsMs: bounds,
                sumMs: captured.sumMs, observationCount: captured.count)
        }

        package func reset() {
            os_unfair_lock_lock(lock)
            for index in bucketCounts.indices { bucketCounts[index] = 0 }
            sumMs = 0
            totalCount = 0
            os_unfair_lock_unlock(lock)
        }
    }

    package let receiveToAssemble = Stage()
    package let assembleToSubmit = Stage()
    package let submitToOutput = Stage()
    package let outputToPresent = Stage(bounds: Stage.outputToPresentBoundsMs)
    package let endToEnd = Stage(bounds: Stage.outputToPresentBoundsMs)

    /// DECODE time split by frame type (signal: DECODE). The submit→output
    /// (VTDecompressionSessionDecodeFrame → output callback) delta, bucketed
    /// SEPARATELY for IDR keyframes vs P-frames. An IDR is a full-resolution
    /// intra frame and decodes much slower than a delta P-frame, so the combined
    /// `submitToOutput` histogram blurs two distributions; splitting them shows
    /// the true per-type decode cost and catches an IDR-decode-cost spike (the
    /// recurring-IDR-on-idle-resume hypothesis) that the blended view hides. Both
    /// use the fine sub-stage bounds (decode lands in the few-ms range).
    package let decodeIDR = Stage()
    package let decodeP = Stage()

    /// IDR/RFI ROUND-TRIP (signal: IDR-RTT). Time from our requestIdrFrame/RFI
    /// SEND to the matching IDR/recovery frame ARRIVING (both client-side). Spans
    /// a network round trip plus the host's encode of a full intra frame, so it
    /// uses the coarse composite bounds (a recovery on a bad link is tens to
    /// hundreds of ms). Fed once per matched request from the depacketizer.
    package let idrRoundTrip = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// GLASS-TO-GLASS: the "how good is it" number - host capture+encode
    /// (Sunshine `frameHostProcessingLatency`) + network transit (~RTT/2) + our
    /// pipeline (receive→present, the endToEnd stage). Computed per frame at
    /// present and recorded here so the exporter publishes p50/p95/p99 over time.
    /// Spans a much wider range than any single sub-stage (host AV1 encode alone
    /// can be tens of ms), so it gets its own coarse-tailed bound set below.
    package let glassToGlass = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// INPUT-TO-PHOTON (estimate), once per input stamp: client input legs + uplink
    /// ~RTT/2 + half a host frame + that frame's glass-to-glass (see
    /// composeInputToPhoton). Shares the coarse bounds.
    package let inputToPhoton = Stage(bounds: Stage.glassToGlassBoundsMs)

    package func reset() {
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
    package func snapshot() -> LatencyHistogramSnapshot {
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

#endif
