//
//  FramePacer+State.swift
//
//  The four LOCK-GUARDED STATE GROUPS the pacer's hot paths mutate - the
//  adaptive jitter-buffer/reconciler snapshot, the present-side liveness clocks
//  the self-heal watchdog gates on, the display-refresh telemetry accumulators,
//  and the tick-deficit / warm-handover / floor-violation machine's fields -
//  together with the why-comments that make each one legible. Split out of
//  FramePacer.swift (pure move, same file-split idiom as the rest of the
//  FramePacer extensions) to keep that file under the length limit; the stored
//  `adaptiveDepth` / `liveness` / `refreshTelemetry` / `tickDeficit` properties
//  themselves stay declared there with the rest of the core state, because a
//  Swift extension cannot hold stored properties.
//
//  EVERY field in every type here is guarded by FramePacer's single
//  `os_unfair_lock`. The logic that reads and writes them lives in the topic
//  files named in FramePacer.swift's code map.
//

import CoreMedia
import Dispatch
import QuartzCore

extension FramePacer {

    // MARK: - Adaptive jitter buffer + reconciler-target state
    //
    // THREAD ISOLATION: the reconciler's desired depth comes from
    // EnvSignalController's published `headroomLevel`. To honor never-hold-two-
    // locks, `refreshReconciledTargetLocked()` PULLS it into this plain field
    // OUTSIDE the pacer lock; the grow/decay math (under the pacer lock) reads only
    // the field, never the controller. Cached `generation` no-ops the refresh when
    // unchanged. Reconciler OFF: stays at `targetDepth`; the self-decide jitter path
    // drives the target.

    /// Adaptive target-depth + reconciler-snapshot state (guarded by `lock`).
    struct AdaptiveDepthState {
        /// The most recent SMOOTHED RFC-3550 reorder jitter (ms) measured by the RTP
        /// receive path (`RtpVideoQueue` → `TelemetryCounters.recvJitterMs`), refreshed
        /// each tick from the shared gauge. This is the signal that drives grow/decay
        /// - 0.09ms on a clean wired link, ~22ms on lossy wifi - read instead of the
        /// old wall-clock submit-spacing estimator (which was dominated by VT/FEC
        /// drain unevenness on a clean link and falsely pinned the target at the cap).
        var measuredJitterMs: Double = 0.0
        /// The current adaptive target depth. Rests at the baseline (1) on a clean
        /// link, grows by at most one frame per call when SUSTAINED measured jitter
        /// (above the dead-zone) demands more, and decays back to 1 during clean
        /// running. Read on the pacing queue (trim + due-gate floor); written on the
        /// pacing queue (decay/grow) under `lock`.
        var adaptiveTargetDepth: Int = FramePacer.targetDepth
        /// Last time (`CFAbsoluteTimeGetCurrent()`) the adaptive target shrank by a
        /// frame, so the decay is rate-limited to one frame per `targetShrinkInterval`.
        var lastTargetShrinkTime: CFTimeInterval = .nan
        /// Desired adaptive target depth pulled from the reconciler's last published
        /// decision (`targetDepth + headroomLevel`, clamped), refreshed off-lock.
        var reconciledTargetDepth: Int = FramePacer.targetDepth
        /// Generation of the published decision last folded into `reconciledTargetDepth`
        /// - the refresh re-maps only when the controller's generation advances.
        var reconciledDecisionGeneration: UInt64 = 0
    }

    // MARK: - Present-side liveness (self-heal watchdog + instrumentation)
    //
    // These are the clocks the present-path watchdog (StreamSession) gates on,
    // and the counters the NOTICE-level instrumentation reports. They are the
    // single thing that was missing before: the decode-output watchdog is
    // structurally blind to a stall DOWNSTREAM of VT (a stopped CADisplayLink
    // or a latched-false `due` gate), because `recordDecodedFrame()` keeps
    // advancing while the screen is frozen. Stamping a present-side host clock
    // here lets the watchdog see "frames are queued/decoding but nothing has
    // reached the renderer for N ms" and self-heal.

