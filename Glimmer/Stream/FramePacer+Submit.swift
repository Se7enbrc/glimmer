//
//  FramePacer+Submit.swift
//
//  The decode-queue submit path. Split out of FramePacer.swift to keep that file
//  under the length limit; this is the analogue of moonlight-qt's
//  `Pacer::submitFrame` → `m_PacingQueue` - it inserts a ready CMSampleBuffer in
//  hostPTS order into the bounded jitter/reorder FIFO and learns the stream's
//  inter-frame interval from PTS deltas. Runs on the VT decode queue (any
//  thread); only touches the lock-guarded FIFO + counters. See `releaseDueFrame`
//  (FramePacer+DueGate.swift) for the per-vsync drain.
//

import AVFoundation
import CoreMedia
import os

extension FramePacer {

    // MARK: - Submit (decode queue)

    /// Push a decoded, ready-to-present sample buffer into the pacing queue.
    /// Called from the VT output callback on the decode queue. The frame is
    /// inserted in hostPTS order; on overflow the oldest frame is dropped and
    /// counted as a presentation-late drop (we couldn't present it in time).
    /// While presentation is SUPPRESSED each submit instead displaces the oldest
    /// queued frame (steady-state depth 1 - only the newest frame is held) and
    /// the displaced frame counts as a SUPPRESSED drop - see the suppressed
    /// branch below.
    ///
    /// Returns immediately - the actual present happens on the next due vsync.
    func submit(_ sampleBuffer: CMSampleBuffer, hostPTS: CMTime) {
        let ptsSeconds = hostPTS.isValid ? CMTimeGetSeconds(hostPTS) : Double.nan
        let entry = Entry(
            sampleBuffer: sampleBuffer,
            hostPTSSeconds: ptsSeconds)

        var droppedStale: CMSampleBuffer?
        var suppressedDisplaced: CMSampleBuffer?
        os_unfair_lock_lock(&lock)
        guard running else {
            os_unfair_lock_unlock(&lock)
            return
        }

        // Learn the stream's frame interval from consecutive PTS deltas. The
        // lower-quartile (skip-robust) estimate over a short window holds the true
        // per-frame interval through a delivery dip / loss - where the median
        // chased the cold-connect under-delivery down to 43-64Hz and the due gate
        // paced the whole grid that slow (the startup chug). See `skipRobustInterval`.
        if ptsSeconds.isFinite, lastSubmittedPTSSeconds.isFinite {
            let delta = ptsSeconds - lastSubmittedPTSSeconds
            // Reject non-positive (reorder / IDR PTS reset) and absurd gaps
            // (>1s = a stall, not a cadence sample) so the estimate stays clean.
            if delta > 0, delta < 1.0 {
                ptsDeltas.append(delta)
                if ptsDeltas.count > 64 { ptsDeltas.removeFirst() }
                // Hold the configured-fps seed for the first few deltas - a lone
                // startup gap must not yank the cadence off the negotiated rate.
                if ptsDeltas.count >= FramePacer.minCadenceRefineSamples {
                    streamFrameIntervalSeconds =
                        FramePacer.clampFrameInterval(skipRobustInterval(ptsDeltas))
                }
            }
        }
        if ptsSeconds.isFinite {
            lastSubmittedPTSSeconds = ptsSeconds
        }

        // NOTE: the adaptive target is NO LONGER driven from submit() - the old
        // wall-clock submit-spacing jitter estimator lived here and is deleted.
        // Submit spacing on a clean link is dominated by VT/FEC drain unevenness,
        // not network jitter, so it falsely pinned the target at the cap on a
        // 0.09ms link and wedged the present path. Grow/decay now key off the
        // MEASURED RFC-3550 reorder jitter, refreshed on the tick path
        // (decayTargetLocked) from TelemetryCounters.recvJitterMs.

        // WARM HANDOVER: a re-enabled pacer keeps presenting DIRECT - bypassing
        // the queue entirely - until its rebuilt CADisplayLink proves a healthy
        // realized tick rate (FramePacer+TickDeficit.swift). Queueing against
        // an un-primed link's delayed first ticks snapped depth to the cap and
        // re-froze the stream 350ms after a measured re-enable; direct flow has
        // no tick dependency, so the cutover hiccup is structurally gone. The
        // PTS learning above still ran, so cadence is already converged when
        // the atomic flip hands release back to the due gate. Suppressed wins
        // over warm-up (nothing may present at a hidden layer) - the suppressed
        // branch below keeps its single-newest-frame behavior.
        if warmingUp && !presentSuppressed {
            os_unfair_lock_unlock(&lock)
            presentWarmHandoverFrame(entry)
            return
        }

        // Insert in hostPTS order. Common case (in-order arrival) is an append;
        // the search walks back from the tail so a single reorder is cheap.
        if ptsSeconds.isFinite {
            var insertAt = queue.count
            while insertAt > 0, queue[insertAt - 1].hostPTSSeconds > ptsSeconds {
                insertAt -= 1
            }
            queue.insert(entry, at: insertAt)
        } else {
            // PTS-less frame (older Sunshine / defensive path) - can't pace it,
            // so just append; the cadence gate falls back to wall-clock.
            queue.append(entry)
        }

        // While presentation is intentionally SUPPRESSED (window backgrounded /
        // occluded → the display link deliberately stops ticking), nothing drains
        // the FIFO, so the overflow path below would mint ~120/s of fake "late"
        // drops against the cap. These drops are DESIGNED: displace the OLDEST
        // frame so the insert nets zero growth (steady state rides at depth 1 -
        // the freshest pixels held ready for an instant resume; the enter-edge
        // bulk collapse is owned by `dropToNewest` on the suppression edge) and
        // account the displaced frame separately so `drops_presentation_late`
        // keeps meaning "failed to present in time". SINGLE-SLOT handoff, not an
        // Array append: appending would malloc while holding the lock handleTick
        // contends every vsync - same no-allocation-under-lock discipline as
        // `droppedStale` below.
        if presentSuppressed {
            if queue.count > 1 {
                suppressedDisplaced = queue.removeFirst().sampleBuffer
            }
        } else if queue.count > FramePacer.maxQueuedFrames {
            // Overflow: drop the oldest (stalest) frame. Keeping a backlog would
            // grow wall-clock latency unboundedly, which is the exact "stream
            // feels laggy after a while" symptom we're killing.
            droppedStale = queue.removeFirst().sampleBuffer
        }
        os_unfair_lock_unlock(&lock)

        if suppressedDisplaced != nil {
            // Suppressed-mode drops are quiet by design: the suppression EDGES
            // are NOTICE-logged, so a per-submit log/signpost here would be its
            // own ~120/s flood. The buffer was pulled out under the lock and
            // releases here, off it - same discipline as `droppedStale` below.
            TelemetryCounters.shared.suppressedDropTotal.increment(by: 1)
        }
        if droppedStale != nil {
            // Count the overflow drop as a presentation-late drop (load-bearing
            // telemetry). A submit-overflow drop discards an already-decoded
            // frame from the FIFO - the reference chain is intact - so it never
            // requests a keyframe; IDR/RFI is reserved for genuine decode/
            // reference breaks. (The pacer's sustained-lag → IDR hook is gone.)
            stats.recordPresentationLateDrop()
            OSSignposter.render.emitEvent(
                "PacerOverflowDrop",
                "depth=\(FramePacer.maxQueuedFrames, privacy: .public)")
        }
    }

