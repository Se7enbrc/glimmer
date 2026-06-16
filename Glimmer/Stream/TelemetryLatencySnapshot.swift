//
//  TelemetryLatencySnapshot.swift
//
//  The plain value type the latency rig hands to the renderers: one tick's
//  snapshot of every per-stage latency histogram - plus the ROLLING 60s window
//  derived from a ring of those snapshots (the "is bad" view next to the
//  cumulative "was bad" one). Split out of TelemetryLatency.swift so that file
//  stays under the length budget and focused on the live atomic histograms +
//  the per-frame timing tracker; see that file for the recording path and the
//  gate/safety contract.
//

import Foundation

/// One tick's snapshot of all per-stage latency histograms. Plain value type
/// built on the exporter queue from `LatencyHistograms`; rendered to both wire
/// forms (Prometheus `_bucket/_sum/_count`, NDJSON p50/p95/p99) and the session
/// report. Each stage is its cumulative bucket counts + sum(ms) + count.
struct LatencyHistogramSnapshot: Sendable {
    struct Stage: Sendable {
        var buckets: [UInt64]
        /// The bucket upper bounds (ms) THIS stage was recorded against - carried
        /// on the snapshot so the Prometheus render + NDJSON quantile estimator
        /// use the matching bounds (fine for sub-stages, coarse for the composite
        /// glass-to-glass / input-to-photon / idr-round-trip stages) without a
        /// second lookup.
        var boundsMs: [Double]
        var sumMs: Double
        /// Total observations (rendered as Prometheus `_count`). Named
        /// `observationCount` rather than `count` so a "no data this tick" check
        /// doesn't trip SwiftLint's `empty_count` rule, which flags any property
        /// literally named `count` compared to zero - a false positive here since
        /// this is a numeric total, not a collection size.
        var observationCount: UInt64
        /// True iff this stage observed at least one frame this session.
        var hasObservations: Bool { observationCount != 0 }
    }
    var receiveToAssemble: Stage
    var assembleToSubmit: Stage
    var submitToOutput: Stage
    var outputToPresent: Stage
    var endToEnd: Stage
    /// Glass-to-glass: host-encode + ~RTT/2 + our pipeline. THE headline number.
    var glassToGlass: Stage
    /// Input-to-photon estimate: next-frame-present − last-input-sent.
    var inputToPhoton: Stage
    /// DECODE time (submit→output) for IDR keyframes only.
    var decodeIDR: Stage
    /// DECODE time (submit→output) for P-frames only.
    var decodeP: Stage
    /// IDR/RFI round-trip: request-sent → matching IDR/recovery frame arrived.
    var idrRoundTrip: Stage
}

// MARK: - Rolling 60s window

/// ROLLING 60s latency window: a fixed ring of the per-tick cumulative bucket
/// snapshots, differenced bucket-wise (current − the entry from 60 ticks ago)
/// to yield an exact 60-second-window histogram for the same quantile
/// estimator the cumulative NDJSON fields use. The cumulative session-lifetime
/// percentiles can mislead (a start-chug looks far worse than felt for as long
/// as the cumulative tail takes to age out); the windowed pair disambiguates
/// "was bad" vs "is bad" in the offline NDJSON, where a dashboard's `rate()`
/// windows can't help.
///
/// MEMORY-BOUND + ZERO-COST-OFF: exactly `windowTicks` snapshots (~10 stages ×
/// ~20 UInt64 buckets each, ≈ 100KB worst case - the bounds arrays are shared
/// CoW references), owned by the exporter's per-session `CaptureBaselines`.
/// Confined to the exporter's serial `workQueue` (no lock needed), and when
/// telemetry is off the exporter - and therefore this ring - never exists.
final class LatencyRollingWindow {
    /// Window span in capture ticks (1Hz capture → seconds).
    static let windowTicks = 60

    private var ring: [LatencyHistogramSnapshot?]
    private var writeIndex = 0
    init() { ring = Array(repeating: nil, count: Self.windowTicks) }

    /// Fold one tick's cumulative snapshot into the ring and return the
    /// windowed difference (current − ring[t−60]). Until the ring fills, the
    /// baseline slot is still nil and the cumulative snapshot IS the rolling
    /// window (the window honestly spans min(session age, 60s)). The buckets
    /// are monotonic within a session and the ring is per-session, so
    /// old ≤ current always; the subtraction still saturates defensively.
    func advance(with current: LatencyHistogramSnapshot) -> LatencyHistogramSnapshot {
        let baseline = ring[writeIndex]
        ring[writeIndex] = current
        writeIndex = (writeIndex + 1) % Self.windowTicks
        guard let baseline else { return current }
        return Self.difference(current, minus: baseline)
    }

