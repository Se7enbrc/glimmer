//
//  FramePacer+DueGate.swift
//
//  The due-gate + release core (decide-and-release on the dedicated serial
//  pacing queue). Split out of FramePacer.swift to keep that file under the
//  length limit; this is the per-vsync trim → backoff → due-gate → present
//  pipeline plus the present-loop-backoff helpers it calls, the nested types it
//  constructs/returns (`BackoffBeat`, `DueGateResult`), and the cadence-base
//  reset/re-anchor helpers the gate's grid depends on. See `handleTick` (the
//  dispatcher) and `decayTargetLocked` (the adaptive trim target).
//

import AVFoundation
import CoreMedia
import os

extension FramePacer {

    /// A present-loop backoff beat: the single freshest frame to present plus the
    /// stale backlog dropped to get there. Returned by `takeBackoffNewestLocked`.
    struct BackoffBeat {
        let newest: Entry
        let droppedCount: Int
    }

    /// The outcome of the per-tick due-gate: the frame to present (nil = nothing
    /// due / idle tick), whether a barely-due head was deliberately held to grow
    /// the buffer (so the starvation failsafe doesn't count this tick), and
    /// whether this release was FORCED by the over-target short-circuit (a genuine
    /// drainable backlog above the adaptive target that the due gate would
    /// otherwise have latched not-due - the no-network present-stall fix). The
    /// last flag drives only observability; it never alters the present itself.
    struct DueGateResult {
        let toPresent: Entry?
        let heldForGrowth: Bool
        let forcedOverTarget: Bool
    }

    /// Reset the pacing TIMEBASE under the lock. MUST be called on every link
    /// (re)bind. `lastPresentMediaTime` is gated against a CADisplayLink's
    /// `targetTimestamp`; that timebase goes DISCONTINUOUS across a link
    /// rebuild / display-mode switch / sleep-wake, so a stale value left over
    /// from the OLD link's clock can be AHEAD of the NEW link's targetTimestamp
    /// → `sinceLast` goes negative → `due` is never true again → permanent
    /// freeze. Resetting to `.nan` makes the very first tick on the new link
    /// hit the "first present" branch, release immediately, and re-seed the
    /// base from the CURRENT link's clock. This is the prime root-cause fix.
    func resetCadenceBaseLocked() {
        lastPresentMediaTime = .nan
        prevPresentMediaTimeForMetric = .nan
    }

    /// In-place sibling of `resetCadenceBaseLocked`: re-anchor the cadence base ON
    /// the stream grid, ONE interval BEHIND the live link's `targetTimestamp` (must
    /// be FINITE; falls back to the `.nan` reset otherwise). Call under the lock.
    /// The `.nan` reset releases ONE frame next tick then re-seeds the base to
    /// `targetTimestamp` - AHEAD of the queued frames' grid - so the due-gate
    /// RE-LATCHES not-due (the ~1-release-per-8-ticks limp). Anchoring one interval
    /// behind makes `sinceLast ≈ streamFrameIntervalSeconds >= interval - slack`, so
    /// the next queued frame is DUE and STAYS due - flow resumes next vsync with no
    /// link rebuild or 5s pacer re-enable wait. Used by backoff reseed + failsafe.
    func anchorCadenceBaseOnGridLocked(targetTimestamp: CFTimeInterval) {
        guard targetTimestamp.isFinite else {
            resetCadenceBaseLocked()
            return
        }
        lastPresentMediaTime = targetTimestamp - streamFrameIntervalSeconds
        prevPresentMediaTimeForMetric = .nan
    }

