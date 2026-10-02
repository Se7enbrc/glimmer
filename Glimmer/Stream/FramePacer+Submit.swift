// The decode-queue submit path shares the queue lock with the display-link drain.

import AVFoundation
import CoreMedia
import os

extension FramePacer {

    // MARK: - Submit (decode queue)

    /// Queue in presentation order; hidden windows retain only the newest frame.
    /// Presentation happens on the next due vsync, except during warm handover.
    func submit(_ sampleBuffer: CMSampleBuffer, hostPTS: CMTime) {
        let ptsSeconds = hostPTS.isValid ? CMTimeGetSeconds(hostPTS) : Double.nan
        var droppedStale: CMSampleBuffer?
        var suppressedDisplaced: CMSampleBuffer?
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        let entry = makeEntryLocked(sampleBuffer, ptsSeconds: ptsSeconds)

        // Present directly until the rebuilt display link proves a healthy tick rate.
        // Suppression still wins so a hidden layer cannot present.
        if tickDeficit.warmingUp && !presentSuppressed {
            lock.unlock()
            presentWarmHandoverFrame(entry)
            return
        }

        // Empty → non-empty edge: the present watchdog times a wedge from here, so
        // a post-drought burst restarts the clock instead of reading as a stall.
        if queue.isEmpty { liveness.queueNonEmptySince = CFAbsoluteTimeGetCurrent() }

        // Insert by epoch, then hostPTS. The common in-order case appends;
        // the search walks back from the tail for cheap small reorders.
        if ptsSeconds.isFinite {
            Self.insert(entry, into: &queue)
        } else {
            // PTS-less frame (older Sunshine / defensive path) - can't pace it,
            // so just append; the cadence gate falls back to wall-clock.
            queue.append(entry)
        }

        // Hold only the newest frame while hidden; displaced buffers release off-lock.
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
        lock.unlock()

        if suppressedDisplaced != nil {
            // Suppression edges are logged; per-submit drops stay quiet.
            TelemetryCounters.shared.suppressedDropTotal.increment(by: 1)
        }
        if droppedStale != nil {
            // Overflow leaves the decode reference chain intact, so no keyframe is needed.
            stats.recordPresentationLateDrop()
            OSSignposter.render.emitEvent(
                "PacerOverflowDrop",
                "depth=\(FramePacer.maxQueuedFrames, privacy: .public)")
        }
    }

    // The caller holds the queue lock so epoch and cadence advance with the entry.
    private func makeEntryLocked(_ sampleBuffer: CMSampleBuffer, ptsSeconds: Double) -> Entry {
        let latePreWrap = ptsSeconds.isFinite && lastSubmittedPTSSeconds.isFinite
            && ptsSeconds - lastSubmittedPTSSeconds > Self.halfTimestampRangeSeconds
        let isPTSDiscontinuity = ptsSeconds.isFinite && lastSubmittedPTSSeconds.isFinite
            && ptsSeconds < lastSubmittedPTSSeconds - 1.0
        if isPTSDiscontinuity { ptsEpoch &+= 1 }
        let entryEpoch = latePreWrap && ptsEpoch > 0 ? ptsEpoch - 1 : ptsEpoch
        let entry = Entry(sampleBuffer: sampleBuffer, hostPTSSeconds: ptsSeconds, ptsEpoch: entryEpoch)

        // The lower-quartile estimate holds cadence through delivery dips and loss.
        if ptsSeconds.isFinite, lastSubmittedPTSSeconds.isFinite {
            let delta = ptsSeconds - lastSubmittedPTSSeconds
            // Reject non-positive (reorder / IDR PTS reset) and absurd gaps
            // (>1s = a stall, not a cadence sample) so the estimate stays clean.
            if delta > 0, delta < 1.0 {
                ptsDeltas.append(delta)
                Self.insertCadenceDelta(delta, into: &sortedPtsDeltas)
                if ptsDeltas.count > 64 {
                    let evicted = ptsDeltas.removeFirst()
                    Self.removeCadenceDelta(evicted, from: &sortedPtsDeltas)
                }
                // Hold the configured-fps seed for the first few deltas - a lone
                // startup gap must not yank the cadence off the negotiated rate.
                if ptsDeltas.count >= FramePacer.minCadenceRefineSamples {
                    streamFrameIntervalSeconds =
                        FramePacer.clampFrameInterval(skipRobustInterval(sortedPtsDeltas))
                }
            }
        }
        if ptsSeconds.isFinite && !latePreWrap {
            lastSubmittedPTSSeconds = ptsSeconds
        }

        return entry
    }

    private static let halfTimestampRangeSeconds = Double(UInt64(1) << 31) / 90_000

    static func insert(_ entry: Entry, into queue: inout [Entry]) {
        var insertAt = queue.count
        while insertAt > 0 {
            let previous = queue[insertAt - 1]
            let delta = previous.hostPTSSeconds - entry.hostPTSSeconds
            guard delta.isFinite else { break }
            // Compare both sides of wrap before epochs: a late pre-wrap decode
            // may arrive after the first post-wrap frame, even at session start.
            if delta > halfTimestampRangeSeconds { break }
            if delta >= -halfTimestampRangeSeconds {
                if previous.ptsEpoch < entry.ptsEpoch { break }
                if previous.ptsEpoch == entry.ptsEpoch && delta <= 0 { break }
            }
            insertAt -= 1
        }
        queue.insert(entry, at: insertAt)
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
        lock.lock()
        let wasSuppressed = presentSuppressed
        presentSuppressed = suppressed
        if wasSuppressed != suppressed {
            let now = CFAbsoluteTimeGetCurrent()
            events = clearForSuppressionLocked(now: now)
            if !suppressed {
                reseedRateWindowLocked(now: now)
                tickDeficit.deficitVerdictHoldUntilHostTime =
                    now + FramePacer.resumeVerdictHoldSeconds
            }
        }
        lock.unlock()
        // Logs the disengage + reconciles the off-tick timer OFF the lock -
        // the same discipline as every other caller of the service pass.
        handleTickDeficitEvents(events)
    }
}
