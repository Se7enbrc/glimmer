//
//  TelemetryLatency+Composites.swift
//
//  The COMPOSITE latency stages — glass-to-glass and the input-to-photon
//  estimate — computed per presented frame by `recordPresent`. Topic split from
//  TelemetryLatency.swift (file-length budget); see that file for the tracker,
//  the gate/safety contract, and the warmup/resume ingestion gates these feed
//  past. Everything here runs on the (gate-on-only) present path.
//

import Foundation
import os

extension FrameTimingTracker {

    /// Sum the available glass-to-glass legs (signal 1). host-encode and transit
    /// are each optional; pipeline (endToEnd) is the spine. Returns nil only when
    /// NO leg is known (a frame with no pipeline delta — shouldn't happen for a
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

    /// Input-to-photon estimate (signal 2): (this present) − (last input sent),
    /// recorded ONCE per input stamp — the first present after an input is the
    /// frame that plausibly CARRIES its visual result; every later present is a
    /// static frame between inputs, not latency. Consume-once replaces the old
    /// 38ms freshness cap: the cap silently dropped genuinely-slow outliers and
    /// pinned the metric's max/p99 at exactly the cap (max ~37.999ms — the
    /// distribution's right edge measured the WINDOW, not the pipeline). The
    /// artifact the cap fought — static frames
    /// re-counting an old input (p95 158 / p99 254ms at a 250ms window) — is
    /// killed at the source by consume-once: one stamp, one observation. Still
    /// reuses the always-live last-input instant the InputBatcher stamps via
    /// `noteInputEvent()`, so there is NO new input-side write.
    func computeInputToPhoton(presentNanos: UInt64) -> Double? {
        guard let lastInputNanos = TelemetryCounters.shared.lastInputNanos else { return nil }
        guard presentNanos > lastInputNanos else { return nil }
        // Consume-once gate on the lock this present path already takes for
        // the warmup/resume tags — one extra compare+store, gate-on only.
        os_unfair_lock_lock(warmupLock)
        let alreadyConsumed = lastInputConsumedNanos == lastInputNanos
        lastInputConsumedNanos = lastInputNanos
        os_unfair_lock_unlock(warmupLock)
        guard !alreadyConsumed else { return nil }
        let deltaMs = Double(presentNanos &- lastInputNanos) / 1_000_000.0
        // Plausibility ceiling, NOT a freshness cap: past ~1s the gap is a
        // stall/freeze with its own counters telling that story, and the
        // coarse composite bounds top out at 1056ms — a multi-second delta
        // would land shapeless in +Inf while poisoning the stage's sum.
        guard deltaMs <= Self.inputToPhotonPlausibleMaxMs else { return nil }
        return deltaMs
    }

    /// See the ceiling comment in `computeInputToPhoton` — beyond this the
    /// observation is a freeze, not input latency.
    static let inputToPhotonPlausibleMaxMs: Double = 1000.0
}
