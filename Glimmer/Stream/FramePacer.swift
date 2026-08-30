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
//    * FramePacer+State.swift      - the four lock-guarded state GROUP types
//                                    (adaptive depth / liveness / refresh
//                                    telemetry / tick deficit) the stored
//                                    properties here are declared with.
//    * FramePacer+Constants.swift  - the static tuning constants.
//    * FramePacer+Submit.swift     - the decode-queue submit path.
//    * FramePacer+Tick.swift       - the CADisplayLink vsync tick.
//    * FramePacer+DueGate.swift    - the trim → backoff → due-gate → release core
//                                    (+ the BackoffBeat/DueGateResult types).
//    * FramePacer+Recovery.swift   - the self-heal watchdog actions + snapshots
//                                    (+ the LivenessSnapshot/RefreshWindowSnapshot types).
//    * FramePacer+AdaptiveDepth.swift - measured-jitter input + depth math.
//    * FramePacer+FrameRateRange.swift - the present-callback throttle floor.
//    * FramePacer+TickDeficit.swift - the tick-deficit degraded mode's measured-
//                                    rate state machine, the warm re-enable
//                                    handover, and the floor-violation
//                                    breadcrumbs.
//    * FramePacer+TickDeficitEvents.swift - the `TickDeficitEvent` vocabulary
//                                    that state machine returns + its off-lock
//                                    breadcrumb logging.
//    * FramePacer+DeficitTimer.swift - the off-tick release timer (reconcile,
//                                    synthetic-vsync beat, governor repaint).
//
//  Threading
//  ---------
//  * `submit` runs on the VT decode queue (any thread). It only touches the
//    lock-guarded FIFO + counters.
//  * The CADisplayLink `@objc` tick fires on a private high-QoS run loop (the
//    `pacerTickOffMain` default; `.main` in fallback) so a busy main thread
//    can't starve it. It does the minimum there (read targetTimestamp/duration,
//    roll the lock-guarded telemetry), hops the lone main-affine touch (the
//    floor re-apply) to the main actor, and dispatches the dequeue+enqueue to
//    `pacingQueue`. The link bind/unbind themselves stay on the main actor.
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

    // Module-internal (not private) so the floor re-apply in
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

    /// DEBUG-only lock-discipline assertions (compiled out in release). The never-nest
    /// invariant is load-bearing: `refreshReconciledTarget` takes EnvSignalController's
    /// lock so it MUST run OFF this one. Traps at the boundary on the first violation
    /// rather than surfacing as a rare deadlock far away.
    @inline(__always) func assertLockHeld() {
        #if DEBUG
        os_unfair_lock_assert_owner(&lock)
        #endif
    }
    @inline(__always) func assertLockNotHeld() {
        #if DEBUG
        os_unfair_lock_assert_not_owner(&lock)
        #endif
    }

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

    /// Adaptive target-depth + reconciler-snapshot state (guarded by `lock`).
    /// The `AdaptiveDepthState` type - and the THREAD ISOLATION contract behind
    /// its reconciler fields (never hold the pacer lock and EnvSignalController's
    /// at once) - lives in FramePacer+State.swift with the other lock-guarded
    /// state groups; the grow/decay math is in FramePacer+AdaptiveDepth.swift.
    var adaptiveDepth = AdaptiveDepthState()

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

    /// Present-side liveness clocks + counters (guarded by `lock`) - the clocks
    /// the present-path watchdog (StreamSession) gates on and the counters the
    /// NOTICE-level instrumentation reports, so a stall DOWNSTREAM of VT (a
    /// stopped CADisplayLink or a latched-false `due` gate) is visible at all.
    /// The `PresentLivenessState` type + that full rationale live in
    /// FramePacer+State.swift with the other lock-guarded state groups.
    var liveness = PresentLivenessState()

    // MARK: - Display-refresh telemetry (ProMotion ramp-down detector)

    /// Display-refresh telemetry accumulators (guarded by `lock`) - the live
    /// vsync interval → derived refresh Hz, rolled in handleTick and exposed
    /// (min/avg/max) via LivenessSnapshot so a ProMotion ramp-down on a static
    /// scene is visible. The `RefreshTelemetryState` type is in
    /// FramePacer+State.swift with the other lock-guarded state groups.
    var refreshTelemetry = RefreshTelemetryState()

    // MARK: - Tick-deficit degraded mode + warm handover (guarded by `lock`)

    /// Tick-deficit / warm-handover / floor-violation state (guarded by `lock`)
    /// - the failsafe for the macOS frame-rate governor throttling
    /// CADisplayLink callbacks below the pinned preferredFrameRateRange floor.
    /// The `TickDeficitState` type is in FramePacer+State.swift with the other
    /// lock-guarded state groups; the logic in FramePacer+TickDeficit.swift.
    var tickDeficit = TickDeficitState()

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
    /// Module-internal (not private) so the floor re-apply in
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

    /// The Hz (floor) we last pinned `preferredFrameRateRange` to.
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

    // MARK: - Present tick run loop (off-main, default)

    /// The private run loop the tick fires on when `tickOffMain` is set. Created
    /// lazily in `installLink` (off-main path) and stopped on teardown/`deinit`
    /// so no thread leaks across a reconnect / screen-change rebuild. Assigned
    /// only from the main actor (install/teardown); read from `deinit`. NOT
    /// main-actor isolated so `deinit` can stop it without an actor hop - safe
    /// because deinit runs only when no other reference (so no thread) survives,
    /// and `PacerTickThread` is itself `Sendable` with idempotent, locked teardown.
    /// Nil while the main-runloop fallback is active. The `tickOffMain` flag +
    /// key live in FramePacer+TickThread.swift with the thread they gate.
    var pacerTickThread: PacerTickThread?

    deinit {
        // The link retains its proxy, not us, so deinit means the session is
        // fully torn down; stop the thread so it can never outlive us. stop()
        // is idempotent (stop() already ran on the normal teardown path).
        pacerTickThread?.stop()
    }

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
        liveness.lastTickHostTime = now
        liveness.lastReleaseHostTime = now
        liveness.starvedTickStreak = 0
        liveness.overTargetReleaseStreak = 0
        liveness.presentRejectStreak = 0
        liveness.loggedStarvation = false
        // Seed the realized-rate window from "now" too, so the first deficit /
        // floor-violation verdicts measure from start - never from a stale or
        // .nan origin that would mint a giant fake first window.
        tickDeficit.rateWindowStartHostTime = now
        tickDeficit.rateWindowStartTicks = liveness.tickCount
        tickDeficit.rateWindowStartReleases = liveness.releaseCount
        // Warm re-enable cadence seed: a re-enabled pacer is freshly built
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
        // the truth (~174Hz) instead of the configured fps (the 240.0Hz
        // warm-re-enable seed bug) - see adoptStashedRefinedCadenceLocked.
        stashRefinedCadenceForWarmReenable()
        os_unfair_lock_lock(&lock)
        running = false
        queue.removeAll(keepingCapacity: false)
        // Reset liveness so a future restart starts clean (the watchdog reads
        // these; a stale "never ticked" must not survive a restart).
        liveness.lastTickHostTime = .nan
        liveness.lastReleaseHostTime = .nan
        liveness.starvedTickStreak = 0
        liveness.overTargetReleaseStreak = 0
        liveness.presentRejectStreak = 0
        liveness.loggedStarvation = false
        // Reset the adaptive jitter buffer so a restart begins at the low-latency
        // baseline (depth 1) rather than inheriting a stale deepened target.
        adaptiveDepth.adaptiveTargetDepth = FramePacer.targetDepth
        adaptiveDepth.measuredJitterMs = 0.0
        adaptiveDepth.lastTargetShrinkTime = .nan
        // Reset the reconciler snapshot so a restart begins at the REST target
        // (depth 1, generation 0) and re-pulls the live decision on its first tick.
        adaptiveDepth.reconciledTargetDepth = FramePacer.targetDepth
        adaptiveDepth.reconciledDecisionGeneration = 0
        // Reset display-refresh telemetry so a restart's first window is clean.
        refreshTelemetry.refreshIntervalSumSeconds = 0
        refreshTelemetry.refreshIntervalSamples = 0
        refreshTelemetry.refreshIntervalMinSeconds = .nan
        refreshTelemetry.refreshIntervalMaxSeconds = .nan
        refreshTelemetry.lastRefreshIntervalSeconds = .nan
        refreshTelemetry.refreshChangedSinceRead = false
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
        // Stop the private tick run loop so the thread exits on full teardown.
        // invalidate() above already detached the link from it. The rebind paths
        // (screenDidChange / rebuildLink) deliberately KEEP the thread alive -
        // they re-add through installLink - so only stop() and deinit tear it down.
        pacerTickThread?.stop()
        pacerTickThread = nil
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

    // Per the code map in the file header: the throttle floor lives in
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