    /// PRESENT-LOOP BACKOFF decision (called under `lock` from `releaseDueFrame`).
    /// When the head frame is HOPELESSLY late (> `presentBackoffLatenessIntervals`
    /// stream intervals) AND a fresher frame is queued behind it, collapse the FIFO
    /// to its single newest frame, re-anchor the cadence base on-grid, and return
    /// it for immediate present - killing the busy-spin where the present path
    /// churns doomed late frames every tick (on a lossy wifi link: 80-96% CPU,
    /// fps_rendered→0). We require a finite POSITIVE lateness; a negative / absurd
    /// `sinceLast` is a timebase discontinuity owned by the due-gate's defensive
    /// clamp, not this path. Returns nil on a normally-paced / jitter-buffered
    /// stream, whose head is never this late. MUTATES queue - caller holds the lock.
    func takeBackoffNewestLocked(targetTimestamp: CFTimeInterval) -> BackoffBeat? {
        guard queue.count > 1, lastPresentMediaTime.isFinite else { return nil }
        let sinceLast = targetTimestamp - lastPresentMediaTime
        let backoffThreshold =
            streamFrameIntervalSeconds * FramePacer.presentBackoffLatenessIntervals
        guard sinceLast.isFinite, sinceLast > 0, sinceLast > backoffThreshold else {
            return nil
        }
        let newest = queue.removeLast()
        let droppedCount = queue.count
        queue.removeAll(keepingCapacity: true)
        // Re-anchor ON the grid, NOT at `targetTimestamp`: parking the base at
        // `targetTimestamp` put it ≈one vsync AHEAD of fresh frames → the due-gate
        // latched not-due → a hard wedge (observed on a lossy wifi link). See
        // `anchorCadenceBaseOnGridLocked`. Clear the streak - we are presenting.
        anchorCadenceBaseOnGridLocked(targetTimestamp: targetTimestamp)
        liveness.starvedTickStreak = 0
        return BackoffBeat(newest: newest, droppedCount: droppedCount)
    }

    /// Stamp the release liveness clocks + the tick-deficit repaint source after
    /// a frame ACTUALLY reached the renderer. The release clock is what the
    /// watchdog's "present wedged" trip gates on; the retained sample buffer is
    /// the one the layer is now displaying, so holding it costs no extra surface.
    /// Takes the lock itself - call OFF the lock, right after a true
    /// `willPresent` return. Shared by the due-gate release, the backoff beat,
    /// and the warm-handover direct present.
    func noteFramePresented(_ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        liveness.lastReleaseHostTime = CFAbsoluteTimeGetCurrent()
        liveness.releaseCount &+= 1
        liveness.presentRejectStreak = 0
        tickDeficit.lastPresentedSampleBuffer = sampleBuffer
        os_unfair_lock_unlock(&lock)
    }

    /// Count one pacer-path release the renderer REFUSED (`willPresent` false).
    /// The due gate's missing bookkeeping behind the wired-link present wedge:
    /// a dequeue that dies at the renderer is neither a release (the
    /// release clock rightly stays stale) nor a gate wedge (`toPresent` was
    /// non-nil, so the starvation failsafe rightly stays disarmed) - it is a
    /// RENDERER fault, and without this streak the episode was indistinguishable
    /// from a latched gate, so the watchdog spent its cheap stages on cadence/
    /// link medicine that a latched `isReadyForMoreMediaData` survives (the
    /// in-ladder rebuild changed nothing; only the stage-3 flush cured it).
    /// Consecutive-only: any successful present resets it (noteFramePresented),
    /// so healthy transient backpressure - Apple's "a single late vsync can
    /// flip the flag for one frame" class, and anything wifi jitter can cause
    /// upstream - can never accumulate toward the ladder's threshold.
    func noteGateReleaseRejected() {
        os_unfair_lock_lock(&lock)
        liveness.presentRejectStreak += 1
        os_unfair_lock_unlock(&lock)
    }

    /// Present the freshest frame from a backoff beat and record its telemetry.
    /// Called OFF the lock (caller already unlocked). Counts the dropped backlog
    /// as presentation-late drops and stamps the release liveness clocks so the
    /// watchdog sees the catch-up. A backoff beat discards already-decoded frames
    /// from the present queue (reference chain intact), so it requests NO IDR -
    /// see the removed `onSustainedLag` hook on `FramePacer`.
    func presentBackoffAndYield(_ beat: BackoffBeat) {
        for _ in 0..<beat.droppedCount { stats.recordPresentationLateDrop() }
        stats.recordPacingDepth(0)
        OSSignposter.render.emitEvent(
            "PacerBackoffDropToNewest",
            "discarded=\(beat.droppedCount, privacy: .public)")
        guard let willPresent else { return }
        if willPresent(beat.newest.sampleBuffer) {
            noteFramePresented(beat.newest.sampleBuffer)
        } else {
            // The renderer refused the freshest frame too - feed the reject
            // streak so a latched-unready renderer steers the ladder to the
            // flush (see noteGateReleaseRejected).
            noteGateReleaseRejected()
        }
    }

