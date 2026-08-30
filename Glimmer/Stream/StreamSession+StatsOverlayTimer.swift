//
//  StreamSession+StatsOverlayTimer.swift
//
//  The 4 Hz stats-overlay update timer and the perceived-hitch pill's
//  cross-tick rate memory. Split out of StreamSession+Watchdog.swift (pure
//  move) to keep each unit under the length limit; see StreamSession.swift for
//  the actor's stored state and lifetime contract, and StreamSession+Watchdog /
//  +FrameWatchdog for the self-heal timers this one sits alongside.
//
//  The timer body runs on the MAIN run loop and touches only main-actor state
//  (the decoder, the window's overlay + banner layers), so it reads the live
//  snapshot directly rather than hopping actors. Everything it reads is either
//  a cached ~1s stats window or a cheap gauge - never a hot path.
//

import Foundation
import AppKit
import os

extension StreamSession {

    /// Build + install the 4 Hz overlay-update timer (latency rows live; FPS
    /// averaging window decoupled to ~1s via `statsSnapshot(minWindowSeconds:)`).
    /// Captures the decoder and window by weak reference; if either is torn down
    /// between ticks, the timer body no-ops on the next fire and we wait for
    /// `stop()` to invalidate the timer for real.
    func startStatsOverlayTimer(
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind>,
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds
    ) async {
        // Build a snapshot closure with weak refs. The timer fires on the
        // main run loop; the backend's RTT estimate is safe to read from any
        // thread while the connection is up, so the main thread is fine.
        let dec = videoDecoder
        let win = window
        let inp = input
        await MainActor.run {
            self.statsOverlayTimer?.invalidate()
            // `Timer.scheduledTimer` registers the timer on the *current*
            // run loop. Since we're inside `MainActor.run`, that's the main
            // run loop - exactly where the overlay layer + decoder live.
            // The block closure runs synchronously on the main thread when
            // the timer fires, so `dec` and `win` (both `@MainActor`-
            // isolated) are safe to touch directly.
            // 4 Hz (250ms) overlay refresh so the latency / jitter / RTT rows
            // feel LIVE - at 1Hz a momentary spike was a quarter-second stale.
            // The FPS averaging window stays DECOUPLED from the tick:
            // `statsSnapshot(minWindowSeconds:)` keeps FPS / bitrate / cadence
            // on a ~1s average (the collector slides + recomputes the window
            // only once 1s of data accrues, serving the cached last-good average
            // between), so 4Hz does NOT reintroduce the ±4fps boundary noise a
            // literal 250ms window would; the live gauges refresh at full 4Hz.
            let overlayFpsWindowSeconds = 1.0
            // Per-second-rate baselines for the perceived-hitch pill, carried
            // across ticks. Reference type so the timer closure mutates one box.
            let hitchBox = PerceivedHitchBox()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak dec, weak win, weak inp] _ in
                MainActor.assumeIsolated {
                    guard let dec, let win else { return }
                    // Cheap stats read FIRST (cached ~1s window) so the pill
                    // works with the HUD off - the expensive host/controller
                    // probes below stay gated on `statsOverlayEnabled`.
                    var snap = dec.statsSnapshot(minWindowSeconds: overlayFpsWindowSeconds)
                    // Auto pill, independent of the stats-HUD toggle so a
                    // degrading PRESENT path reaches the user with the HUD off.
                    // Drives off PERCEIVED present-hitching (render-gap / stale
                    // repeats / late drops), not env_state (which measures link
                    // contention and anti-correlates with felt stutter).
                    let composite = hitchBox.perceivedHitch(snap: snap)
                    win.networkBanner.setSustained(composite, text: "Stream stuttering")
                    // Cheap early-out: if the overlay is hidden, skip the
                    // expensive enrichment + HUD render. The decoder's collectors
                    // keep ticking so a re-enable shows fresh numbers immediately.
                    guard dec.statsOverlayEnabled else { return }
                    // Read RTT through the decoder's LIVE backend (re-pointed on
                    // reconnect) so it survives a silent reconnect; nil when not
                    // connected (transient drop / native stub) → row renders "-".
                    if let rttInfo = dec.telemetryEstimatedRtt() {
                        // RTT is now measured from a HIGH-RES local monotonic clock
                        // (fractional ms, EWMA as Double) - no widen/truncation; the
                        // overlay shows true sub-ms latency uniformly with jitter.
                        snap.rttMs = rttInfo.rttMs
                        snap.rttVarianceMs = rttInfo.varianceMs
                    }
                    // Jitter: prefer the FINE RFC-3550 smoothed receive jitter
                    // (already Double, ~0.09ms on a clean wired link) over the
                    // whole-ms ENet RTT variance - an integer variance rounds a
                    // clean link to "0 ms" (no signal). `recvJitterMs` is the same
                    // gauge the telemetry exporter ships, refreshed by the RTP
                    // receive path. Falls back to the RTT-variance proxy
                    // (rttVarianceMs, set above) only when no fine jitter has been
                    // measured yet (gauge still 0 / pre-first-sample) - the row
                    // resolves `jitterMs ?? rttVarianceMs`.
                    let fineJitter = TelemetryCounters.shared.recvJitterMs
                    if fineJitter > 0 {
                        snap.jitterMs = fineJitter
                    }
                    // Host-Mac vitals (battery, CPU%, RAM%). Probes are
                    // cheap (IOPS + two host_statistics calls) but we
                    // still gate on the overlay being on so a disabled
                    // overlay doesn't keep the sampler ticking.
                    let mac = MacSystemStats.shared.snapshot()
                    snap.macBatteryPercent = mac.batteryPercent
                    snap.macBatteryCharging = mac.batteryCharging
                    snap.macCpuPercent = mac.cpuPercent
                    snap.macRamPercent = mac.ramPercent
                    // Connected controller battery (first attached pad that
                    // reports one). Read live each tick so it tracks a pad
                    // that connects/disconnects mid-stream.
                    if let inp, let batt = inp.currentControllerBattery() {
                        snap.controllerBatteryPercent = batt.percent
                        snap.controllerBatteryCharging = batt.charging
                    }
                    // Read the enabled row set live every tick so a
                    // Settings flip (preset change, custom checkbox
                    // toggle) takes effect on the next 1Hz refresh - no
                    // need to restart the stream to see the new layout.
                    // The provider closure resolves through
                    // AppModel.effectiveStatsRows, which routes
                    // through statsOverlayPreset + statsOverlayCustomRows.
                    let enabled = statsRowsProvider()
                    let thresholds = statsThresholdsProvider()
                    win.statsOverlay.update(
                        snapshot: snap,
                        enabled: enabled,
                        targetFps: Double(dec.streamFps),
                        thresholds: thresholds)
                }
            }
            // Tolerance saves the OS some power - at 4 Hz a 30 ms tolerance is
            // invisible to the user but lets the run loop coalesce the timer.
            // Under half the 250ms interval so a coalesced tick can't drift
            // into the next one.
            timer.tolerance = 0.03
            self.statsOverlayTimer = timer
        }
    }
}

