//
//  FramePacer.swift
//
//  A display-clock frame pacer that sits between the VideoToolbox decode
//  callback and the AVSampleBufferDisplayLayer's renderer. It exists to kill
//  the micro-stutter that comes from enqueueing each decoded frame the instant
//  VT produces it: network-arrival jitter on the host's capture clock then maps
//  1:1 onto screen time, so frames that arrived 2ms early/late present 2ms
//  early/late and the motion judders even on a perfectly-paced 60/120/240 Hz
//  panel.
//
//  Design - a faithful port of moonlight-qt's `pacer.cpp` two-queue model,
//  adapted to AVSampleBufferDisplayLayer + CADisplayLink instead of FFmpeg
//  AVFrames + CVDisplayLink:
//
//    * VT decode callback → `submit(_:hostPTS:)` pushes a ready CMSampleBuffer
//      into a bounded, hostPTS-ordered jitter/reorder FIFO (the "pacing
//      queue"). This is the analogue of `Pacer::submitFrame` →
//      `m_PacingQueue`.
//
//    * A CADisplayLink bound to the STREAM WINDOW's screen drives a per-vsync
//      tick. On each tick we decide whether a frame is DUE - by the display
//      link's own cadence, never a hardcoded refresh - and if so release
//      exactly one frame to `renderer.enqueue(...)`. This is the analogue of
//      `Pacer::handleVsync` releasing one frame from the pacing queue per
//      vsync. The release runs on a DEDICATED serial queue, never the main
//      actor, so the present path can't be blocked by SwiftUI / AppKit work.
//
//  Refresh-agnostic + PTS-driven
//  -----------------------------
//  We read the true cadence from the link (`targetTimestamp - timestamp`),
//  which is correct at 60 Hz, 120 Hz ProMotion-variable, and 240 Hz without a
//  hardcoded constant. We also learn the STREAM's inter-frame interval from the
//  spacing of host PTSes. The release rule is then refresh-vs-fps aware:
//
//    * stream-fps == refresh (240/240, 60/60) → release ~one frame per tick.
//    * stream-fps  < refresh (120 on 240, 60 on 120) → the pacing queue fills
//      slower than vsyncs arrive, so ticks where no frame is due naturally
//      release nothing and we present the same frame again (the layer holds
//      the last frame), i.e. "every other tick" falls out for free.
//    * stream-fps  > refresh (rare; 240 on 120) → multiple frames accumulate
//      between vsyncs; the adaptive trim drops the stale excess so only the
//      freshest DUE frame presents, bounding wall-clock latency.
//
//  Adaptive depth - passthrough on a clean link, absorb only MEASURED jitter
//  --------------------------------------------------------------------------
//  The baseline target depth RESTS AT 1 frame (o2p median ~10.8ms at fps==refresh;
//  moonlight's fixed 3-frame buffer is ~25ms) and GROWS only for genuine MEASURED
//  jitter - the RtpVideoQueue's ~1s-smoothed RFC-3550 reorder jitter (0.09ms wired
//  / ~22ms wifi) through a dead-zone, never wall-clock submit spacing. It DECAYS
//  back to 1 over a ~250ms clean window; the grow-without-a-hitch hold is OFF on a
//  clean link (target == 1). Every release also TRIMS the FIFO drop-to-newest
//  toward `effectiveTarget + 1`. Full schedule + tuning in FramePacer+Constants.swift
//  / FramePacer+AdaptiveDepth.swift.
//
//  Code map (this type is split across same-module extension files)
//  ----------------------------------------------------------------
//    * FramePacer.swift            - the class decl, stored state, init, and
//                                    the lifecycle / link plumbing.
//    * FramePacer+Constants.swift  - the static tuning constants.
//    * FramePacer+Submit.swift     - the decode-queue submit path.
//    * FramePacer+Tick.swift       - the CADisplayLink vsync tick.
//    * FramePacer+DueGate.swift    - the trim → backoff → due-gate → release core
//                                    (+ the BackoffBeat/DueGateResult types).
//    * FramePacer+Recovery.swift   - the self-heal watchdog actions + snapshots
//                                    (+ the LivenessSnapshot/RefreshWindowSnapshot types).
//    * FramePacer+AdaptiveDepth.swift - measured-jitter input + depth math.
//    * FramePacer+FrameRateRange.swift - the present-callback throttle floor.
//    * FramePacer+TickDeficit.swift - the tick-deficit degraded mode (off-tick
//                                    release + governor repaint), the warm
//                                    re-enable handover, and the floor-violation
//                                    breadcrumbs.
//
//  Threading
//  ---------
//  * `submit` runs on the VT decode queue (any thread). It only touches the
//    lock-guarded FIFO + counters.
//  * The CADisplayLink `@objc` tick fires on the main run loop. It does the
//    minimum on main (read targetTimestamp/duration, snapshot isStreaming) and
//    dispatches the dequeue+enqueue to `pacingQueue`.
//  * `start`/`stop`/`screenDidChange` run on the main actor (lifecycle).
//  All shared mutable state is guarded by a single `os_unfair_lock`, the same
//  discipline StatsCollector uses. The lock is held only for a handful of
//  field updates per submit/tick - well under a microsecond.
//
//  Pacing model ported from moonlight-qt's pacer.cpp (GPLv3); see CREDITS.md.
//

