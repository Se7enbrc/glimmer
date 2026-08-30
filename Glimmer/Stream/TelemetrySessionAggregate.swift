//
//  TelemetrySessionAggregate.swift
//
//  `SessionAggregate` - the running per-tick rollup the telemetry exporter folds
//  each 1Hz snapshot into, and the GATE-AWARE tick classification that makes it
//  honest: fps min/avg/max, peak pacing depth, the worst single 1s windows, the
//  ACTIVE-seconds latency stitch, and the per-segment second counts. Split out
//  of TelemetrySessionReport.swift (pure move, same file-split idiom as the rest
//  of the telemetry rig) to keep both units under the length limit; see that
//  file for the assembled scorecard this feeds and the gating/safety contract.
//
//  Accumulated on the exporter's serial queue, once per 1Hz tick - never a hot
//  path, and never built at all when the telemetry gate is off.
//

import Foundation

/// Per-session running rollup, folded one snapshot at a time on the exporter
/// queue. Tracks the things the cumulative latency histograms don't: fps
/// min/avg/max, peak pacing depth, and the worst single 1s windows for the
/// signals where a transient spike is the story.
///
/// GATE-AWARE: every tick is classified ACTIVE / GATED / BRING-UP /
/// RESUME before folding, and the HEADLINE numbers (fps min/avg/max, worst
/// windows, latency percentiles) are computed over ACTIVE seconds only. The
/// all-session versions lie: a long decode-gated AFK window working as designed
/// dragged a scorecard's fps-min to 0 and its worst cadence to tens of seconds,
/// and a cold-open bring-up era polluted the cumulative percentiles for minutes
/// after behavior normalized. The raw all-session values stay under
/// explicitly-named `*_raw` keys (with the worst second's segment tag), so
/// nothing is hidden - it is labeled.
struct SessionAggregate {

    /// One 1Hz tick's segment. Priority order is the classification order:
    /// a hidden (suppressed/gated) second is GATED even inside bring-up; a
    /// visible second inside the first ~10s is BRING-UP; a visible second
    /// within ~5s of an un-gate edge is RESUME; everything else is ACTIVE.
    enum TickSegment: String {
        case active
        case gated
        case bringUp = "bring_up"
        case resume
    }

    /// Bring-up era: connect-relative seconds treated as cold-open settling
    /// (game load / encoder ramp / cushion ratchet - content legitimately
    /// wild, not stream quality).
    static let bringUpSeconds = 10.0
    /// Resume corridor: seconds after an un-gate/un-suppress edge during
    /// which drops/cadence are designed catch-up (queued-frame drain, IDR
    /// resync), not steady-state quality.
    static let resumeCorridorSeconds = 5.0