    // MARK: - Suppression flag (suppression edges)

    /// Flip the pacer-side suppression flag (`presentSuppressed`, declared with
    /// the core state in FramePacer.swift). Called on the suppression EDGES by
    /// `VideoDecoder.setPresentSuppressed` - BEFORE the enter-edge one-shot
    /// drain, so a submit racing the edge already takes the suppressed
    /// drop-to-newest branch above instead of minting an overflow late-drop.
    ///
    /// EDGE HYGIENE for the tick-deficit machinery (all 8 false deficit
    /// engages + the 1 false FLOOR VIOLATION observed were resume-edge
    /// artifacts - windows spanning by-design-non-ticking suppressed time):
    /// on EITHER edge any live deficit episode/latch is cleared (the hide
    /// instant must stop the off-tick timer; a hidden layer is not a fault),
    /// and on the CLEAR edge the realized-rate window re-seeds from now -
    /// the machinery measures only un-suppressed time - plus a short verdict
    /// hold so the rebound link's delayed first ticks can't mint an engage.
    /// Jittery-link safety: this only ever CLEARS/defers fault verdicts at
    /// known-benign edges; trip conditions and thresholds are untouched, and
    /// a genuine collapse after refocus is still measured (windows keep
    /// rolling) and judged ≤0.5s later - inside the watchdog's 1.75s trip.
    func setPresentSuppressed(_ suppressed: Bool) {
        var events: [TickDeficitEvent] = []
        os_unfair_lock_lock(&lock)
        let wasSuppressed = presentSuppressed
        presentSuppressed = suppressed
        if wasSuppressed != suppressed {
            let now = CFAbsoluteTimeGetCurrent()
            events = clearForSuppressionLocked(now: now)
            if !suppressed {
                reseedRateWindowLocked(now: now)
                deficitVerdictHoldUntilHostTime =
                    now + FramePacer.resumeVerdictHoldSeconds
            }
        }
        os_unfair_lock_unlock(&lock)
        // Logs the disengage + reconciles the off-tick timer OFF the lock -
        // the same discipline as every other caller of the service pass.
        handleTickDeficitEvents(events)
    }
}
