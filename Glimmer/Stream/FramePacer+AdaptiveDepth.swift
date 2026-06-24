//
//  FramePacer+AdaptiveDepth.swift
//
//  The measured-jitter input + adaptive-target depth math + the small pure
//  metric helpers. Split out of FramePacer.swift to keep that file under the
//  length limit; this is the grow/decay of the jitter-driven target depth off
//  the smoothed RFC-3550 recv-jitter signal, plus the inter-present cadence
//  delta and median estimator the release / submit paths consume. The companion
//  stored field `prevPresentMediaTimeForMetric` stays declared in
//  FramePacer.swift with the rest of the core state. All `*Locked` methods run
//  under `lock`.
//

import CoreMedia
import os

extension FramePacer {

    // MARK: - Measured-jitter input (decode/receive path → pacer)

    /// Feed the pacer the latest SMOOTHED RFC-3550 reorder jitter (ms) measured by
    /// the RTP receive path, and walk the grow path one step toward the desired
    /// target. Driven on the same ~2s metric cadence that updates
    /// `TelemetryCounters.recvJitterMs`, so a deeper buffer requires SUSTAINED
    /// real jitter across several windows - a lone spike (already ~1s-smoothed)
    /// can't ratchet it. Grows one step per call when the desired target exceeds
    /// the current depth; shrinking stays rate-limited in `decayTargetLocked`.
    ///
    /// RECONCILER ON (default): `ms` is recorded but the desired target comes from
    /// the published headroom level (see `justifiedDepthLocked`), so this call is
    /// just a cadence-aligned GROW TICK toward that level - it no longer self-
    /// decides off `ms`. RECONCILER OFF: `ms` IS the self-decide signal (the
    /// original behavior). Either way `bumpTargetForJitterLocked` does the
    /// one-step grow.
    func noteMeasuredJitter(_ ms: Double) {
        refreshReconciledTarget()
        os_unfair_lock_lock(&lock)
        if ms.isFinite, ms >= 0 { adaptiveDepth.measuredJitterMs = ms }
        bumpTargetForJitterLocked()
        os_unfair_lock_unlock(&lock)
    }