    /// Present-side liveness clocks + counters (guarded by `lock`).
    struct PresentLivenessState {
        /// `CFAbsoluteTimeGetCurrent()` at the top of the most recent `handleTick`.
        /// A 240Hz link ticks every ~4.17ms; if this stops advancing the link has
        /// died (a same-screen HDR/VRR/mode switch that posts no didChangeScreen).
        var lastTickHostTime: CFTimeInterval = .nan
        /// `CFAbsoluteTimeGetCurrent()` when a frame last actually reached the
        /// renderer (`willPresent` returned true). If this stops advancing while
        /// the queue is non-empty, the present path is wedged.
        var lastReleaseHostTime: CFTimeInterval = .nan
        /// Count of consecutive ticks where the queue was non-empty but nothing was
        /// released (the wedge signature: `due` latched false). Reset on any
        /// release. Used to log the diagnostic once it crosses a threshold.
        var starvedTickStreak: Int = 0
        /// Consecutive empty-queue ticks - the delivery-GAP signature (vs the non-empty
        /// wedge above). Drives `releaseDueFrame`'s post-gap leniency.
        var emptyTickStreak: Int = 0
        /// `CFAbsoluteTime` of the last gap-recovery edge; lenient window measures from here.
        var lastGapRecoveryTime: CFTimeInterval = 0
        /// Count of consecutive ticks the OVER-TARGET short-circuit had to force a
        /// release (a genuine backlog above the adaptive target the due gate would
        /// otherwise have latched not-due - the no-network present-stall fix). Reset
        /// the moment a normally-due release lands, so the streak measures ONLY the
        /// over-drain↔re-grow oscillation episodes, not steady state (where it stays
        /// 0). Drives a one-shot diagnostic signpost; never affects the present.
        var overTargetReleaseStreak: Int = 0
        /// Consecutive pacer-path releases the RENDERER refused (`willPresent` false -
        /// backpressure / not-ready), reset on any frame that reached it. The renderer-
        /// wedge signature: the due gate kept dequeuing while every frame died at
        /// `isReadyForMoreMediaData == false`, so `releaseCount` froze and the starvation
        /// failsafe never armed. Surfaced via LivenessSnapshot so the recovery ladder
        /// reaches for the renderer flush. Guarded by `lock`.
        var presentRejectStreak: Int = 0
        /// Latched so the starvation-diagnostic warning logs once per episode, not
        /// every tick. Cleared on the next successful release.
        var loggedStarvation = false
        /// Total ticks observed since start - exposed so instrumentation can derive
        /// a ticks/sec rate across a sampling window.
        var tickCount: UInt64 = 0
        /// Total releases observed since start - same, for a present/sec rate.
        var releaseCount: UInt64 = 0
    }

    // MARK: - Display-refresh telemetry (ProMotion ramp-down detector)
    //
    // The live displayLink vsync interval → derived refresh Hz, accumulated per tick
    // and exposed (min/avg/max) via LivenessSnapshot for the 1Hz exporter. Catches
    // ProMotion ramping the panel down (120→24Hz) on a static scene - a stretched
    // interval means the pacer paces slow / the buffer builds, then spikes when
    // motion resumes. Guarded by `lock`; accumulators roll in handleTick.

    /// Display-refresh telemetry accumulators (guarded by `lock`).
    struct RefreshTelemetryState {
        /// Sum of vsync intervals (seconds) observed since the last snapshot read,
        /// with the tick count, for a per-second average. Reset on read.
        var refreshIntervalSumSeconds: Double = 0
        var refreshIntervalSamples: UInt64 = 0
        /// Min/max vsync interval (seconds) since the last snapshot read. `.nan` =
        /// no sample yet this window; reset on read.
        var refreshIntervalMinSeconds: Double = .nan
        var refreshIntervalMaxSeconds: Double = .nan
        /// Last vsync interval seen (seconds), retained across snapshots so a
        /// refresh CHANGE (the ProMotion ramp edge) can be detected per tick. `.nan`
        /// until the first tick.
        var lastRefreshIntervalSeconds: Double = .nan
        /// Set true by a tick whose derived refresh Hz differs from the previous
        /// tick's by more than a small tolerance - surfaces a "refresh changed"
        /// marker in the snapshot. Reset on read. The signpost is emitted on the
        /// main run loop (in handleTick); this flag is the snapshot-side latch.
        var refreshChangedSinceRead: Bool = false
    }

    // MARK: - Tick-deficit degraded mode + warm handover (guarded by `lock`)
    //
    // Failsafe for the macOS frame-rate governor throttling CADisplayLink callbacks
    // BELOW the pinned preferredFrameRateRange floor (battery + ProMotion; the floor
    // is advisory and demonstrably not honored). The pacer releases only on ticks, so
    // a tick collapse froze the screen and machine-gunned queued frames into late
    // drops. The MEASURED realized tick rate (rolled below) keys a degraded mode that
    // releases due frames OFF-TICK at stream cadence until ticks return. Logic in
    // FramePacer+TickDeficit.swift; this is the stored state.

