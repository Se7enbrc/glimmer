//
//  TelemetryLatency+Composites.swift
//
//  The COMPOSITE latency stages - glass-to-glass and the input-to-photon
//  estimate - computed per presented frame by `recordPresent`. Topic split from
//  TelemetryLatency.swift (file-length budget); see that file for the tracker,
//  the gate/safety contract, and the warmup/resume ingestion gates these feed
//  past. Everything here runs on the (gate-on-only) present path.
//

import Foundation
import os

extension FrameTimingTracker {

    /// Sum the available glass-to-glass legs (signal 1). host-encode and transit
    /// are each optional; pipeline (endToEnd) is the spine. Returns nil only when
    /// NO leg is known (a frame with no pipeline delta - shouldn't happen for a
    /// presented frame). `~RTT/2` is the one-way transit estimate from the current
    /// smoothed ENet RTT; 0 RTT means "not yet known" and the transit leg is
    /// omitted rather than counted as 0.
    func computeGlassToGlass(hostEncodeMs: Double, pipelineMs: Double?) -> Double? {
        var total = 0.0
        var haveAny = false
        if hostEncodeMs > 0 { total += hostEncodeMs; haveAny = true }
        let rtt = TelemetryCounters.shared.rttMs
        if rtt > 0 { total += rtt / 2.0; haveAny = true }
        if let pipelineMs { total += pipelineMs; haveAny = true }
        return haveAny ? total : nil
    }

    /// Input-to-photon (signal 2): a felt-latency estimate composed from the
    /// SAME known legs as glass-to-glass (host-encode + ~RTT/2 + client
    /// pipeline), recorded ONCE per fresh input stamp. The old form -
    /// (first present after the stamp) − stamp - measured time-to-NEXT-present,
    /// bounded by the frame interval, so it read 4-5x BELOW glass-to-glass
    /// (structurally impossible for felt latency: a present ~8ms out shows
    /// content fixed a host round-trip ago). Composing the legs makes it
    /// >= glass_to_glass by construction. Consume-once on the input stamp keeps
    /// "one observation per input" so an idle stream's static frames can't
    /// re-count an old input. Reuses the always-live last-input instant the
    /// InputBatcher stamps via `noteInputEvent()` for the gate only - no new
    /// clock, no new input-side write.
    func computeInputToPhoton(presentNanos: UInt64, glassToGlassMs: Double?) -> Double? {
        guard let lastInputNanos = TelemetryCounters.shared.lastInputNanos else { return nil }
        guard presentNanos > lastInputNanos else { return nil }
        // Consume-once gate on the lock this present path already takes for
        // the warmup/resume tags - one extra compare+store, gate-on only.
        os_unfair_lock_lock(warmupLock)
        let alreadyConsumed = lastInputConsumedNanos == lastInputNanos
        lastInputConsumedNanos = lastInputNanos
        os_unfair_lock_unlock(warmupLock)
        guard !alreadyConsumed else { return nil }
        // HONEST composition: the felt input round trip is the same pipeline
        // glass-to-glass measures for THIS input-carrying frame - input rides
        // the link, the host encodes the response, it transits back, our
        // pipeline presents it. Same legs, so it can never read below g2g.
        return glassToGlassMs
    }
}