    /// Pull the reconciler's latest published headroom level into
    /// `adaptiveDepth.reconciledTargetDepth` (mapped `targetDepth + level`, clamped). MUST be
    /// called WITHOUT the pacer lock held - it takes EnvSignalController's lock
    /// (via `.decision`), so calling it under the pacer lock would nest two locks.
    /// No-ops on an unchanged decision generation (the common path costs one
    /// short controller-lock read + a `UInt64` compare). When the reconciler is
    /// off this leaves `adaptiveDepth.reconciledTargetDepth` untouched - `justifiedDepthLocked`
    /// ignores it and self-decides off `adaptiveDepth.measuredJitterMs` instead.
    func refreshReconciledTarget() {
        guard EnvSignalController.reconcilerEnabled else { return }
        let decision = EnvSignalController.shared.decision
        os_unfair_lock_lock(&lock)
        if decision.generation != adaptiveDepth.reconciledDecisionGeneration {
            adaptiveDepth.reconciledDecisionGeneration = decision.generation
            adaptiveDepth.reconciledTargetDepth = min(FramePacer.maxTargetDepth,
                                        max(FramePacer.targetDepth,
                                            FramePacer.targetDepth + decision.headroomLevel))
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Adaptive target depth. All run under `lock`.

    /// The depth the CURRENT desired target justifies - the value the rate-limited
    /// grow/decay actuator walks `adaptiveDepth.adaptiveTargetDepth` toward. Clamped to
    /// [targetDepth, maxTargetDepth].
    ///
    /// RECONCILER ON (the default): the desired depth comes from the UNIFIED
    /// jitter→headroom decision EnvSignalController publishes - `targetDepth +
    /// headroomLevel` - so the pacer and the FEC reorder-hold walk off ONE shared
    /// level instead of each reading `recvJitterMs` independently. headroomLevel 0
    /// (clear / jitter under the dead-zone) → depth 1 (REST), each level up → +1
    /// depth, capped at `maxTargetDepth`. Only the TARGET changes; the grow/decay
    /// rate-limiter and the depth-1 floor below are untouched (they are the
    /// actuator).
    ///
    /// RECONCILER OFF (the kill-switch A/B fallback): the ORIGINAL self-decide -
    /// compute the depth off the SMOOTHED RFC-3550 `recvJitterMs` through a
    /// DEAD-ZONE: jitter at/below `jitterDeadZoneMs` (3ms) earns NO extra depth, so
    /// a clean link rests at 1; above it, +1 frame per `jitterMsPerExtraFrame` of
    /// excess. 0.09ms wired → depth 1 (passthrough); ~22ms wifi → grows toward the
    /// cap. Byte-identical to today.
    func justifiedDepthLocked() -> Int {
        if EnvSignalController.reconcilerEnabled {
            // Read ONLY the off-lock-refreshed snapshot - never the controller -
            // so the pacer holds exactly one lock (its own). Already clamped to
            // [targetDepth, maxTargetDepth] by the refresh.
            return adaptiveDepth.reconciledTargetDepth
        }
        let j = adaptiveDepth.measuredJitterMs
        let extra: Int = j <= FramePacer.jitterDeadZoneMs
            ? 0
            : Int(((j - FramePacer.jitterDeadZoneMs)
                   / FramePacer.jitterMsPerExtraFrame).rounded(.up))
        return min(FramePacer.maxTargetDepth,
                   max(FramePacer.targetDepth, FramePacer.targetDepth + extra))
    }

    /// Recompute the adaptive target from the current measured jitter and RAISE
    /// it - by AT MOST one frame per call - if SUSTAINED measured jitter demands
    /// more depth. Stepping one frame at a time, driven on the ~2s metric / tick
    /// cadence off the ~1s-smoothed signal, means a deeper buffer requires real
    /// sustained jitter, never a lone spike. Never lowers here - shrinking is
    /// rate-limited in `decayTargetLocked`. Called under the lock.
    func bumpTargetForJitterLocked() {
        let justified = justifiedDepthLocked()
        guard justified > adaptiveDepth.adaptiveTargetDepth else { return }
        // Grow ONE step per call so a deeper buffer requires SUSTAINED jitter
        // across multiple windows, never a lone spike.
        adaptiveDepth.adaptiveTargetDepth = min(adaptiveDepth.adaptiveTargetDepth + 1, justified)
        // Arm the shrink clock so the new (higher) depth holds for at least one
        // shrink interval before it can start decaying.
        adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent()
    }

    /// Decay the adaptive target back toward the baseline (depth 1) during clean
    /// running: at most one frame per `targetShrinkInterval`, and only when the
    /// measured jitter no longer justifies the current depth. Called once per tick
    /// from `releaseDueFrame` under the lock. Returns the (possibly updated)
    /// effective target so the caller uses one consistent value.
    func decayTargetLocked() -> Int {
        // RECONCILER OFF (kill-switch fallback): refresh the measured-jitter
        // signal from the shared gauge each tick, so grow/decay track the live
        // RFC-3550 recv-jitter (0.09ms wired / ~22ms wifi) even if the explicit
        // noteMeasuredJitter path isn't wired. This is the self-decide read the
        // diagnosis endorsed. RECONCILER ON: the pacer does NOT self-read the
        // shared gauge - `justifiedDepthLocked()` pulls the published headroom
        // level instead (the whole point of the unification: ONE reader of the
        // jitter signal, not two racing). `adaptiveDepth.measuredJitterMs` then just goes stale
        // (it feeds only the OFF path), which is harmless.
        if !EnvSignalController.reconcilerEnabled {
            let liveJitter = TelemetryCounters.shared.recvJitterMs
            if liveJitter.isFinite, liveJitter >= 0 { adaptiveDepth.measuredJitterMs = liveJitter }
        }
        // A rising signal/level must be able to GROW the buffer on the tick path
        // too (not only via the explicit note path), so a lossy link absorbs
        // jitter even if the setter is never called. Grow keys off
        // justifiedDepthLocked(), which is the published level when reconciling.
        bumpTargetForJitterLocked()

        guard adaptiveDepth.adaptiveTargetDepth > FramePacer.targetDepth else {
            return adaptiveDepth.adaptiveTargetDepth
        }
        // What does CURRENT measured jitter justify? If it still wants the present
        // depth, hold - don't shrink into ongoing, sustained jitter. Because the
        // signal is the ~1s-smoothed RFC-3550 metric, a transient spike clears
        // quickly and the guard below releases, letting the rate-limited shrink
        // run back to 1.
        guard justifiedDepthLocked() < adaptiveDepth.adaptiveTargetDepth else {
            return adaptiveDepth.adaptiveTargetDepth
        }

        let now = CFAbsoluteTimeGetCurrent()
        if !adaptiveDepth.lastTargetShrinkTime.isFinite {
            adaptiveDepth.lastTargetShrinkTime = now
            return adaptiveDepth.adaptiveTargetDepth
        }
        if now - adaptiveDepth.lastTargetShrinkTime >= FramePacer.targetShrinkInterval {
            adaptiveDepth.adaptiveTargetDepth -= 1            // one frame per interval
            adaptiveDepth.lastTargetShrinkTime = now
        }
        return adaptiveDepth.adaptiveTargetDepth
    }

    // MARK: - Helpers

    /// The delta between the realized inter-present interval and the stream's
    /// ideal frame interval, in seconds. Read under the lock right after a
    /// present updates `lastPresentMediaTime`. Positive = we presented late
    /// vs the grid; near zero = on cadence.
    func lastPresentInterPresentDelta() -> Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let now = lastPresentMediaTime
        defer { prevPresentMediaTimeForMetric = now }
        guard prevPresentMediaTimeForMetric.isFinite, now.isFinite else { return 0 }
        let interPresent = now - prevPresentMediaTimeForMetric
        return interPresent - streamFrameIntervalSeconds
    }

    /// SKIP-ROBUST frame-interval estimator: the lower-quartile (p25) of the PTS
    /// deltas. The cadence-learning fix for the cold-connect chug.
    ///
    /// A SKIPPED frame - the host's stream-start ramp under-delivering, or wifi
    /// loss - produces a PTS delta that is a near-MULTIPLE of the true interval
    /// (the gap spans the missing frame's slot). The MEDIAN counts those inflated
    /// gaps as the cadence, so a delivery dip to ~64fps dragged the estimate to
    /// 43-64Hz and the due gate paced the WHOLE grid that slow - the measured cold-
    /// connect stutter (rendered 38 while 64 frames/s were arriving). The lower
    /// quartile keys off the no-skip CLUSTER (the true per-frame interval is the
    /// SMALLEST delta; skips only ever ADD), so the cadence stays pinned to the
    /// real content rate through a transient dip. A GENUINE sustained rate change
    /// still moves it once the new uniform interval dominates the window -
    /// asymmetric by design: quick to adopt a FASTER rate (>p25 of the window at
    /// the short interval), slow to follow a SLOWER one (a dip is usually not a
    /// real slowdown). Steady clean state: every delta ≈ the interval, so p25 ==
    /// median == the interval - byte-identical to the prior behavior.
    func skipRobustInterval(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return streamFrameIntervalSeconds }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1,
                      Int(Double(sorted.count) * FramePacer.cadencePercentile))
        return sorted[idx]
    }

    /// True while recovering from a real delivery GAP - a recent empty-tick streak,
    /// or within the lenient window after one. Lets the post-gap catch-up play
    /// through instead of being trimmed/backed-off to newest. Called under `lock`.
    func inGapRecoveryLocked(now: CFTimeInterval) -> Bool {
        liveness.emptyTickStreak >= FramePacer.gapRecoveryTickThreshold
            || (liveness.lastGapRecoveryTime > 0
                && now - liveness.lastGapRecoveryTime < FramePacer.postDrainLenientSeconds)
    }

    /// Trim the FIFO toward the drop ceiling, returning the stalest dropped buffers
    /// and the gap-recovery flag. In gap-recovery the ceiling is the cap so the
    /// bunched catch-up plays through; otherwise `effectiveTarget + 1`. Under `lock`.
    func gapAwareTrimLocked(now: CFTimeInterval, effectiveTarget: Int)
        -> (trimmed: [CMSampleBuffer], inGapRecovery: Bool) {
        let inGapRecovery = inGapRecoveryLocked(now: now)
        let dropTarget = inGapRecovery ? FramePacer.maxQueuedFrames
            : min(FramePacer.maxQueuedFrames, effectiveTarget + 1)
        var trimmed: [CMSampleBuffer] = []
        while queue.count > dropTarget { trimmed.append(queue.removeFirst().sampleBuffer) }
        return (trimmed, inGapRecovery)
    }

    /// Advance the empty-tick streak + arm the gap-recovery window: a frame
    /// presenting right after an empty streak is the recovery edge. Under `lock`.
    func updateGapRecoveryLocked(presented: Bool, empty: Bool, now: CFTimeInterval) {
        if !presented, empty {
            liveness.emptyTickStreak += 1
        } else {
            if presented, liveness.emptyTickStreak >= FramePacer.gapRecoveryTickThreshold {
                liveness.lastGapRecoveryTime = now
            }
            liveness.emptyTickStreak = 0
        }
    }
}
