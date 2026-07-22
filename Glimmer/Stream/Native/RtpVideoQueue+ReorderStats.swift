//
//  RtpVideoQueue+ReorderStats.swift
//
//  REORDER-DISPLACEMENT measurement (measurement ONLY - the reorder hold value
//  is untouched). Turns the raw out-of-order count into a checked invariant:
//  track how LATE each reordered packet arrives (ms + packets), assert
//  displacement < reorder hold, and count violations. On a tuned single-AP
//  wifi path, reorders are 802.11 Block-Ack reorder-buffer releases with
//  displacement bounded by MAC retry latency (single-digit ms) - driving the
//  COUNT to zero is physics-impossible on shared spectrum; proving every
//  reorder lands inside the hold is the correct target.
//
//  HOT-PATH SAFETY: runs ONLY on the rare out-of-order branch (0.0009% of
//  packets on the reference session), on the single receive thread. No
//  allocation; the histogram observes + counter increment are self-locked leaf
//  adds gated on the telemetry tracker. Displacement-ms source, in order:
//    * EXACT: the single-slot open-gap anchor (arrival time of the packet that
//      overtook this one), when the late seq falls inside the anchored range.
//    * FALLBACK: seq-distance x the window's mean inter-packet interval, when
//      the anchor was overwritten by a newer gap.
//

import Foundation

extension RtpVideoQueue {

    /// Record one reordered packet's displacement. Called from
    /// `accumulateReceiveQuality` on the genuine-reorder branch only.
    func recordReorderDisplacement(seq: UInt16, receiveTimeUs: UInt64) {
        // Displacement in packets: wrap-aware distance behind the highest seq
        // accepted (how many sequence slots overtook it, dups notwithstanding).
        let dispPackets = Int(Self.u16(Int(seqHighestSeen) - Int(seq)))
        let dispMs: Double
        if haveOpenGap,
           !Self.isBefore16(seq, gapOpenLowSeq),
           !Self.isBefore16(gapOpenHighSeq, seq),
           receiveTimeUs >= gapOpenAtUs {
            // Exact: lateness vs the arrival of the first packet that overtook it.
            dispMs = Double(receiveTimeUs &- gapOpenAtUs) / 1000.0
        } else {
            // Fallback: seq distance x the window's mean inter-arrival. Window
            // elapsed / packet count are both already maintained; ~200µs/pkt at
            // 5k pps. Never negative; documented optimistic-vs-exact tradeoff
            // in the header.
            let elapsedUs = receiveTimeUs > metricsWindowStartUs
                ? Double(receiveTimeUs &- metricsWindowStartUs) : 0
            let meanGapUs = packetsInWindow > 1 ? elapsedUs / Double(packetsInWindow) : 200
            dispMs = Double(dispPackets) * meanGapUs / 1000.0
        }
        if dispMs > reorderDispSessionMaxMs { reorderDispSessionMaxMs = dispMs }
        if dispPackets > reorderDispSessionMaxPackets { reorderDispSessionMaxPackets = dispPackets }
        // THE INVARIANT: a reorder displaced past the live hold outlived its
        // release window (it was promoted to pre-FEC loss). Always-live counter;
        // the only reorder signal worth alerting on.
        let holdMs = Double(reorderWindowUs) / 1000.0
        if dispMs > holdMs {
            TelemetryCounters.shared.reorderHoldExceededTotal.increment()
        }
        // Distribution (telemetry-gated; ~46 observations per reference session).
        if let tracker = FrameTimingTracker.shared {
            tracker.reorderDisplacementMs.observe(dispMs)
            tracker.reorderDisplacementPackets.observe(Double(dispPackets))
        }
    }

    /// Flush the displacement gauge alongside the per-window FEC health publish
    /// (maybeLogMetrics, ~2s cadence). Session-lifetime maxes + the live hold,
    /// so the exporter can emit the margin without touching this thread.
    func publishReorderDisplacementGauge() {
        TelemetryCounters.shared.setReorderDisplacement(
            TelemetryCounters.ReorderDisplacementSnapshot(
                maxMs: reorderDispSessionMaxMs,
                maxPackets: reorderDispSessionMaxPackets,
                holdMs: Double(reorderWindowUs) / 1000.0))
    }
}
