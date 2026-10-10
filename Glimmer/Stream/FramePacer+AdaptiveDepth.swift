// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  FramePacer+AdaptiveDepth.swift
//
//  The adaptive target depth: it rests at 1 and walks toward the headroom level EnvSignalController
//  publishes from its 2 s jitter windows, growing one frame per window tick and shrinking one frame
//  per `targetShrinkInterval`. Plus the small cadence helpers. All `*Locked` methods run under `lock`.
//

import CoreMedia
import os

extension FramePacer {

    // MARK: - Window tick (StreamSession's 2 s present-metric timer → pacer)

    /// Grow the target one step toward the published headroom level. Called once per 2 s
    /// window and the only grow path, so a deeper buffer needs several sustained windows.
    func growDepthTowardTarget() {
        refreshReconciledTarget()
        lock.lock()
        growTargetOneStepLocked()
        lock.unlock()
    }

    /// Pull the published headroom level into `adaptiveDepth.reconciledTargetDepth`. Takes
    /// EnvSignalController's lock, so it MUST run off the pacer lock (never nest the two); an
    /// unchanged generation costs one locked compare.
    func refreshReconciledTarget() {
        assertLockNotHeld()
        let decision = EnvSignalController.shared.decision
        lock.lock()
        if decision.generation != adaptiveDepth.reconciledDecisionGeneration {
            adaptiveDepth.reconciledDecisionGeneration = decision.generation
            adaptiveDepth.reconciledTargetDepth = min(FramePacer.maxTargetDepth,
                                        max(FramePacer.targetDepth,
                                            FramePacer.targetDepth + decision.headroomLevel))
        }
        lock.unlock()
    }

    // MARK: - Adaptive target depth. All run under `lock`.

    /// The depth the published decision justifies: headroom level 0 (CLEAR, or a wired route)
    /// is depth 1 and each level adds one frame, capped at `maxTargetDepth`. Reads only the
    /// off-lock-refreshed snapshot so the pacer holds exactly one lock.
    func justifiedDepthLocked() -> Int {
        assertLockHeld()
        return adaptiveDepth.reconciledTargetDepth
    }

    /// Raise the target by at most one frame when the justified depth is higher, and arm the
    /// shrink clock so the new depth holds for one shrink interval. Never lowers.
    func growTargetOneStepLocked() {
        let justified = justifiedDepthLocked()
        guard justified > adaptiveDepth.adaptiveTargetDepth else { return }
        adaptiveDepth.adaptiveTargetDepth = min(adaptiveDepth.adaptiveTargetDepth + 1, justified)
        adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent()
    }

    /// Decay the target toward depth 1 once the decision no longer justifies it: one frame per
    /// `targetShrinkInterval`. Called once per tick from `releaseDueFrame`; it never grows, so
    /// no tick can ratchet depth. Returns the effective target the caller trims against.
    func decayTargetLocked() -> Int {
        assertLockHeld()
        guard adaptiveDepth.adaptiveTargetDepth > FramePacer.targetDepth,
              justifiedDepthLocked() < adaptiveDepth.adaptiveTargetDepth else {
            return adaptiveDepth.adaptiveTargetDepth
        }
        let now = CFAbsoluteTimeGetCurrent()
        if !adaptiveDepth.lastTargetShrinkTime.isFinite {
            adaptiveDepth.lastTargetShrinkTime = now
            return adaptiveDepth.adaptiveTargetDepth
        }
        if now - adaptiveDepth.lastTargetShrinkTime >= FramePacer.targetShrinkInterval {
            adaptiveDepth.adaptiveTargetDepth -= 1
            adaptiveDepth.lastTargetShrinkTime = now
        }
        return adaptiveDepth.adaptiveTargetDepth
    }

    // MARK: - Helpers