/// Carries per-second-rate baselines for the perceived-hitch pill across the
/// 4Hz overlay ticks. MainActor-isolated: only ever touched from the timer body.
@MainActor
private final class PerceivedHitchBox {
    private var prevLate: UInt64 = 0
    private var prevGap: UInt64 = 0
    private var prevTime: CFTimeInterval = 0
    private var firstTime: CFTimeInterval = 0

    /// Stream seconds before the pill may show. A title's launch (loading +
    /// display-mode negotiation) stutters briefly; without this the pill flashes
    /// the instant a game starts. ~6s covers the launch transient.
    private let graceSeconds: CFTimeInterval = 6.0

    /// True when the PRESENT path drops frames the user would feel. Render-gap
    /// (decoded-but-never-rendered) catches sustained starvation; the late-drop
    /// burst is gated on a PERCEIVED GAP (renderer showed nothing fresh) so healthy
    /// wifi jitter - drop-to-newest that DOES present - no longer mis-fires.
    /// Stale-repeats and cadence stay excluded (normal at fps<refresh); the
    /// banner's leaky integrator debounces; deltas guard a reconnect reset.
    func perceivedHitch(snap: StreamStatsSnapshot) -> Bool {
        let now = CACurrentMediaTime()
        if firstTime == 0 { firstTime = now }
        let dt = prevTime > 0 ? now - prevTime : 0.25
        prevTime = now

        let late = snap.presentationLateDrops ?? 0
        let lateRate = (dt > 0 && late >= prevLate) ? Double(late - prevLate) / dt : 0
        prevLate = late
        let gap = snap.presentationGaps ?? 0
        let gapped = gap > prevGap   // a real gap (renderer showed nothing) this tick
        prevGap = gap

        if now - firstTime < graceSeconds { return false }

        var hitch = false
        // Real frame loss: decoded but never rendered (sustained starvation).
        if let decoded = snap.decodedFps, let rendered = snap.renderedFps, decoded > 0 {
            if (decoded - rendered) / decoded > 0.18 { hitch = true }
        }
        // Late-drop burst - but only when the renderer actually showed nothing
        // fresh. A drop-to-newest that catches up isn't a felt stutter.
        if lateRate > 12.0 && gapped { hitch = true }
        return hitch
    }
}
