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

    /// Input-to-photon (signal 2), an ESTIMATE recorded once per fresh input stamp
    /// (`noteInputEvent`), so an idle stream's static frames can't re-count an old
    /// input. The host doesn't mark which frame reflects an input.
    func computeInputToPhoton(presentNanos: UInt64, glassToGlassMs: Double?,
                              hostFrameIntervalMs: Double) -> Double? {
        guard let lastInputNanos = TelemetryCounters.shared.lastInputNanos else { return nil }
        guard presentNanos > lastInputNanos else { return nil }
        // Consume-once gate on the lock this present path already takes for
        // the warmup/resume tags - one extra compare+store, gate-on only.
        os_unfair_lock_lock(warmupLock)
        let alreadyConsumed = lastInputConsumedNanos == lastInputNanos
        lastInputConsumedNanos = lastInputNanos
        let clientLegsMs = lastInputLegsMs
        os_unfair_lock_unlock(warmupLock)
        guard !alreadyConsumed, let glassToGlassMs else { return nil }
        return Self.composeInputToPhoton(
            glassToGlassMs: glassToGlassMs, clientLegsMs: clientLegsMs,
            rttMs: TelemetryCounters.shared.rttMs, hostFrameIntervalMs: hostFrameIntervalMs)
    }

    /// The input round trip: client legs (deliver + queue→wire), uplink ~RTT/2, the
    /// average wait for the host's next frame (half an interval), then that frame's
    /// glass-to-glass (which carries the downlink). Unknown legs (0) add nothing.
    static func composeInputToPhoton(glassToGlassMs: Double, clientLegsMs: Double,
                                     rttMs: Double, hostFrameIntervalMs: Double) -> Double {
        glassToGlassMs + max(clientLegsMs, 0) + max(rttMs, 0) / 2 + max(hostFrameIntervalMs, 0) / 2
    }
}