    /// Realized inter-present interval minus the stream's frame interval (positive =
    /// late vs the grid), plus that interval, in seconds. Read under the lock right
    /// after a present updates `lastPresentMediaTime`.
    func lastPresentInterPresentDelta() -> (error: Double, streamInterval: Double) {
        lock.lock(); defer { lock.unlock() }
        let now = lastPresentMediaTime
        defer { prevPresentMediaTimeForMetric = now }
        guard prevPresentMediaTimeForMetric.isFinite, now.isFinite else { return (0, streamFrameIntervalSeconds) }
        let interPresent = now - prevPresentMediaTimeForMetric
        return (interPresent - streamFrameIntervalSeconds, streamFrameIntervalSeconds)
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
        let idx = min(values.count - 1,
                      Int(Double(values.count) * FramePacer.cadencePercentile))
        return values[idx]
    }

    static func insertCadenceDelta(_ delta: Double, into sorted: inout [Double]) {
        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sorted[middle] < delta { lower = middle + 1 } else { upper = middle }
        }
        sorted.insert(delta, at: lower)
    }

    static func removeCadenceDelta(_ delta: Double, from sorted: inout [Double]) {
        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sorted[middle] < delta { lower = middle + 1 } else { upper = middle }
        }
        if lower < sorted.count, sorted[lower] == delta { sorted.remove(at: lower) }
    }

    /// True while recovering from a real delivery GAP - a recent empty-tick streak,
    /// or within the lenient window after one. Lets the post-gap catch-up play
    /// through instead of being trimmed/backed-off to newest. Called under `lock`.
    func inGapRecoveryLocked(now: CFTimeInterval) -> Bool {
        liveness.emptyTickStreak >= FramePacer.gapRecoveryTickThreshold
            || (liveness.lastGapRecoveryTime > 0
                && now - liveness.lastGapRecoveryTime < FramePacer.postDrainLenientSeconds)
    }

    /// Whether spare vsyncs can drain a post-gap catch-up: the learned stream
    /// rate sits below `postGapDrainableRateRatio` of the NOMINAL panel rate
    /// (link duration, so a realized-tick wobble can't flip it). Unknown panel → true.
    static func postGapCatchUpDrains(
        streamIntervalSeconds: Double, nominalVsyncSeconds: Double
    ) -> Bool {
        guard nominalVsyncSeconds.isFinite, nominalVsyncSeconds > 0 else { return true }
        return nominalVsyncSeconds < streamIntervalSeconds * postGapDrainableRateRatio
    }

    /// Trim the FIFO toward the drop ceiling, returning the stalest dropped buffers and the
    /// gap-recovery flag. The ceiling is the cap while a drainable catch-up plays through, else
    /// `effectiveTarget + 1`; a depth above target for a whole history window trims to target.
    func gapAwareTrimLocked(now: CFTimeInterval, effectiveTarget: Int)
        -> (trimmed: [CMSampleBuffer], inGapRecovery: Bool) {
        let inGapRecovery = inGapRecoveryLocked(now: now)
        let lenient = inGapRecovery && Self.postGapCatchUpDrains(
            streamIntervalSeconds: streamFrameIntervalSeconds,
            nominalVsyncSeconds: refreshTelemetry.lastRefreshIntervalSeconds)
        let dropTarget = lenient ? FramePacer.maxQueuedFrames
            : min(FramePacer.maxQueuedFrames, effectiveTarget + 1)
        var trimmed: [CMSampleBuffer] = []
        while queue.count > dropTarget { trimmed.append(queue.removeFirst().sampleBuffer) }
        // The +1 slack tolerates bunching, but at fps≈refresh a two-frame burst leaves one frame
        // standing above target on every later tick: one extra vsync of latency until a frame
        // happens to be missed. A whole window of that is latency, so drop to target.
        if !lenient, queue.count > effectiveTarget {
            if !liveness.overTargetSince.isFinite {
                liveness.overTargetSince = now
            } else if now - liveness.overTargetSince >= FramePacer.standingExtraFrameSeconds {
                trimmed.append(queue.removeFirst().sampleBuffer)
                liveness.overTargetSince = .nan
            }
        } else {
            liveness.overTargetSince = .nan
        }
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