    /// Tick-deficit / warm-handover / floor-violation state (guarded by `lock`).
    struct TickDeficitState {
        /// Rolling ~250ms rate window over `tickCount`/`releaseCount` - the MEASURED
        /// (not inferred) realized tick/release rates everything below keys on.
        /// Rolled by `serviceTickDeficitLocked` from handleTick, livenessSnapshot
        /// (the 20Hz watchdog keeps it rolling even when ticks stop), and the
        /// deficit timer. `.nan` start = window not seeded yet.
        var rateWindowStartHostTime: CFTimeInterval = .nan
        var rateWindowStartTicks: UInt64 = 0
        var rateWindowStartReleases: UInt64 = 0
        /// Realized rates from the last completed window. `.nan` until the first
        /// window completes. Surfaced through LivenessSnapshot for the watchdog's
        /// tick-deficit trip and the exporter.
        var measuredTicksPerSecond: Double = .nan
        var measuredReleasesPerSecond: Double = .nan
        /// Expected tick rate from the last window: min(stream Hz, NOMINAL panel
        /// Hz). The nominal link duration keeps reading the rated panel cadence
        /// even while callbacks are throttled (verified: refresh_changed=0 through
        /// every collapse), so this is the honest "what ticks SHOULD arrive" bar -
        /// and it keeps a 120fps-stream-on-60Hz-panel setup (ticks legitimately
        /// half the stream rate) from ever reading as a deficit.
        var lastExpectedTickHz: Double = .nan
        /// When the measured tick rate first fell below the deficit enter ratio
        /// (hysteresis: enter <0.5×, clear ≥0.8× expected). `.nan` = no deficit.
        var tickDeficitSince: CFTimeInterval = .nan
        /// Until this host time, deficit / floor-violation VERDICTS are held (the
        /// rates keep being measured) - armed on the suppression-clear edge so the
        /// rebound link's delayed first post-refocus ticks can't mint a false
        /// engage (all 8 false engages + the 1 false FLOOR VIOLATION observed were
        /// this resume-edge artifact). `.nan` = no hold.
        var deficitVerdictHoldUntilHostTime: CFTimeInterval = .nan
        /// True while the off-tick release timer is the active release path.
        var deficitModeActive = false
        /// Engage bookkeeping for the disengage breadcrumb (duration + flow proof).
        var deficitEngagedAt: CFTimeInterval = .nan
        var deficitEngageReleaseCount: UInt64 = 0
        var deficitRepaints: UInt64 = 0
        /// Last governor-repaint instant, so repaints are rate-limited to stream
        /// cadence. `.nan` = none this episode.
        var lastRepaintHostTime: CFTimeInterval = .nan
        /// The most recent sample buffer that reached the renderer via the pacing
        /// queue - the repaint source during a deficit (re-committing the current
        /// frame so the governor never classifies the layer as static). Holds the
        /// SAME buffer the layer is already displaying, so no extra surface is
        /// retained from VT's pool. Cleared on stop().
        var lastPresentedSampleBuffer: CMSampleBuffer?
        /// WARM HANDOVER: true while a re-enabled pacer keeps presenting DIRECT
        /// (submit bypasses the queue) until the rebuilt link proves a healthy
        /// realized tick rate - the cold cutover onto an un-primed link queued
        /// arriving frames to the depth cap and re-froze 350ms after re-enable
        /// (measured on a battery wifi link). Armed by
        /// `armWarmHandover()` before start().
        var warmingUp = false
        /// Consecutive healthy rate windows seen while warming up.
        var warmHealthyWindowStreak = 0
        /// Floor-violation breadcrumb state (NOTICE when realized ticks violate the
        /// pinned preferredFrameRateRange floor >1s - direct governor evidence).
        var floorViolationSince: CFTimeInterval = .nan
        var floorViolationLogged = false
        /// FLOOR-VIOLATION ASSIST: true while the off-tick timer is armed to
        /// fill the governor's 0.5-0.9x dead band (ticks throttled below the
        /// pinned floor but above the hard-deficit ratio - the field's
        /// most-frequent judder signature, logged for weeks with no response).
        var floorAssistActive = false
        var floorAssistEngagedAt: CFTimeInterval = .nan
        var floorAssistEngageReleaseCount: UInt64 = 0
        /// Continuous healthy time (ticks back at/above the assist exit ratio)
        /// before the assist stands down - rides the observed 1-3s throttle
        /// flap through as ONE episode instead of cycling the timer with it.
        var floorAssistHealthySince: CFTimeInterval = .nan
        /// When realized ticks first ran below the content-overrate engage
        /// ratio (vs expectedHz). `.nan` = not short. Drives the assist engage
        /// independently of the floor-violation breadcrumb latch.
        var assistShortSince: CFTimeInterval = .nan
        /// Lock-guarded mirror of the main-actor `appliedFloorHz`, written wherever
        /// the range is (re)applied, so the off-main rate-window roll can compare
        /// realized ticks against the pinned floor without an actor hop.
        var pinnedFloorHz: Double = .nan
        /// The off-tick release timer. Created/cancelled ONLY on `pacingQueue`
        /// (see `reconcileDeficitTimer`), so it needs no lock of its own.
        var deficitTimer: DispatchSourceTimer?
    }
}