import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import os

/// Drives presentation of decoded frames against the display's true vsync
/// cadence. One per streaming session; owned by `VideoDecoder`.
///
/// `@unchecked Sendable` over an internal `os_unfair_lock` - the decode queue
/// (`submit`), the main run loop (the link tick), and the main actor
/// (lifecycle) all touch it, mirroring `StatsCollector`'s contract.
final class FramePacer: @unchecked Sendable {

    // Module-internal (not private) so the FIX #1 floor re-apply in
    // FramePacer+FrameRateRange.swift can log through the same category.
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Pacer")

    // The static tuning constants (FIFO caps, the adaptive jitter-buffer depth
    // schedule, the starvation failsafe thresholds, the present-loop backoff
    // lateness) live in FramePacer+Constants.swift to keep this file under the
    // length limit.

    // MARK: - Frame entry

    /// One queued frame: the ready-to-enqueue sample buffer plus the host PTS
    /// we pace against. PTS is the host capture clock (90 kHz recovered by VT),
    /// so deltas between consecutive PTSes give the stream's frame interval
    /// independent of when the bytes actually arrived.
    struct Entry {
        let sampleBuffer: CMSampleBuffer
        let hostPTSSeconds: Double
    }

    // MARK: - Shared state (guarded by `lock`)

    var lock = os_unfair_lock_s()

    /// The pacing queue: hostPTS-ordered FIFO of decoded frames awaiting a
    /// vsync. Bounded at `maxQueuedFrames`. Insertion keeps it sorted by
    /// hostPTS so an out-of-order decode (VT can momentarily reorder under
    /// load even with ThreadCount=1 on some codecs) presents in display order.
    var queue: [Entry] = []

    /// Learned stream inter-frame interval in seconds, derived from the median
    /// of recent hostPTS deltas. Seeded from the configured stream fps so the
    /// very first ticks have a sane cadence before PTS history accrues.
    var streamFrameIntervalSeconds: Double
    /// The FIXED configured-fps interval (set once at init, never refined). The
    /// present-callback FLOOR pins to THIS, not to the per-frame-refined
    /// `streamFrameIntervalSeconds` (which jitters with measured PTS cadence) - so
    /// the floor never re-pins on cadence wobble, which makes the display
    /// renegotiate its refresh and drop a frame (the TestUFO frameskip gap). The
    /// due gate still paces from the refined interval; only the floor is fixed.
    let configuredFrameIntervalSeconds: Double
    /// Last hostPTS we saw at submit, to compute the next delta.
    var lastSubmittedPTSSeconds: Double = .nan
    /// Recent hostPTS deltas (seconds) for the median estimate. Bounded.
    var ptsDeltas: [Double] = []

    // MARK: - Adaptive jitter buffer state (Issue 2a)

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