    /// Decide whether the head frame is DUE this vsync and pop it if so (called
    /// under `lock` from `releaseDueFrame`). Refresh-vs-fps aware: due every tick
    /// at fps==refresh, every Nth tick at fps<refresh (idle ticks re-show the last
    /// frame), every tick at fps>refresh (the trim already dropped the backlog). A
    /// fixed 2ms of slack avoids the fps≈refresh 1.5x judder; the
    /// grow-without-a-hitch gate tightens that slack only while filling toward a
    /// raised adaptive target. MUTATES queue state - caller must hold the lock.
    func dequeueDueFrameLocked(
        targetTimestamp: CFTimeInterval, effectiveTarget: Int
    ) -> DueGateResult {
        assertLockHeld()
        guard !queue.isEmpty else {
            return DueGateResult(toPresent: nil, heldForGrowth: false, forcedOverTarget: false)
        }
        var heldForGrowth = false
        var forcedOverTarget = false
        let due: Bool
        // GROW-WITHOUT-A-HITCH gate. When the adaptive target has risen above the
        // current depth (the link just got jittery, or we're filling the baseline
        // after a flush), hold one extra frame so the buffer DEEPENS out of the
        // slack a clean link provides - at zero added per-frame latency, because we
        // only ever hold back a frame that is BARELY due (within the half-vsync
        // slack). A genuinely overdue frame always releases, so this can never
        // starve the present path. fps<refresh idle ticks (head not due at all) are
        // untouched. The gate is purely additive: it tightens release only while
        // depth < target.
        let belowTarget = queue.count <= effectiveTarget
        // Over-target backlog test uses the trim ceiling (`effectiveTarget + 1`), not
        // `effectiveTarget`: at fps==refresh the natural rest depth equals the bare
        // target, so `> effectiveTarget` mis-read that rest state as backlog and force-
        // released most presents on a clean link. Only a TRUE over-ceiling build trips.
        let overTargetBacklog = queue.count > effectiveTarget + 1
        if lastPresentMediaTime.isFinite {
            let sinceLast = targetTimestamp - lastPresentMediaTime
            // DEFENSIVE CLAMP - the heart of the freeze fix on the gate.
            // `targetTimestamp` and `lastPresentMediaTime` must share the
            // CADisplayLink's timebase, but that timebase goes DISCONTINUOUS across
            // a link rebuild / display-mode switch / VRR retrain / sleep-wake. When
            // it does, `sinceLast` can go negative (or absurdly large), and the
            // plain `>=` test below would latch false forever → permanent freeze.
            // Treat any non-finite / negative / >1s delta as "due now" and re-seed
            // from the current link's clock (the `if due` block below sets
            // lastPresentMediaTime = targetTimestamp), so a timebase jump
            // self-corrects on the very NEXT tick instead of wedging.
            if !sinceLast.isFinite || sinceLast < 0 || sinceLast > 1.0 {
                due = true
            } else if overTargetBacklog {
                // OVER-TARGET SHORT-CIRCUIT - the no-network present-stall fix.
                // Steady-state the trim bounds the FIFO to `effectiveTarget + 1`, so
                // `count > effectiveTarget + 1` is UNREACHABLE then; this fires ONLY in
                // gap-recovery, whose lenient ceiling is `maxQueuedFrames`. There a real
                // backlog must always drain, so force the head out NOW. The `if due`
                // tail re-anchors `lastPresentMediaTime` to keep the grid aligned.
                due = true
                forcedOverTarget = true
            } else {
                // Slack = a small FIXED ms (not half a vsync, which scaled with
                // refresh and penalized 120Hz vs 240Hz). Just enough to absorb
                // sub-frame arrival jitter; see `dueGateSlackSeconds`.
                let slack = FramePacer.dueGateSlackSeconds
                let interval = streamFrameIntervalSeconds
                // GROW: while we're still filling toward the adaptive target,
                // require the head to be FULLY due (a whole interval elapsed)
                // instead of due-minus-slack. That holds a barely-due head for one
                // more tick so the queue can build the extra slot. Once at or above
                // target, use the normal slack-relaxed test so steady state has
                // zero added latency.
                //
                // STARTUP GATE: do NOT run the grow-hold until cadence has locked
                // (`liveness.releaseCount > startupGrowHoldReleases`). During the first
                // ~0.25s the PTS-median interval is still converging and startup
                // jitter has transiently inflated the adaptive target; holding
                // barely-due frames in that window presents half of them late (the
                // startup chop) and trips the present-stall watchdog. Until cadence
                // locks we use the normal slack-relaxed test, so the buffer primes
                // from a clean link's natural slack WITHOUT ever holding a frame late.
                let cadenceLocked = liveness.releaseCount > FramePacer.startupGrowHoldReleases
                if cadenceLocked && belowTarget
                    && adaptiveDepth.adaptiveTargetDepth > FramePacer.targetDepth {
                    due = sinceLast >= interval
                    // If the head was barely-due (would have presented under the
                    // normal slack test) but we held it to grow, mark it so the
                    // starvation failsafe doesn't count this tick.
                    if !due && sinceLast >= (interval - slack) {
                        heldForGrowth = true
                    }
                } else {
                    due = sinceLast >= (interval - slack)
                }
            }
        } else {
            // First present: always release immediately so the window can fade in
            // on a real frame without waiting a cadence beat.
            due = true
        }
        guard due else {
            return DueGateResult(
                toPresent: nil, heldForGrowth: heldForGrowth, forcedOverTarget: false)
        }
        let entry = queue.removeFirst()
        lastPresentMediaTime = targetTimestamp
        return DueGateResult(
            toPresent: entry, heldForGrowth: false, forcedOverTarget: forcedOverTarget)
    }