    /// min / avg / max accumulator for a per-tick gauge. avg is the mean across
    /// ticks that had a value (a divide-by-`samples`), which for a 1Hz cadence is
    /// the per-second-averaged session mean.
    struct Stat {
        var min: Double?
        var max: Double?
        var sum: Double = 0
        var samples: Int = 0
        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            min = min.map { Swift.min($0, value) } ?? value
            max = max.map { Swift.max($0, value) } ?? value
            sum += value
            samples += 1
        }
        var avg: Double? { samples > 0 ? sum / Double(samples) : nil }
    }

    // ---- fps stats: HEADLINE over ACTIVE seconds, raw over every tick ----
    var receivedFps = Stat()
    var decodedFps = Stat()
    var renderedFps = Stat()
    var receivedFpsRaw = Stat()
    var decodedFpsRaw = Stat()
    var renderedFpsRaw = Stat()

    /// Peak pacing-queue depth seen across the whole session (the deepest the
    /// jitter buffer ever rode) - a latency-creep tell the live gauge misses.
    var peakPacingDepth: Int = 0

    // ---- Worst single 1s windows (the transient that defined the run) ----
    // Headline pair = worst ACTIVE second; `*Raw` = worst second of the whole
    // session, with the segment it landed in (a raw worst tagged `gated` or
    // `resume` is the instrument seeing a designed window, not the stream).
    /// Worst per-tick mean present-cadence error (ms) + the connect-relative
    /// second it happened on - the hitch a user feels, and exactly when.
    var worstPresentCadenceErrorMs: Double?
    var worstPresentCadenceErrorAtSeconds: Double?
    var worstPresentCadenceErrorRawMs: Double?
    var worstPresentCadenceErrorRawAtSeconds: Double?
    var worstPresentCadenceErrorRawSegment: TickSegment?
    /// Worst per-tick glass-to-glass p95 (ms) + when - the second the headline
    /// "how good is it" number was at its worst.
    var worstGlassToGlassP95Ms: Double?
    var worstGlassToGlassP95AtSeconds: Double?
    var worstGlassToGlassP95RawMs: Double?
    var worstGlassToGlassP95RawAtSeconds: Double?
    var worstGlassToGlassP95RawSegment: TickSegment?

    /// How many 1Hz ticks were folded in - a sanity/coverage count.
    var tickCount: Int = 0
    // ---- Per-segment second counts (ticks ≈ seconds at the 1Hz cadence) ----
    var activeTicks = 0
    var gatedTicks = 0
    var bringUpTicks = 0
    var resumeTicks = 0
    /// Previous tick's hidden (suppressed-or-gated) state - the edge detector
    /// that arms the resume corridor.
    private var prevTickHidden = false
    /// Connect-relative end of the live resume corridor, nil when none.
    private var resumeCorridorUntilSeconds: Double?

    // ---- ACTIVE-seconds latency accumulation ----
    /// Cumulative histogram snapshot from the PREVIOUS tick - the baseline the
    /// per-tick delta is sliced against.
    private var prevLatencyCumulative: LatencyHistogramSnapshot?
    /// Sum of the per-tick histogram deltas folded on ACTIVE ticks only - the
    /// scorecard's headline percentile source. The cumulative histograms stay
    /// the raw truth (`latency_raw`); this is the same data minus the
    /// gated/bring-up/resume seconds that polluted the cold-open reads.
    private(set) var activeLatency: LatencyHistogramSnapshot?

    /// Classify this tick AND advance the corridor state. Called once per
    /// capture tick, BEFORE `accumulate`, on the exporter queue.
    mutating func classifyTick(atSeconds seconds: Double, hidden: Bool) -> TickSegment {
        // Arm the resume corridor at the un-hide edge (gated/suppressed →
        // visible); a re-hide simply re-arms on its own next clear edge.
        if prevTickHidden && !hidden {
            resumeCorridorUntilSeconds = seconds + Self.resumeCorridorSeconds
        }
        prevTickHidden = hidden
        let segment: TickSegment
        if hidden {
            segment = .gated
        } else if seconds <= Self.bringUpSeconds {
            segment = .bringUp
        } else if let until = resumeCorridorUntilSeconds, seconds < until {
            segment = .resume
        } else {
            segment = .active
        }
        switch segment {
        case .active: activeTicks += 1
        case .gated: gatedTicks += 1
        case .bringUp: bringUpTicks += 1
        case .resume: resumeTicks += 1
        }
        return segment
    }

    /// Fold one tick's CUMULATIVE histogram snapshot: slice the per-tick delta
    /// off the previous tick's baseline and add it to the active accumulation
    /// iff this tick is ACTIVE. Must be called EVERY tick (the baseline has to
    /// advance through gated spans too, or the first active tick after one
    /// would swallow the whole hidden era's observations).
    mutating func foldLatency(_ current: LatencyHistogramSnapshot, active: Bool) {
        defer { prevLatencyCumulative = current }
        guard active else { return }
        // First-ever active tick with no baseline can't happen in practice
        // (bring-up ticks precede it and arm the baseline), but fall back to
        // the cumulative-so-far rather than dropping the tick if it does.
        let delta = prevLatencyCumulative.map {
            LatencyRollingWindow.difference(current, minus: $0)
        } ?? current
        activeLatency = activeLatency.map { LatencyRollingWindow.sum($0, plus: delta) } ?? delta
    }

    // ---- ENV-SIGNAL judge inputs ----
    /// Ticks (~seconds) spent in each env state (index = the state ordinal:
    /// clear/caution/distress) + the final transition count - "how long was
    /// each state, and how often did it move" is the scorecard half of
    /// judging the state machine against felt events.
    var envStateSeconds = [Int](repeating: 0, count: 3)
    var envStateChangesTotal: UInt64 = 0

    /// Fold one tick's env state. Called on the exporter queue right after
    /// `accumulate` (the env fields ride Extras, not the snapshot).
    mutating func noteEnvState(ordinal: Int, changesTotal: UInt64) {
        if envStateSeconds.indices.contains(ordinal) { envStateSeconds[ordinal] += 1 }
        envStateChangesTotal = changesTotal
    }

    /// Fold one per-second snapshot into the rollup. Called on the exporter
    /// queue, after `classifyTick` decided this tick's segment.
    mutating func accumulate(_ snap: TelemetrySnapshot, segment: TickSegment) {
        tickCount += 1
        let isActive = segment == .active
        if let value = snap.receivedFps {
            receivedFpsRaw.add(value)
            if isActive { receivedFps.add(value) }
        }
        if let value = snap.decodedFps {
            decodedFpsRaw.add(value)
            if isActive { decodedFps.add(value) }
        }
        if let value = snap.renderedFps {
            renderedFpsRaw.add(value)
            if isActive { renderedFps.add(value) }
        }
        if let depth = snap.pacingQueueDepth { peakPacingDepth = Swift.max(peakPacingDepth, depth) }

        if let err = snap.presentCadenceErrorMs {
            if err > (worstPresentCadenceErrorRawMs ?? -1) {
                worstPresentCadenceErrorRawMs = err
                worstPresentCadenceErrorRawAtSeconds = snap.sinceConnectSeconds
                worstPresentCadenceErrorRawSegment = segment
            }
            if isActive, err > (worstPresentCadenceErrorMs ?? -1) {
                worstPresentCadenceErrorMs = err
                worstPresentCadenceErrorAtSeconds = snap.sinceConnectSeconds
            }
        }
        // Worst glass-to-glass: use the per-tick p95 from the histogram so a
        // single bad second stands out (the cumulative session p95 would smear
        // it). Cheap - the histogram snapshot is already on the snapshot.
        if let histograms = snap.latencyHistograms,
           let p95 = TelemetryRenderer.histogramQuantile(0.95, stage: histograms.glassToGlass) {
            if p95 > (worstGlassToGlassP95RawMs ?? -1) {
                worstGlassToGlassP95RawMs = p95
                worstGlassToGlassP95RawAtSeconds = snap.sinceConnectSeconds
                worstGlassToGlassP95RawSegment = segment
            }
            if isActive, p95 > (worstGlassToGlassP95Ms ?? -1) {
                worstGlassToGlassP95Ms = p95
                worstGlassToGlassP95AtSeconds = snap.sinceConnectSeconds
            }
        }
    }
}