    // MARK: - Reconciler desired-target snapshot (INCREMENT 1)
    //
    // THREAD ISOLATION: the reconciler's desired depth comes from
    // EnvSignalController's published `headroomLevel`. To honor never-hold-two-
    // locks, `refreshReconciledTargetLocked()` PULLS it into this plain field
    // OUTSIDE the pacer lock; the grow/decay math (under the pacer lock) reads only
    // the field, never the controller. Cached `generation` no-ops the refresh when
    // unchanged. Reconciler OFF: stays at `targetDepth`; the self-decide jitter path
    // drives the target.

    /// Desired adaptive target depth pulled from the reconciler's last published
    /// decision (`targetDepth + headroomLevel`, clamped), refreshed off-lock.
    var reconciledTargetDepth: Int = FramePacer.targetDepth
    /// Generation of the published decision last folded into `reconciledTargetDepth`
    /// - the refresh re-maps only when the controller's generation advances.
    var reconciledDecisionGeneration: UInt64 = 0

    /// Display-clock time (`CADisplayLink.targetTimestamp`) of the last
    /// present - the cadence base we gate the next "is a frame DUE" decision
    /// against. `.nan` until the first present so the first frame goes out
    /// immediately.
    var lastPresentMediaTime: CFTimeInterval = .nan

    /// True between `start()` and `stop()`. The tick and the dispatched
    /// release both bail when false so we never enqueue to a released layer.
    var running = false

    /// True while presentation is intentionally suppressed (window hidden → the
    /// display link stops ticking by design): `submit()` then keeps ONLY the
    /// newest frame, counting displaced frames as SUPPRESSED - not late - drops.
    /// Set/cleared on the suppression edges via `setPresentSuppressed` (in
    /// FramePacer+Submit.swift, with the drop logic it gates); NOT reset by
    /// `stop()` - it mirrors `VideoDecoder`'s state, which outlives a link rebuild.
    var presentSuppressed = false

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

    // MARK: - Display-refresh telemetry (ProMotion ramp-down detector)
    //
    // The live displayLink vsync interval → derived refresh Hz, accumulated per tick
    // and exposed (min/avg/max) via LivenessSnapshot for the 1Hz exporter. Catches
    // ProMotion ramping the panel down (120→24Hz) on a static scene - a stretched
    // interval means the pacer paces slow / the buffer builds, then spikes when
    // motion resumes. Guarded by `lock`; accumulators roll in handleTick.

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

    // MARK: - Tick-deficit degraded mode + warm handover (guarded by `lock`)
    //
    // Failsafe for the macOS frame-rate governor throttling CADisplayLink callbacks
    // BELOW the pinned preferredFrameRateRange floor (battery + ProMotion; the floor
    // is advisory and demonstrably not honored). The pacer releases only on ticks, so
    // a tick collapse froze the screen and machine-gunned queued frames into late
    // drops. The MEASURED realized tick rate (rolled below) keys a degraded mode that
    // releases due frames OFF-TICK at stream cadence until ticks return. Logic in
    // FramePacer+TickDeficit.swift; this is the stored state.

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
    /// Lock-guarded mirror of the main-actor `appliedFloorHz`, written wherever
    /// the range is (re)applied, so the off-main rate-window roll can compare
    /// realized ticks against the pinned floor without an actor hop.
    var pinnedFloorHz: Double = .nan
    /// The off-tick release timer. Created/cancelled ONLY on `pacingQueue`
    /// (see `reconcileDeficitTimer`), so it needs no lock of its own.
    var deficitTimer: DispatchSourceTimer?

    // MARK: - Collaborators

    /// Stats sink - present cadence, late/on-time counts, depth samples, and
    /// the presentation-late drop cause. Shared with `VideoDecoder` (the same
    /// `@unchecked Sendable` collector the decode path records into).
    let stats: StatsCollector

    /// Called on `pacingQueue` (or the decode queue on submit overflow) just
    /// before each release so the owner (`VideoDecoder`) can run its
    /// renderer-status / backpressure-IDR logic against the frame we're about
    /// to present. Returns true to proceed with the enqueue, false to skip it
    /// (e.g. renderer not ready). Keeping this a closure lets `VideoDecoder`
    /// own the IDR + flush policy without the pacer reaching into decoder state.
    /// `@Sendable` because the pacer (a `Sendable` type) invokes it from the
    /// decode queue (fallback) and the pacing queue.
    var willPresent: (@Sendable (_ sampleBuffer: CMSampleBuffer) -> Bool)?