    /// Decide-and-release on the dedicated serial queue. Releases at most one
    /// frame per tick (one present per vsync), after trimming sustained lag.
    func releaseDueFrame(targetTimestamp: CFTimeInterval, vsyncInterval: CFTimeInterval) {
        var toPresent: Entry?
        var trimmed: [CMSampleBuffer] = []
        var sampledDepth = 0

        // Refresh the reconciler's desired target BEFORE taking the
        // pacer lock (the refresh briefly takes the controller's lock; doing it
        // here keeps the pacer from ever holding two locks). The grow/decay math
        // below - under the pacer lock - then reads only the pulled snapshot.
        refreshReconciledTarget()

        os_unfair_lock_lock(&lock)
        // `!tickDeficit.warmingUp`: during a warm handover the queue is empty by design
        // (submits direct-present until the rebuilt link proves healthy ticks
        // - FramePacer+TickDeficit.swift), so a tick here has nothing to do.
        // Bailing keeps the priming span from polluting the depth samples and
        // stale-repeat counter while real frames are demonstrably flowing.
        guard running, !tickDeficit.warmingUp else {
            os_unfair_lock_unlock(&lock)
            return
        }

        // ---- Adaptive trim (low-latency drop-to-newest toward the adaptive
        //      target) ----
        //
        // Decay the jitter-driven target first, then every release bring the FIFO
        // back toward THAT adaptive target, keeping at most ONE frame of slack
        // (`effectiveTarget + 1`). This is the low-latency-correct gaming behavior
        // (moonlight drops to stay current): a static scene yields tiny P-frames
        // that VT/FEC drains in BUNCHES, so a motion RESUME after idle lands
        // several frames inside one vsync window while we release only 1/vsync.
        // Trimming each tick absorbs the burst by DROPPING-TO-NEWEST - present the
        // freshest frame, discard the stale intermediate ones - so
        // output_to_present returns to ~1-2 vsyncs within a frame or two.
        //
        // The OLD lenient policy relaxed the ceiling to the hard cap (6) whenever
        // ANY recent depth sample sat at/below target (almost always true - the
        // queue dips to <=1 on quiet beats), so a burst filled to 6 and RODE the
        // cap: a standing ~50ms output_to_present that came/went with motion
        // (on a lossy wifi link: o2p clustered at exactly 5x/6x the 8.33ms vsync,
        // decode flat ~1.5-3ms). The minimal +1 slack still tolerates benign 1↔2
        // cadence oscillation (fps≈refresh, a frame landing a hair early) without
        // trimming every other tick → no judder / no spurious late-drops on a
        // steady stream; only a 2-deep-or-more standing build trims.
        //
        // ADAPTIVE-JITTER SAFEGUARD: `effectiveTarget` is `decayTargetLocked()`,
        // the GROWN adaptive target - 1 on a clean link, climbing toward the cap
        // under real measured RFC-3550 reorder jitter. The ceiling rises WITH it
        // (wifi at target 5 ⇒ trim only above 6), so the trim NEVER drops below
        // the adaptive target: the wifi jitter buffer still fills and holds as
        // designed; only latency ABOVE the (correct, possibly grown) target sheds.
        let effectiveTarget = decayTargetLocked()
        // POST-GAP LENIENCY: in gap-recovery the trim ceiling rises to the cap so the
        // bunched catch-up plays THROUGH (drained 1/vsync) instead of trim-to-newest -
        // the discard that cost ~20% of frames on a gappy link; otherwise it stays at
        // `effectiveTarget + 1`. Gated on a real empty-tick streak so ordinary motion-
        // bunches still trim tight. Zero standing latency. See `gapAwareTrimLocked`.
        let nowTime = CFAbsoluteTimeGetCurrent()
        let (gapTrimmed, inGapRecovery) = gapAwareTrimLocked(
            now: nowTime, effectiveTarget: effectiveTarget)
        trimmed = gapTrimmed

        // Snapshot the post-trim depth for the per-tick depth telemetry
        // (pacing_depth / pacing_depth_max) - the signal the diagnosis keys on to
        // re-measure this fix.
        sampledDepth = queue.count

        // ---- PRESENT-LOOP BACKOFF (the chop): hopelessly-late → drop-to-newest
        //      and present NOW instead of spinning over doomed late frames ----
        //
        // The adaptive trim above keeps the queue near the (possibly grown)
        // target, but the HEAD it leaves can still be hopelessly stale when the
        // present callback was throttled and a backlog formed faster than one
        // present/vsync can drain it. Decide UNDER the lock whether this tick is a
        // backoff beat; if so we unlock, present the single newest frame, and
        // YIELD (the helper handles telemetry + present). SUPPRESSED in gap-recovery:
        // collapsing to newest would discard the catch-up we want to play through,
        // and the lenient trim already bounds the backlog so the busy-spin can't return.
        if !inGapRecovery,
           let backoff = takeBackoffNewestLocked(targetTimestamp: targetTimestamp) {
            sampledDepth = 0
            os_unfair_lock_unlock(&lock)
            presentBackoffAndYield(backoff)
            // Yield: do NOT fall through to the due gate / starvation failsafe.
            // The backlog is gone and the newest frame is on screen.
            return
        }

        // ---- Is the head frame DUE this vsync? ----
        //
        // Refresh-vs-fps aware. We release when display time since the last present
        // reaches (just about) the stream's frame interval, so: fps==refresh → due
        // every tick; fps<refresh → due every Nth tick (intermediate ticks re-show
        // the last frame; "every other tick" for 60-on-120 falls out automatically);
        // fps>refresh → the trim above dropped the backlog, release the head every
        // tick. A fixed 2ms of slack lets a barely-not-due frame present now rather
        // than wait a whole vsync (the classic 1.5x judder near fps≈refresh); the
        // grow-without-a-hitch gate tightens that slack only while filling a target.
        //
        // `heldForGrowth` is true when this tick deliberately withheld a barely-due
        // head to grow the buffer (not a genuine wedge) - it keeps the starvation
        // failsafe from mistaking an intentional one-tick hold for a latched-false
        // gate. The full decision lives in `dequeueDueFrameLocked` to keep this
        // function within complexity limits.
        let gate = dequeueDueFrameLocked(
            targetTimestamp: targetTimestamp, effectiveTarget: effectiveTarget)
        toPresent = gate.toPresent
        let heldForGrowth = gate.heldForGrowth

        // Gap-recovery edge: a frame presenting right after an empty-tick streak
        // arms the lenient window that plays the catch-up through (see the trim).
        updateGapRecoveryLocked(
            presented: toPresent != nil, empty: queue.isEmpty, now: nowTime)

        // ---- Internal starvation failsafe (independent of the external
        // watchdog) ----
        //
        // If ticks keep arriving but nothing has been released while the queue is
        // non-empty, the `due` gate is wedged (or the cadence base is poisoned).
        // Count the streak; once it crosses a few vsyncs' worth, log the diagnosis
        // and re-anchor the cadence base ON the live grid so the head is DUE next
        // tick - breaking a latched-false `due` before the external watchdog fires.
        // A deliberate one-tick grow-hold is NOT a wedge - exclude it so the
        // failsafe only ever fires on a genuinely latched-false gate.
        let wedgedThisTick = !queue.isEmpty && toPresent == nil && !heldForGrowth
        var sinceLastForLog: CFTimeInterval = .nan
        var forcedSelfHeal = false
        if wedgedThisTick {
            liveness.starvedTickStreak += 1
            sinceLastForLog = lastPresentMediaTime.isFinite
                ? targetTimestamp - lastPresentMediaTime : .nan
            if liveness.starvedTickStreak >= FramePacer.starvationFailsafeTicks {
                // Re-anchor ON the live grid rather than reseeding to `.nan` (which
                // RE-LATCHES the wedge into the ~15fps limp; telemetry rn~12). On-
                // grid self-clears the wedge next vsync. See the helper.
                anchorCadenceBaseOnGridLocked(targetTimestamp: targetTimestamp)
                forcedSelfHeal = true
                liveness.starvedTickStreak = 0
            }
        } else if toPresent != nil {
            liveness.starvedTickStreak = 0
            liveness.loggedStarvation = false
        }
        let shouldLogStarvation = wedgedThisTick
            && liveness.starvedTickStreak >= FramePacer.starvationLogTicks
            && !liveness.loggedStarvation
        if shouldLogStarvation { liveness.loggedStarvation = true }
        let starvationSnapshot = StarvationSnapshot(
            streak: liveness.starvedTickStreak, depth: sampledDepth,
            sinceLastMs: sinceLastForLog * 1000, targetTimestamp: targetTimestamp,
            lastPresent: lastPresentMediaTime, intervalMs: streamFrameIntervalSeconds * 1000)
        os_unfair_lock_unlock(&lock)

        // Per-tick PRESENT-signal observability (the stale-frame repeat + the
        // over-target force-release telemetry). Folded into one helper so neither
        // branch grows this already-large function's complexity/body; see
        // `recordPerTickPresentSignals` for the two signals' rationale.
        recordPerTickPresentSignals(gate, depth: sampledDepth)

        emitStarvationDiagnostics(
            shouldLog: shouldLogStarvation, forcedSelfHeal: forcedSelfHeal,
            snapshot: starvationSnapshot)

        // Stats: sampled depth every tick (cadence-rate sampling) so the
        // overlay can show how deep the jitter buffer is sitting.
        stats.recordPacingDepth(sampledDepth)

        // Count each trimmed frame as a presentation-late drop (the renderer
        // owns sample lifetime; ARC frees the trimmed buffers when `trimmed`
        // goes out of scope).
        for _ in trimmed {
            stats.recordPresentationLateDrop()
        }
        if !trimmed.isEmpty {
            OSSignposter.render.emitEvent(
                "PacerTrim",
                "count=\(trimmed.count, privacy: .public) depthAfter=\(sampledDepth, privacy: .public)")
        }

        // ---- Presentation-late trim is NOT an IDR trigger ----
        //
        // A trim drops already-decoded CMSampleBuffers from the present queue
        // (the VT decoder already produced them; the reference chain is intact),
        // so a keyframe can't fix it and would only blur/refocus at 4K240. The
        // pacer therefore NO LONGER escalates a laggy beat to an IDR - the old
        // `onSustainedLag` hook is gone. Trimming-to-newest is the correct
        // low-latency behavior and we keep counting every trimmed frame as a
        // presentation-late drop above (load-bearing telemetry); we just don't
        // ask the host for anything. Real reference breaks (depacketizer RFI on
        // wire loss, VT decode errors) own the only remaining IDR/RFI paths.

        guard let entry = toPresent else { return }

        // Hand the frame to the owner's present path. `willPresent`
        // (VideoDecoder.presentFrame) owns the renderer-status / backpressure
        // policy AND the actual `renderer.enqueue` - the pacer deliberately
        // does NOT enqueue itself, so there's a single enqueue site and the
        // pacer stays decoupled from the layer's failure handling. A false
        // return means the frame was dropped at the renderer (failed / not
        // ready); we don't count it as an on-cadence present in that case.
        guard let willPresent else { return }
        let presented = willPresent(entry.sampleBuffer)
        guard presented else {
            // The gate did its job - the RENDERER refused the frame (failed /
            // not ready). Count the consecutive-reject streak: this is the
            // wedge signature the renderer-refusal incident proved invisible
            // (releases 0/s, ticks healthy, depth 1, survived a link rebuild) -
            // the measured escape the recovery ladder keys the flush on.
            noteGateReleaseRejected()
            return
        }

        // Present-side liveness: a frame ACTUALLY reached the renderer. This is
        // the clock the watchdog's "present wedged" trip gates on - the single
        // number that proves the screen is being updated, distinct from the
        // decode-output clock the old watchdog was blind to. Stamp it (plus the
        // tick-deficit repaint source) before the cadence metric so the
        // watchdog sees the freshest possible value.
        noteFramePresented(entry.sampleBuffer)

        // Present-cadence metric (only for frames that actually reached the
        // renderer): how far this present landed from the ideal grid. We
        // measure present-vs-PTS as the delta between the realized inter-present
        // wall-clock and the stream's frame interval - a smooth stream lands
        // near zero; jitter shows as spread.
        let presentDelta = lastPresentInterPresentDelta()
        stats.recordPresent(cadenceErrorMs: presentDelta * 1000.0)
    }

