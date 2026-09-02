//
//  Types+StatsSnapshotHostEncode.swift
//
//  The overlay's "Host encode" row: the host's per-frame capture+encode time
//  measured against the frame budget. Split out of Types+StatsSnapshot.swift
//  (which is already at the size bar) because this row carries budget
//  arithmetic no other row needs, and it is the row that answers the question
//  the fps rows can't: WHY the host started skipping frames.
//

import Foundation

extension StreamStatsSnapshot {
    /// "8.0 ms / 4.2" - average host capture+encode time this window against
    /// the frame budget (1000 / requested fps). The budget half is the point
    /// of the row: when a heavy game pushes Sunshine's encode past one frame
    /// time the host has no choice but to skip frames, and the fps rows show
    /// only the sag that follows. Window-relative, like every other row here
    /// (the accumulators reset each snapshot).
    ///
    /// A nil average means the host reported nothing this window (GFE never
    /// populates the field; Sunshine emits zero for repeated frames), so the
    /// row shows the same em-dash every other unmeasured row shows - never
    /// "0.0 ms", which would read as a flawless host.
    func formatHostEncode(targetFps: Double) -> String {
        guard let avg = avgHostProcessingLatencyMs else { return "\u{2014}" }
        // No negotiated rate yet means no budget to compare against; the raw
        // encode time is still honest on its own.
        guard targetFps > 0 else { return String(format: "%.1f ms", avg) }
        return String(format: "%.1f ms / %.1f", avg, 1000.0 / targetFps)
    }

    /// Host-encode health against the frame budget: healthy below 80% of a
    /// frame time, warning across the 80-100% band (the host is riding the
    /// edge, so any scene-complexity spike starts costing frames), critical
    /// once encode exceeds the budget outright (the host cannot sustain the
    /// requested rate - the bottleneck is its encoder, not the link or our
    /// client). Neutral until the host reports a value, so an unmeasurable
    /// row never colours like a healthy one.
    func hostEncodeHealth(targetFps: Double) -> StatsRow.Health {
        guard let avg = avgHostProcessingLatencyMs, targetFps > 0 else { return .neutral }
        let frameBudget = 1000.0 / targetFps
        if avg > frameBudget { return .critical }
        if avg >= frameBudget * 0.8 { return .warning }
        return .healthy
    }
}