    /// Governor-repaint hook (tick-deficit degraded mode): re-commit the given
    /// ALREADY-PRESENTED sample buffer to the renderer WITHOUT counting it as a
    /// rendered frame. Deliberately separate from `willPresent`: a repaint must
    /// not inflate fps_rendered / o2p / cadence telemetry (renders==received is
    /// the degraded mode's verification contract), so it cannot route through
    /// `presentFrame`. Set once at `startPacing` before frames flow, like
    /// `willPresent`. Invoked on `pacingQueue` only.
    var onDeficitRepaint: (@Sendable (_ sampleBuffer: CMSampleBuffer) -> Void)?

    // No `onSustainedLag`/IDR-escalation hook: a presentation-timing drop of an
    // already-decoded CMSampleBuffer leaves the reference chain intact, so a keyframe
    // can't fix pacing (and the bitrate-capped 4K240 IDR arrives soft then refines -
    // visible blur/refocus). The pacer trims-to-newest and counts every drop as
    // presentation-late (load-bearing telemetry); IDR/RFI is for genuine
    // decode/reference breaks only (depacketizer RFI on real loss; VT errors).

    // MARK: - Display link

    /// The CADisplayLink bound to the stream window's screen. macOS 14+
    /// `NSView.displayLink(target:selector:)`. Stored so we can invalidate on
    /// teardown / rebind on a screen change. Touched on the main actor only.
    /// Module-internal (not private) so the FIX #1 floor re-apply in
    /// FramePacer+FrameRateRange.swift can re-pin `preferredFrameRateRange`.
    @MainActor var displayLink: CADisplayLink?
    /// The view we bound the link to, kept so a screen change can rebind.
    @MainActor weak var boundView: NSView?
    /// Signature of the screen the link was last bound to (display ID |
    /// panel max | backing scale), seeded by `installLink`. `screenDidChange`
    /// rebinds ONLY when this changes: macOS posts screen-parameter
    /// notifications ~1/s on a ProMotion panel (VRR housekeeping), and the
    /// unconditional rebind reset the cadence base 785 times in a ~12-minute
    /// run - a standing micro-judder source invisible until the (re)bind
    /// breadcrumbs landed. A no-op notification must stay a no-op.
    @MainActor var boundScreenSignature: String?

    /// The `@objc` tick target. CADisplayLink retains its target; we keep the
    /// shim separate from `self` so the link's retain doesn't form a cycle with
    /// VideoDecoder and so the selector signature stays clean.
    @MainActor private var tickProxy: DisplayLinkProxy?

    /// The Hz (floor) we last pinned `preferredFrameRateRange` to (FIX #1).
    /// Pinned to the FIXED configured fps at install and held there; the
    /// main-actor re-apply only touches it again if the panel max changes under
    /// us (deadband `frameRateReapplyHysteresisHz`). `.nan` until first applied.
    /// Module-internal (not private) so the re-apply helper in
    /// FramePacer+FrameRateRange.swift can read/update it.
    @MainActor var appliedFloorHz: Double = .nan

    // `frameRateReapplyHysteresisHz` lives in FramePacer+FrameRateRange.swift
    // with the re-apply helper that uses it.

    /// Dedicated serial queue for the present path. `.userInteractive` because
    /// a missed release is a dropped frame the user sees. NEVER the main actor.
    let pacingQueue = DispatchQueue(
        label: "io.ugfugl.Glimmer.video.pacer", qos: .userInteractive)

    // MARK: - Init

    init(stats: StatsCollector, configuredFps: Int32) {
        self.stats = stats
        // Seed the cadence from the configured fps; refined from PTS deltas
        // once frames flow. Guard against a zero/garbage config.
        let fps = configuredFps > 0 ? Double(configuredFps) : 60.0
        let interval = FramePacer.clampFrameInterval(1.0 / fps)
        self.streamFrameIntervalSeconds = interval
        self.configuredFrameIntervalSeconds = interval
    }