    /// The two per-tick PRESENT-signal recordings, folded into one call so neither
    /// grows `releaseDueFrame`'s complexity/body: the stale-frame REPEAT counter
    /// and the over-target force-release telemetry. Called OFF the gate's lock
    /// (caller unlocked). See each sub-helper for its rationale.
    func recordPerTickPresentSignals(_ gate: DueGateResult, depth: Int) {
        recordStaleRepeatIfNeeded(gate.toPresent == nil)
        recordOverTargetReleaseIfNeeded(gate, depth: depth)
    }

    /// Bump the stale-frame REPEAT counter (signal: PRESENT) when a running tick
    /// presented no new frame - the layer re-shows the last one (the invisible
    /// stutter). Kept off `releaseDueFrame` so its branch doesn't grow that
    /// already-large function. Always-live sub-µs integer add; the exporter
    /// derives a repeats/sec rate from the monotonic total.
    func recordStaleRepeatIfNeeded(_ repeated: Bool) {
        if repeated { TelemetryCounters.shared.staleFrameRepeatTotal.increment() }
    }

    /// OVER-TARGET force-release observability (the no-network present-stall fix).
    /// `forced` is true when the due gate would have latched not-due against a
    /// GENUINE drainable backlog (one frame above the adaptive target that survived
    /// the per-tick trim) and the short-circuit forced the head out instead.
    /// Bumps the monotonic per-second counter (exactly like the stale-repeat
    /// counter - a SPIKE in its rate is the over-drain↔re-grow oscillation), and
    /// tracks a consecutive streak under the lock so a one-shot signpost can
    /// bracket a sustained episode; a normally-due release (`released && !forced`)
    /// clears the streak so it measures only the oscillation, never steady state.
    /// Kept off `releaseDueFrame` so its branch doesn't grow that already-large
    /// function's complexity/body. Called OFF the gate's lock (caller unlocked).
    func recordOverTargetReleaseIfNeeded(_ gate: DueGateResult, depth: Int) {
        let forced = gate.forcedOverTarget
        let released = gate.toPresent != nil
        var streakSnapshot = 0
        var shouldSignpost = false
        os_unfair_lock_lock(&lock)
        if forced {
            liveness.overTargetReleaseStreak += 1
            streakSnapshot = liveness.overTargetReleaseStreak
            // Signpost once, when the streak first crosses the starvation log
            // threshold - a sustained over-target episode is the same
            // self-oscillation signature, surfaced before it could ever reach the
            // failsafe (which it now never will, since we force the release).
            shouldSignpost = liveness.overTargetReleaseStreak == FramePacer.starvationLogTicks
        } else if released {
            liveness.overTargetReleaseStreak = 0
        }
        os_unfair_lock_unlock(&lock)
        guard forced else { return }
        TelemetryCounters.shared.pacerOverTargetReleaseTotal.increment()
        if shouldSignpost {
            OSSignposter.render.emitEvent(
                "PacerOverTargetRelease",
                "streak=\(streakSnapshot, privacy: .public) depth=\(depth, privacy: .public)")
        }
    }
}