    /// Bucket-wise difference of two cumulative snapshots. Subtracting one
    /// cumulative-`le` histogram from a later one yields the cumulative-`le`
    /// histogram of just the observations between them, so the result feeds
    /// the existing `histogramQuantile` estimator unchanged. (Internal, not
    /// private: the scorecard's ACTIVE-seconds accumulator reuses it to slice
    /// per-tick deltas out of the cumulative stream - see SessionAggregate.)
    static func difference(
        _ current: LatencyHistogramSnapshot, minus old: LatencyHistogramSnapshot
    ) -> LatencyHistogramSnapshot {
        func stage(
            _ current: LatencyHistogramSnapshot.Stage, _ old: LatencyHistogramSnapshot.Stage
        ) -> LatencyHistogramSnapshot.Stage {
            // A mismatched bucket count can only mean the stage was rebuilt
            // mid-session (doesn't happen today) - fall back to cumulative
            // rather than subtract across different bounds.
            guard current.buckets.count == old.buckets.count else { return current }
            var buckets = current.buckets
            for index in buckets.indices {
                buckets[index] = buckets[index] >= old.buckets[index]
                    ? buckets[index] - old.buckets[index] : 0
            }
            let count = current.observationCount >= old.observationCount
                ? current.observationCount - old.observationCount : 0
            return LatencyHistogramSnapshot.Stage(
                buckets: buckets, boundsMs: current.boundsMs,
                sumMs: Swift.max(current.sumMs - old.sumMs, 0),
                observationCount: count)
        }
        return LatencyHistogramSnapshot(
            receiveToAssemble: stage(current.receiveToAssemble, old.receiveToAssemble),
            assembleToSubmit: stage(current.assembleToSubmit, old.assembleToSubmit),
            submitToOutput: stage(current.submitToOutput, old.submitToOutput),
            outputToPresent: stage(current.outputToPresent, old.outputToPresent),
            endToEnd: stage(current.endToEnd, old.endToEnd),
            glassToGlass: stage(current.glassToGlass, old.glassToGlass),
            inputToPhoton: stage(current.inputToPhoton, old.inputToPhoton),
            decodeIDR: stage(current.decodeIDR, old.decodeIDR),
            decodeP: stage(current.decodeP, old.decodeP),
            idrRoundTrip: stage(current.idrRoundTrip, old.idrRoundTrip))
    }

    /// Bucket-wise SUM of two cumulative snapshots - `difference`'s inverse,
    /// used by the scorecard's ACTIVE-seconds accumulator to stitch per-tick
    /// deltas back into one histogram covering only the active seconds. A
    /// mismatched bucket count (a mid-session stage rebuild - doesn't happen
    /// today) keeps the accumulated side rather than adding across bounds.
    static func sum(
        _ accumulated: LatencyHistogramSnapshot, plus delta: LatencyHistogramSnapshot
    ) -> LatencyHistogramSnapshot {
        func stage(
            _ acc: LatencyHistogramSnapshot.Stage, _ delta: LatencyHistogramSnapshot.Stage
        ) -> LatencyHistogramSnapshot.Stage {
            guard acc.buckets.count == delta.buckets.count else { return acc }
            var buckets = acc.buckets
            for index in buckets.indices { buckets[index] &+= delta.buckets[index] }
            return LatencyHistogramSnapshot.Stage(
                buckets: buckets, boundsMs: acc.boundsMs,
                sumMs: acc.sumMs + delta.sumMs,
                observationCount: acc.observationCount &+ delta.observationCount)
        }
        return LatencyHistogramSnapshot(
            receiveToAssemble: stage(accumulated.receiveToAssemble, delta.receiveToAssemble),
            assembleToSubmit: stage(accumulated.assembleToSubmit, delta.assembleToSubmit),
            submitToOutput: stage(accumulated.submitToOutput, delta.submitToOutput),
            outputToPresent: stage(accumulated.outputToPresent, delta.outputToPresent),
            endToEnd: stage(accumulated.endToEnd, delta.endToEnd),
            glassToGlass: stage(accumulated.glassToGlass, delta.glassToGlass),
            inputToPhoton: stage(accumulated.inputToPhoton, delta.inputToPhoton),
            decodeIDR: stage(accumulated.decodeIDR, delta.decodeIDR),
            decodeP: stage(accumulated.decodeP, delta.decodeP),
            idrRoundTrip: stage(accumulated.idrRoundTrip, delta.idrRoundTrip))
    }
}