    /// Clamp a frame-interval estimate to a sane [1ms, 1s] range. A poisoned
    /// PTS window (NaN, 0, or an absurd gap) must never feed the `due` gate -
    /// a NaN/0 interval would make `due` evaluate against garbage and could
    /// wedge the present path, exactly the freeze this pass closes.
    static func clampFrameInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 1.0 / 60.0 }
        return min(max(seconds, 1.0 / 1000.0), 1.0)
    }

    // MARK: - Lifecycle (main actor)

    /// Start pacing: bind a CADisplayLink to `view`'s screen and begin ticking.
    /// Call once the stream view has a window + screen (from `StreamWindow`'s
    /// show path). The actual `renderer.enqueue` is delegated to the owner's
    /// `willPresent` closure, so the pacer needs no renderer reference of its
    /// own. Idempotent - a second start with the same view rebinds the link.
    @MainActor
    func start(drivingView view: NSView) {
        os_unfair_lock_lock(&lock)
        running = true
        // Seed the present-side liveness clocks to "now" so the watchdog gives
        // the pacer a grace period to produce its first frame rather than
        // tripping on the .nan startup state.
        let now = CFAbsoluteTimeGetCurrent()
        lastTickHostTime = now
        lastReleaseHostTime = now
        starvedTickStreak = 0
        overTargetReleaseStreak = 0
        presentRejectStreak = 0
        loggedStarvation = false
        // Seed the realized-rate window from "now" too, so the first deficit /
        // floor-violation verdicts measure from start - never from a stale or
        // .nan origin that would mint a giant fake first window.
        rateWindowStartHostTime = now
        rateWindowStartTicks = tickCount
        rateWindowStartReleases = releaseCount
        // D3 (warm re-enable cadence seed): a re-enabled pacer is freshly built
        // from the CONFIGURED fps, but its predecessor had already refined the
        // true content cadence - adopt it to warm-start the DUE GATE's pacing
        // cadence. The present-callback floor is unaffected: it always pins the
        // FIXED configured rate (configuredFrameIntervalSeconds), never this.
        adoptStashedRefinedCadenceLocked()
        os_unfair_lock_unlock(&lock)

        // Invalidate any prior link (idempotent re-start) before binding fresh.
        displayLink?.invalidate()
        displayLink = nil
        boundView = view
        installLink(on: view)
        log.info("FramePacer started - streamInterval=\(self.streamFrameIntervalSeconds * 1000, privacy: .public)ms")
    }

    // The cadence-base reset/re-anchor helpers (`resetCadenceBaseLocked`,
    // `anchorCadenceBaseOnGridLocked`) live in FramePacer+DueGate.swift with the
    // due-gate that consumes the base they manage - moved there with the
    // tick-deficit state additions to keep THIS file under the length limit.

    /// Tear the pacer down: stop + invalidate the link and drain the queue.
    /// Safe to call more than once and from teardown races - after this the
    /// tick and any in-flight dispatched release no-op.
    @MainActor
    func stop() {
        // Stash the refined content cadence FIRST (helper takes the lock) so a
        // warm re-enable after a give-up can seed its fresh pacer's floor from
        // the truth (~174Hz) instead of the configured fps (the D3 240.0Hz
        // warm-re-enable seed bug) - see adoptStashedRefinedCadenceLocked.
        stashRefinedCadenceForWarmReenable()
        os_unfair_lock_lock(&lock)
        running = false
        queue.removeAll(keepingCapacity: false)
        // Reset liveness so a future restart starts clean (the watchdog reads
        // these; a stale "never ticked" must not survive a restart).
        lastTickHostTime = .nan
        lastReleaseHostTime = .nan
        starvedTickStreak = 0
        overTargetReleaseStreak = 0
        presentRejectStreak = 0
        loggedStarvation = false
        // Reset the adaptive jitter buffer so a restart begins at the low-latency
        // baseline (depth 1) rather than inheriting a stale deepened target.
        adaptiveTargetDepth = FramePacer.targetDepth
        measuredJitterMs = 0.0
        lastTargetShrinkTime = .nan
        // Reset the reconciler snapshot so a restart begins at the REST target
        // (depth 1, generation 0) and re-pulls the live decision on its first tick.
        reconciledTargetDepth = FramePacer.targetDepth
        reconciledDecisionGeneration = 0
        // Reset display-refresh telemetry so a restart's first window is clean.
        refreshIntervalSumSeconds = 0
        refreshIntervalSamples = 0
        refreshIntervalMinSeconds = .nan
        refreshIntervalMaxSeconds = .nan
        lastRefreshIntervalSeconds = .nan
        refreshChangedSinceRead = false
        // Reset the tick-deficit / warm-handover state and release the held
        // repaint frame so a torn-down pacer pins nothing and a restart begins
        // with fresh measurements (never an inherited deficit verdict). The
        // field-by-field reset lives with the state machine it clears
        // (FramePacer+TickDeficit.swift).
        resetTickDeficitStateLocked()
        os_unfair_lock_unlock(&lock)

        // Cancel the off-tick release timer (if a deficit episode was live).
        // Timer create/cancel is confined to pacingQueue; `deficitModeActive`
        // is already false so a fire racing this reconcile no-ops.
        pacingQueue.async { [weak self] in self?.reconcileDeficitTimer() }

        displayLink?.invalidate()
        displayLink = nil
        tickProxy = nil
        boundView = nil
        log.info("FramePacer stopped")
        // Mirror to the Diag/LogStore file sink: os_log-only pacer breadcrumbs
        // were structurally invisible postmortem (the glimmer-*.log sink records
        // only Diag entries - 0 FramePacer lines across whole sessions).
        Diag.info("FramePacer stopped", "Stream.Pacer")
    }

    // The link-rebind recovery actions (`screenDidChange`, `rebuildLink`) and
    // `installLink` itself (the single bind path all of start / screen-change /
    // rebuild route through) live in FramePacer+Recovery.swift - installLink
    // moved there with the tick-deficit state additions to keep THIS file under
    // the length limit. `tickProxy` setter access for it is below.

    /// Stash the @objc tick shim the live link retains. Main-actor setter for
    /// `installLink` (FramePacer+Recovery.swift) - the stored property itself is
    /// private so nothing else can swap the proxy out from under a live link.
    @MainActor
    func setTickProxy(_ proxy: DisplayLinkProxy?) {
        tickProxy = proxy
    }

    // Per the code map in the file header: the throttle floor (FIX #1) lives in
    // FramePacer+FrameRateRange.swift; the decode-queue submit path in
    // FramePacer+Submit.swift; the vsync tick in FramePacer+Tick.swift; the
    // trim → backoff → due-gate → release core (+ `BackoffBeat` /
    // `DueGateResult`) in FramePacer+DueGate.swift; the watchdog/self-heal
    // recovery actions + snapshots (`LivenessSnapshot` /
    // `RefreshWindowSnapshot`) in FramePacer+Recovery.swift - each split out
    // to keep THIS file under the length limit.

    // MARK: - Helpers

    /// Backing store for the inter-present cadence metric. The realized
    /// inter-present interval is differenced against this previous present time in
    /// `lastPresentInterPresentDelta` (FramePacer+AdaptiveDepth.swift); the field
    /// stays here with the core state because `resetCadenceBaseLocked` /
    /// `anchorCadenceBaseOnGridLocked` clear it alongside `lastPresentMediaTime`.
    var prevPresentMediaTimeForMetric: CFTimeInterval = .nan

    // The pure metric helpers (`lastPresentInterPresentDelta`, `median`), the
    // measured-jitter input (`noteMeasuredJitter`), and the adaptive target depth
    // math (`justifiedDepthLocked`, `bumpTargetForJitterLocked`,
    // `decayTargetLocked`) live in FramePacer+AdaptiveDepth.swift.

    // The `DisplayLinkProxy` @objc tick shim lives in FramePacer+Tick.swift with
    // the tick handler it forwards to.
}
