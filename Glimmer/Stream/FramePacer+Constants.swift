// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  FramePacer+Constants.swift
//
//  The pacer's static tuning constants - FIFO caps, the adaptive jitter-buffer
//  depth schedule (baseline/cap/dead-zone/decay), the starvation failsafe
//  thresholds, and the present-loop backoff lateness. Split out of
//  FramePacer.swift to keep that file under the length limit; these are
//  module-internal `static let`s consumed across the pacer's extension files
//  (DueGate / AdaptiveDepth / Submit). Pure values - no logic.
//

import Foundation

extension FramePacer {

    /// Hard cap on the jitter/reorder FIFO. One slot above the adaptive target
    /// cap (`maxTargetDepth` = 5) so a saturated buffer under sustained jitter
    /// still has in-flight slack. On overflow the OLDEST (most stale) frame is
    /// dropped - a real-time stream wants the freshest pixels, not a backlog.
    /// Stays well under VideoDecoder.maxInFlightDecodes (fps-scaled, ~250ms, floor
    /// 15) so the adaptive buffer can never overrun the decode pool. On a clean link the
    /// queue rides at the depth-1 rest state; this cap only matters under the
    /// genuine measured-jitter (wifi) case where the buffer grows to absorb it.
    static let maxQueuedFrames = 6

    /// Percentile (0...1) of the PTS-delta window used as the SKIP-ROBUST cadence
    /// estimate (`skipRobustInterval`). The lower quartile reads the no-skip
    /// cluster - the true per-frame interval - instead of the median, which
    /// skipped frames (delivery dips / loss) drag UP by counting their multi-
    /// interval gaps as the cadence. p25 stays robust until >~75% of frames are
    /// skipped (catastrophic delivery) while a genuine uniform rate change still
    /// crosses it. See `skipRobustInterval` for the full rationale.
    static let cadencePercentile = 0.25

    /// PTS deltas to collect before the configured-fps cadence SEED is refined
    /// from the window. A lone startup gap (the first delta after an IDR, a cold-
    /// connect arrival burst) must not yank the cadence off the negotiated rate;
    /// holding the seed for the first few frames lets the window fill enough that
    /// the lower-quartile estimate is meaningful. ~8 frames ≈ 67ms at 120fps.
    static let minCadenceRefineSamples = 8

    /// Baseline REST depth: one frame of slack, the floor the adaptive target decays back to.
    /// Measured at fps ≈ refresh on a wired 240 Hz panel: output_to_present p50 3-4 ms (under
    /// one vsync), p95 7-10 ms. At fps < refresh the queue sits at 0-1 anyway.
    static let targetDepth = 1

    /// Upper bound on the adaptive target depth. EnvSignalController's headroom ladder tops
    /// out at level 3 (depth 4), so this only backstops it; kept under `maxQueuedFrames` so an
    /// overflow slot remains at the cap.
    static let maxTargetDepth = 5

    /// How quickly the adaptive target shrinks back to depth 1 once the published level drops:
    /// at most one frame per this many seconds, so a stale depth is gone within ~1 s.
    static let targetShrinkInterval = 0.25

    /// POST-GAP LENIENCY. Consecutive empty ticks that mark a real delivery GAP
    /// (~3 ≈ 25ms@120Hz) - past a healthy depth-1 beat's jitter, so ordinary
    /// motion-bunches (no empty stretch) don't trip it; only a true >50ms wifi gap.
    /// The discriminator the old blanket "queue ≤ target" leniency lacked.
    static let gapRecoveryTickThreshold = 3
    /// Lenient window after a gap edge: the catch-up fills toward `maxQueuedFrames`
    /// and plays out 1/vsync (over-target force-release) instead of trim-to-newest.
    /// 500ms = moonlight's pacing-history window. Latency exists only mid-burst; a
    /// surplus persisting past this is a standing build and trims tight.
    static let postDrainLenientSeconds = 0.5
    /// The lenient ceiling applies only while the stream runs below this
    /// fraction of the panel's nominal rate: at fps≈refresh frames arrive one
    /// per tick, so a parked catch-up never drains and rides as ~5 frames of lag.
    static let postGapDrainableRateRatio = 0.9
    /// A depth above target on every tick for this long is a standing extra frame of latency,
    /// not benign bunching, and trims to target (moonlight's ~500 ms pacing history).
    static let standingExtraFrameSeconds = 0.5

    /// After this many consecutive ticks with frames queued but nothing
    /// released, the in-pacer failsafe re-seeds the cadence base to force a
    /// release. ~8 ticks ≈ 33ms at 240Hz / 133ms at 60Hz - well clear of the
    /// healthy fps<refresh case (where idle ticks have an EMPTY-DUE queue, not
    /// a wedged non-empty one) but fast enough to break a real wedge long
    /// before the external watchdog's ~300ms window.
    static let starvationFailsafeTicks = 8

    /// Number of successful releases after which the grow-without-a-hitch hold is
    /// allowed to run. With the rest depth now 1, the grow-hold is structurally
    /// OFF on a clean link (it keys on `adaptiveTargetDepth > targetDepth`, and a
    /// clean link rests at `adaptiveTargetDepth == targetDepth == 1`), so this
    /// startup gate is MOOT on a clean link - there is no hold to suppress. It is
    /// retained as a belt-and-suspenders guard for the lossy case: if real
    /// measured jitter raises the target while the PTS-median cadence is still
    /// converging (the first ~30 frames ≈ ~0.25s at 120fps), the normal
    /// slack-relaxed due test is used until cadence locks, so the buffer primes
    /// from the link's natural slack without ever holding a frame late.
    static let startupGrowHoldReleases: UInt64 = 30
    /// Log the starvation diagnostic once the streak crosses this many ticks
    /// (slightly below the failsafe so the four diagnostic values are captured
    /// before the self-heal re-seed clears them).
    static let starvationLogTicks = 4

    /// A frame waiting out its own cadence (30fps on a 240Hz tick holds ~8 ticks) isn't
    /// starved, so the logged streak must also outlast one stream interval.
    static func starvationLogThreshold(streamInterval: CFTimeInterval, vsync: CFTimeInterval) -> Int {
        guard streamInterval.isFinite, vsync > 0 else { return starvationLogTicks }
        return max(starvationLogTicks, Int(min(streamInterval / vsync, 1_000).rounded()) + 1)
    }

    /// PRESENT-LOOP BACKOFF threshold (in stream-frame intervals). When the head
    /// frame is HOPELESSLY late - its display-time lateness exceeds this many
    /// stream intervals AND a fresher frame is queued behind it - the tick stops
    /// trying to walk the normal due gate over a doomed stale head. Instead it
    /// drops the whole backlog to the single newest frame, presents THAT, and
    /// yields. This kills the busy-spin where the present path churns doomed
    /// late frames every tick (measured on a lossy wifi link: 80-96% CPU
    /// while fps_rendered→0). 3 intervals is well past the half-vsync due slack and the
    /// +1 adaptive trim, so a normally-paced or jitter-buffered stream NEVER trips
    /// it - only a genuinely-behind present path (the throttled-callback pile-up)
    /// reaches it, and it catches up to NOW in one tick rather than over many.
    static let presentBackoffLatenessIntervals = 3.0
}
