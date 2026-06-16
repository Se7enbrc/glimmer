//
//  FramePacer+Tick.swift
//
//  The CADisplayLink vsync tick (main run loop → pacingQueue). Split out of
//  FramePacer.swift to keep that file under the length limit; this is the cheap
//  main-thread link-timing capture that hands the release decision to the serial
//  pacing queue so nothing on the present path runs on the main actor. See
//  `installLink` (the bind site) and `releaseDueFrame` (the dispatched release).
//

import AppKit
import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - Realized-cadence telemetry state (main actor, metric-only)

    /// Previous tick's `targetTimestamp`, so the refresh-window telemetry can
    /// accumulate the REALIZED callback cadence (deltas of successive targets)
    /// rather than the nominal `link.duration`, which reads the panel's rated
    /// interval even while callbacks are being skipped. Main-actor confined:
    /// `handleTick` is the only reader/writer. Static because an extension can't
    /// add instance storage; safe process-wide since exactly one pacer ticks at
    /// a time (one streaming session), and a stale cross-instance value just
    /// produces one delta the plausibility bounds in `handleTick` discard.
    @MainActor static var lastTickTargetTimestamp: CFTimeInterval = .nan

    /// Ceiling for a plausible realized tick delta (seconds). Above this the
    /// gap is a link suspension (backgrounded window), a rebuild, or a stale
    /// cross-instance timestamp — not panel cadence — and folding it in would
    /// poison the window's min-Hz with a nonsense sub-Hz reading. 0.5s sits far
    /// above the slowest panel idle cadence (ProMotion's 24Hz ≈ 42ms) yet below
    /// any suspension-scale gap.
    static let maxRealizedTickDeltaSeconds: Double = 0.5

    // MARK: - Vsync tick (main run loop → pacingQueue)

    /// CADisplayLink callback (main run loop). We capture only the cheap link
    /// timing here, then hand the release decision to the serial pacing queue
    /// so nothing on the present path runs on the main actor.
    @MainActor
    func handleTick(_ link: CADisplayLink) {
        // The link's realized cadence — refresh-agnostic. `duration` is the
        // nominal vsync interval; `targetTimestamp` is when the frame we
        // present THIS tick will actually scan out. We pace toward
        // targetTimestamp so a frame lands on the right vsync, not the one
        // we're already inside.
        let target = link.targetTimestamp
        // `duration` is reliably > 0 on a running link; the 1/60 fallback only
        // guards a degenerate first tick. We deliberately use a constant here
        // (not the shared cadence estimate) so this main-thread read touches no
        // lock-guarded state.
        let vsyncInterval = link.duration > 0 ? link.duration : (1.0 / 60.0)

        // Present-side liveness: stamp that the LINK is alive on the main run
        // loop. This is the clock the watchdog's "link dead" trip gates on — a
        // stopped link (same-screen HDR/VRR mode switch) freezes this value
        // even though VT keeps decoding. Cheap: one lock + two stores.
        //
        // ALSO accumulate the REALIZED cadence for the display-refresh telemetry
        // (ProMotion ramp-down detector + callback-miss visibility): deltas of
        // successive callbacks' targetTimestamps, NOT the nominal `duration` —
        // the nominal interval reads a constant rated Hz even while callbacks
        // skip, while a missed callback stretches the realized delta, so the
        // per-window min/avg/max expose the tick deficit. The refresh-CHANGE
        // edge stays on the NOMINAL interval (the panel-cadence ramp signal) so
        // it doesn't fire on every skipped tick. Min/avg/max over the 1Hz
        // exporter window — all cheap arithmetic under the lock we already take
        // here. A "refresh changed" signpost is emitted off-lock below so a
        // profile run marks the ramp edge.
        //
        // The realized delta is NaN until the second tick, can step NEGATIVE
        // across a link rebuild (the new link's targetTimestamp can sit behind
        // the old one's — that timebase is discontinuous across rebuilds), and
        // is suspension-sized after a backgrounded window — the bounds below
        // exclude all three.
        let realizedInterval = target - Self.lastTickTargetTimestamp
        Self.lastTickTargetTimestamp = target
        var emitRefreshChange = false
        var changedFromHz = 0.0
        var changedToHz = 0.0
        os_unfair_lock_lock(&lock)
        let hostNow = CFAbsoluteTimeGetCurrent()
        lastTickHostTime = hostNow
        tickCount &+= 1
        // Snapshot the PTS-refined stream interval under the lock so the
        // main-actor floor re-apply (FIX #1) reads a consistent value without a
        // second lock acquisition. `streamFrameIntervalSeconds` is written on the
        // decode/pacing queue (submit's median refine); this is the only place we
        // read it main-side.
        let refinedIntervalSeconds = streamFrameIntervalSeconds
        if realizedInterval.isFinite, realizedInterval > 0,
           realizedInterval <= Self.maxRealizedTickDeltaSeconds {
            refreshIntervalSumSeconds += realizedInterval
            refreshIntervalSamples &+= 1
            if !refreshIntervalMinSeconds.isFinite || realizedInterval < refreshIntervalMinSeconds {
                refreshIntervalMinSeconds = realizedInterval
            }
            if !refreshIntervalMaxSeconds.isFinite || realizedInterval > refreshIntervalMaxSeconds {
                refreshIntervalMaxSeconds = realizedInterval
            }
        }
        if vsyncInterval.isFinite, vsyncInterval > 0 {
            // Refresh-change edge: compare the NOMINAL derived Hz against the
            // previous tick's. A >1Hz delta (well above vsync-timing noise)
            // flags a real panel-cadence change — the ProMotion ramp 120↔24, a
            // 60↔120 switch, etc. — without firing on realized skip noise.
            if lastRefreshIntervalSeconds.isFinite {
                let prevHz = 1.0 / lastRefreshIntervalSeconds
                let nowHz = 1.0 / vsyncInterval
                if abs(nowHz - prevHz) > 1.0 {
                    refreshChangedSinceRead = true
                    emitRefreshChange = true
                    changedFromHz = prevHz
                    changedToHz = nowHz
                }
            }
            lastRefreshIntervalSeconds = vsyncInterval
        }
        // Tick-deficit service: roll the realized-rate window when due and
        // advance the deficit / floor-violation / warm-handover machines off
        // the MEASURED rates (FramePacer+TickDeficit.swift). Cheap — a couple
        // of compares on most ticks, the full roll at most 4×/s — and it rides
        // the lock we already hold. Events (engage/disengage/NOTICE) are
        // emitted off-lock below.
        let deficitEvents = serviceTickDeficitLocked(now: hostNow)
        os_unfair_lock_unlock(&lock)

        handleTickDeficitEvents(deficitEvents)

        if emitRefreshChange {
            OSSignposter.render.emitEvent(
                "RefreshChanged",
                "fromHz=\(changedFromHz, privacy: .public) toHz=\(changedToHz, privacy: .public)")
        }

        // FIX #1 (re-apply): the present-callback floor is seeded at install from
        // the CONFIGURED fps, but the true cadence is learned from PTS deltas once
        // frames flow (a configured-vs-actual mismatch, or a mid-stream fps change
        // like 60→120). Re-pin the floor from the refined cadence here — on the
        // main actor, where the link lives — when it has drifted past the
        // hysteresis. Cheap: only touches the link object on a real change.
        reapplyPreferredRangeIfNeeded(refinedIntervalSeconds: refinedIntervalSeconds)

        pacingQueue.async { [weak self] in
            self?.releaseDueFrame(targetTimestamp: target, vsyncInterval: vsyncInterval)
        }
    }

    // The FIX #1 floor re-apply (`reapplyPreferredRangeIfNeeded`) lives in
    // FramePacer+FrameRateRange.swift alongside the range builders it calls.
}

/// `@objc` shim that forwards the CADisplayLink callback into a Swift closure.
/// CADisplayLink retains its target, so keeping the proxy separate from
/// `FramePacer` (which `VideoDecoder` retains) avoids a retain cycle and keeps
/// the selector signature trivial. Lives on the main actor — the link fires on
/// the run loop it's added to (`.main`). Declared here with the tick handler it
/// forwards to (moved out of FramePacer.swift for the length limit).
@MainActor
final class DisplayLinkProxy: NSObject {
    private let onTick: (CADisplayLink) -> Void
    init(onTick: @escaping (CADisplayLink) -> Void) {
        self.onTick = onTick
    }
    @objc func tick(_ link: CADisplayLink) {
        onTick(link)
    }
}
