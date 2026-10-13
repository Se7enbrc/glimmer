// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamSession+StatsOverlayTimer.swift
//
//  The 4 Hz stats-overlay timer; its body is `StatsOverlayRefresh.tick`, a function
//  of the decoder, overlay and pill, so tests drive one tick at a time.
//

import GlimmerEngine
import Foundation
import AppKit
import os

extension StreamSession {

    /// Refresh the overlay at 4 Hz. Capture FPS rolls across four samples;
    /// pipeline rates retain their independent one-second measurement window.
    func startStatsOverlayTimer(
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind>,
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds
    ) async {
        let dec = videoDecoder
        let win = window
        let inp = input
        await MainActor.run {
            self.statsOverlayTimer?.invalidate()
            // Scheduled inside `MainActor.run`, so it fires on the main run loop
            // where the decoder and window live.
            let clock = self.clock
            let refresh = StatsOverlayRefresh(now: { Double(clock.uptimeNanos()) / 1_000_000_000 })
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak dec, weak win, weak inp] _ in
                MainActor.assumeIsolated {
                    guard let dec, let win else { return }
                    refresh.tick(
                        dec: dec, overlay: win.statsOverlay, banner: win.networkBanner, input: inp,
                        rows: statsRowsProvider, thresholds: statsThresholdsProvider,
                        visible: win.window.occlusionState.contains(.visible))
                }
            }
            // 30 ms lets the run loop coalesce the timer, well under half the interval.
            timer.tolerance = 0.03
            self.statsOverlayTimer = timer
        }
    }

    /// One snapshot for the menu bar's Connection Details, plus the overlay state.
    func menuBarDetails() async
        -> (snapshot: StreamStatsSnapshot, overlayShown: Bool, resolution: (width: Int, height: Int))? {
        guard let dec = videoDecoder else { return nil }
        return await MainActor.run {
            var snap = dec.statsSnapshot(minWindowSeconds: 1.0)
            if let rtt = dec.telemetryEstimatedRtt() { snap.rttMs = rtt.rttMs }
            return (snap, dec.statsOverlayEnabled, (Int(dec.streamWidth), Int(dec.streamHeight)))
        }
    }

    func setStatsOverlayCorner(_ corner: StatsOverlayCorner) async {
        guard let win = window else { return }
        await MainActor.run { win.statsOverlay.corner = corner }
    }

    /// The current session's overlay, the same switch the keyboard toggle drives.
    func setStatsOverlay(_ shown: Bool) async {
        guard let dec = videoDecoder else { return }
        await MainActor.run { dec.statsOverlayEnabled = shown }
    }
}

/// One 4 Hz overlay refresh, with the per-tick memory the pill and audit carry.
/// Runs on the main run loop and reads only cached ~1s windows or cheap gauges.
@MainActor
final class StatsOverlayRefresh {
    // Capture FPS rolls across ticks; raw pipeline rates keep their own 1 s window.
    static let fpsWindowSeconds = 1.0
    let hitch: PerceivedHitchBox
    private let gateAudit: LinkGateAuditBox
    private let history = StreamHistoryFeed()

    init(now: @escaping @MainActor () -> CFTimeInterval = CACurrentMediaTime) {
        hitch = PerceivedHitchBox(now: now)
        gateAudit = LinkGateAuditBox(now: now)
    }

