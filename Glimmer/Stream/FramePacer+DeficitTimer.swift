//
//  FramePacer+DeficitTimer.swift
//
//  The OFF-TICK release timer that carries the tick-deficit degraded mode (and
//  the floor-violation assist): the pacingQueue-confined create/cancel
//  reconcile, the synthetic-vsync beat, and the governor repaint. Split out of
//  FramePacer+TickDeficit.swift - pure move, same file-split idiom as the rest
//  of the FramePacer extensions - to keep both units under the length budget;
//  see that file for the measured-rate state machine that decides WHEN this
//  timer should be armed, and FramePacer+TickDeficitEvents.swift for the
//  transition breadcrumbs that trigger the reconcile.
//

import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - The off-tick release timer (pacingQueue-confined)

    /// Create/cancel the off-tick timer to match the lock-guarded desired state.
    /// Runs ONLY on `pacingQueue`, so `deficitTimer` itself needs no lock - the
    /// idempotent reconcile shape means racing engage/disengage transitions
    /// converge on the latest state instead of double-arming.
    func reconcileDeficitTimer() {
        os_unfair_lock_lock(&lock)
        let want = (tickDeficit.deficitModeActive || tickDeficit.floorAssistActive) && running
        let interval = streamFrameIntervalSeconds
        os_unfair_lock_unlock(&lock)
        if want, tickDeficit.deficitTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: pacingQueue)
            timer.schedule(
                deadline: .now() + interval, repeating: interval,
                leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.deficitTimerFired() }
            tickDeficit.deficitTimer = timer
            timer.resume()
        } else if !want, let timer = tickDeficit.deficitTimer {
            timer.cancel()
            tickDeficit.deficitTimer = nil
        }
    }

    /// One off-tick beat through the normal release pipeline (trim, backoff, due gate) on
    /// `CACurrentMediaTime()`, the link's own timebase, then a governor repaint if nothing flowed.
    /// A beat before the panel vsync a tick's frame scans out on skips its release.
    func deficitTimerFired() {
        let mediaNow = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        let active = (tickDeficit.deficitModeActive || tickDeficit.floorAssistActive)
            && running && !presentSuppressed
        let interval = streamFrameIntervalSeconds
        let tickOwnsVsync = Self.tickOwnsScanout(
            now: mediaNow, scanout: tickDeficit.tickScanoutMediaTime)
        os_unfair_lock_unlock(&lock)
        guard active else { return }
        if !tickOwnsVsync {
            releaseDueFrame(targetTimestamp: mediaNow, vsyncInterval: interval, tickScanout: .nan)
        }
        maybeRepaintForGovernor(interval: interval)
        // Keep the rate window rolling from here too: with ticks FULLY stopped
        // and the watchdog mid-teardown there may be no other caller, and the
        // disengage verdict must never depend on the thing that failed.
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let events = serviceTickDeficitLocked(now: now)
        os_unfair_lock_unlock(&lock)
        handleTickDeficitEvents(events)
    }

    /// True when a real tick's released frame has not yet scanned out at `now`
    /// (a beat there would present twice in one panel vsync). A lead past 1s
    /// is a timebase jump, left to the due gate's discontinuity clamp.
    static func tickOwnsScanout(now: CFTimeInterval, scanout: CFTimeInterval) -> Bool {
        let lead = scanout - now
        return lead > 0 && lead <= 1.0
    }

    /// Re-commit the most recently presented frame so the governor sees a live
    /// layer even when the host also faded (the measured ordering evidence:
    /// commits stopping is the suspected downclock trigger - one collapse
    /// PRECEDED its host dip by ~1.5s). Only after ≥2 stream
    /// intervals without a REAL release (a real release is itself a commit),
    /// rate-limited to stream cadence, and never counted as a rendered frame -
    /// the renders==received verification contract stays honest.
    func maybeRepaintForGovernor(interval: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        var repaint: CMSampleBuffer?
        os_unfair_lock_lock(&lock)
        let sinceRelease = liveness.lastReleaseHostTime.isFinite
            ? now - liveness.lastReleaseHostTime : .infinity
        let sinceRepaint = tickDeficit.lastRepaintHostTime.isFinite
            ? now - tickDeficit.lastRepaintHostTime : .infinity
        if tickDeficit.deficitModeActive || tickDeficit.floorAssistActive, !presentSuppressed,
           sinceRelease > interval * FramePacer.repaintAfterIdleIntervals,
           sinceRepaint >= interval,
           let sampleBuffer = tickDeficit.lastPresentedSampleBuffer {
            tickDeficit.lastRepaintHostTime = now
            tickDeficit.deficitRepaints &+= 1
            repaint = sampleBuffer
        }
        os_unfair_lock_unlock(&lock)
        guard let repaint else { return }
        onDeficitRepaint?(repaint)
    }
}
