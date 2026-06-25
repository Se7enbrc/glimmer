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

    /// Baseline (clean-link) REST depth. On a clean link the pacer rests here -
    /// one frame of slack, essentially direct enqueue (output_to_present
    /// ~0.1-0.3ms, the direct path's measured ideal): at fps<refresh the queue
    /// already sits at ~1 because frames arrive slower than vsyncs, so depth-1 is
    /// the NATURAL rest state and adds zero latency (the layer re-shows the last
    /// frame on idle ticks). This is the FLOOR the adaptive target decays back to
    /// once the link is clean. With the rest depth == target, the grow-hold gate
    /// (which keys on `adaptiveTargetDepth > targetDepth`) self-disables on a
    /// clean link, so the startup present-stall wedge cannot form.
    static let targetDepth = 1

    /// Upper bound on the adaptive target depth under SUSTAINED MEASURED jitter.
    /// 5 frames is the jitter ceiling for the genuine lossy-link (wifi ~22ms)
    /// case - deep enough to absorb a real reorder-jitter envelope. Because the
    /// floor is now 1 and grow keys off the smoothed RFC-3550 recv-jitter through
    /// a 3ms dead-zone, this cap is ONLY ever reached under real sustained
    /// measured jitter; a clean link never leaves depth 1. Kept under
    /// `maxQueuedFrames` so an overflow slot remains at the cap.
    static let maxTargetDepth = 5

    /// Milliseconds of SUSTAINED measured reorder jitter (above the dead-zone)
    /// that buys one extra frame of buffering:
    /// extra = ceil((jitterMs - jitterDeadZoneMs) / jitterMsPerExtraFrame).
    static let jitterMsPerExtraFrame = 8.0

    /// Dead-zone (ms) below which measured reorder jitter buys NO extra depth, so
    /// the buffer rests at 1. Set well above the wired link's 0.31ms p95 (so a
    /// pristine link maps to depth 1) and well below the wifi ~22ms case (so a
    /// genuinely lossy link still grows). 0.09ms wired → extra 0 → depth 1;
    /// sustained 22ms → extra ceil(19/8)=3 → grows toward the cap.
    static let jitterDeadZoneMs = 3.0

    /// How quickly the adaptive target shrinks back toward the baseline (depth 1)
    /// once the link is clean: at most one frame per this many seconds of clean
    /// running. 250ms: because the measured-jitter signal is the ~1s-smoothed
    /// RFC-3550 metric, the depth returns to 1 within ~1s of the link clearing.
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

    /// DUE-GATE slack (seconds): a barely-not-due head may still present this vsync
    /// rather than wait a whole one (the fps≈refresh 1.5× judder). FIXED ms, not half a
    /// vsync - that scaled with refresh and penalized 120Hz vs 240Hz; sub-frame arrival
    /// jitter (all this covers) is refresh-independent. Adaptive depth owns real jitter.
    static let dueGateSlackSeconds = 0.002

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
