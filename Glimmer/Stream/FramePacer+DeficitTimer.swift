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

    /// One off-tick beat: run the NORMAL release pipeline (trim → backoff →
    /// due-gate, every safeguard intact) against a synthetic vsync, then
    /// repaint for the governor if nothing real flowed. `CACurrentMediaTime()`
    /// shares CADisplayLink's timebase, so the cadence base stays on one clock
    /// - when real ticks resume mid-deficit their targetTimestamps slot onto
    /// the same grid and the due gate just keeps pacing (releases stay capped
    /// at one per stream interval no matter how the two sources interleave).
    func deficitTimerFired() {
        os_unfair_lock_lock(&lock)
        let active = (tickDeficit.deficitModeActive || tickDeficit.floorAssistActive)
            && running && !presentSuppressed
        let interval = streamFrameIntervalSeconds
        os_unfair_lock_unlock(&lock)
        guard active else { return }
        releaseDueFrame(
            targetTimestamp: CACurrentMediaTime(), vsyncInterval: interval)
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