    /// The pill updates every tick, HUD or not; the HUD's enrichment, row set and
    /// thresholds are read only while it's shown, so a Settings flip lands next tick.
    func tick(
        dec: VideoDecoder, overlay: StatsOverlayLayer, banner: StreamBannerLayer, input: InputForwarder?,
        rows: @MainActor () -> Set<StatsRow.Kind>, thresholds: @MainActor () -> StatsThresholds,
        visible: Bool = true
    ) {
        let rtt = dec.telemetryEstimatedRtt()
        gateAudit.tick(streamRtt: rtt?.rttMs)
        var snap = dec.statsSnapshot(minWindowSeconds: Self.fpsWindowSeconds)
        history.tick(mbps: snap.measuredBitrateMbps, fps: snap.receivedFps,
                     rttMs: rtt?.rttMs)
        // Perceived present hitching, not env_state (link contention anti-correlates with felt stutter).
        banner.setSustained(hitch.perceivedHitch(snap: snap), text: "Stream stuttering")
        guard visible, dec.statsOverlayEnabled else { return }
        // The decoder's live backend survives a silent reconnect; nil renders "-".
        if let rttInfo = rtt {
            snap.rttMs = rttInfo.rttMs
            snap.rttVarianceMs = rttInfo.varianceMs
        }
        // Fine RFC 3550 jitter beats whole-ms RTT variance, which reads a clean link as 0 ms.
        let fineJitter = TelemetryCounters.shared.recvJitterMs
        if fineJitter > 0 { snap.jitterMs = fineJitter }
        let mac = MacSystemStats.shared.snapshot()
        snap.macBatteryPercent = mac.batteryPercent
        snap.macBatteryCharging = mac.batteryCharging
        snap.macCpuPercent = mac.cpuPercent
        snap.macRamPercent = mac.ramPercent
        if let input, let batt = input.currentControllerBattery() {
            snap.controllerBatteryPercent = batt.percent
            snap.controllerBatteryCharging = batt.charging
        }
        overlay.videoSize = CGSize(width: CGFloat(dec.streamWidth), height: CGFloat(dec.streamHeight))
        overlay.update(snapshot: snap, enabled: rows(), targetFps: Double(dec.streamFps), thresholds: thresholds())
        // The decoder samples the picture under the column for the HUD's ink.
        dec.hudBackdropRect = overlay.backdropSampleRect
        if let luminance = dec.hudBackdropLuminance { overlay.updateBackdropLuminance(luminance) }
    }
}

/// One-shot, ~10 s into the stream: grade the connect-time RTT prior against
/// what the stream itself measures, so every session leaves a verdict in the log.
@MainActor
final class LinkGateAuditBox {
    private var done = false
    private let now: @MainActor () -> CFTimeInterval
    private let firstTime: CFTimeInterval
    private let settleSeconds: CFTimeInterval = 10

    init(now: @escaping @MainActor () -> CFTimeInterval) {
        self.now = now
        firstTime = now()
    }

    func tick(streamRtt: Double?) {
        guard !done, now() - firstTime >= settleSeconds else { return }
        guard let streamRtt, let gate = StreamPathMTU.currentGateDecision, let assumed = gate.rtt else { return }
        done = true
        let ratio = streamRtt > 0 ? assumed.steadyMs / streamRtt : 0
        Diag.notice(
            "Link gate audit: assumed steady \(String(format: "%.0f", assumed.steadyMs)) ms "
            + "(\(assumed.count) samples\(gate.rttPreLaunch ? " before launch" : "")), "
            + "stream measures \(String(format: "%.1f", streamRtt)) ms at 10 s "
            + "(\(String(format: "%.1fx", ratio))) - asked \(gate.askedBitrateKbps / 1000) "
            + "of \(gate.configuredBitrateKbps / 1000) Mbps.", "Stream")
    }
}

/// Carries per-second-rate baselines for the perceived-hitch pill across the
/// 4Hz overlay ticks. MainActor-isolated: only ever touched from the timer body.
@MainActor
final class PerceivedHitchBox {
    private let now: @MainActor () -> CFTimeInterval
    private var prevLate: UInt64 = 0
    private var prevGap: UInt64 = 0
    private var prevTime: CFTimeInterval = 0
    private var firstTime: CFTimeInterval = 0

    /// Stream seconds before the pill may show. A title's launch (loading +
    /// display-mode negotiation) stutters briefly; without this the pill flashes
    /// the instant a game starts. ~6s covers the launch transient.
    private let graceSeconds: CFTimeInterval = 6.0

    init(now: @escaping @MainActor () -> CFTimeInterval) { self.now = now }

    /// True when the PRESENT path drops frames the user would feel. Render-gap
    /// (decoded-but-never-rendered) catches sustained starvation; the late-drop
    /// burst is gated on a PERCEIVED GAP (renderer showed nothing fresh) so healthy
    /// wifi jitter - drop-to-newest that DOES present - no longer mis-fires.
    /// Stale-repeats and cadence stay excluded (normal at fps<refresh); the
    /// banner's leaky integrator debounces; deltas guard a reconnect reset.
    func perceivedHitch(snap: StreamStatsSnapshot) -> Bool {
        let now = now()
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
