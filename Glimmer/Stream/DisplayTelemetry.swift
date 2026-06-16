//
//  DisplayTelemetry.swift
//
//  Opt-in PRESENT/DISPLAY-side sampler for the telemetry rig (P1). Answers the
//  "is the panel actually in HDR, and is it ramping?" question that the decode
//  side can't: the live EDR headroom (NSScreen.maximumEDR) over time, whether HDR
//  is engaged end-to-end, which screen the stream composites on, and the panel's
//  ProMotion (variable-refresh) capability. EDR + HDR + screen are all main-actor
//  probes (NSScreen / AVSampleBufferDisplayLayer), so they CANNOT be read on the
//  exporter's background queue the way the Wi-Fi sampler is.
//
//  GATING + HOT-PATH SAFETY (load-bearing - see TelemetryExporter.swift):
//    * The MAIN-actor sampler timer is constructed ONLY on the gate-on path (the
//      exporter builds it in `start()` after the gate check). When telemetry is
//      off (default) nothing here is constructed, scheduled, or read: zero cost.
//    * The sampler fires at ~1Hz on the MAIN run loop (NOT a hot path - the decode
//      queue, the pacer's serial queue, and the receive thread are all untouched).
//      Each tick is a handful of cheap NSScreen / layer property reads.
//    * The accumulator is lock-guarded so the background exporter queue can read a
//      tear-free snapshot at its own 1Hz cadence. The lock is on the telemetry
//      path only (the sampler that writes it doesn't exist when off).
//
//  SECRET-FREE: EDR headroom is a float; HDR-engaged + ProMotion are bools; the
//  screen name is the user's OWN display label on their OWN machine (same local
//  trust boundary as the Wi-Fi SSID label). No host identity, keys, or secrets.
//

import Foundation
import os

/// One ~1Hz DISPLAY probe of the live present-side state. Plain value type read
/// by the main-actor sampler from the decoder/screen; folded into the accumulator.
struct DisplayProbe: Sendable {
    /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue` for the screen
    /// the stream composites on. 1.0 = SDR / HDR-off; >1.0 = HDR engaged with that
    /// much headroom. The number that proves the panel is (or isn't) in HDR.
    var edrHeadroom: Double
    /// True iff HDR is active end-to-end (host signalled HDR + 10-bit stream + the
    /// layer is in the PQ colorspace) - the decoder's own `isHDRActive`.
    var hdrEngaged: Bool
    /// The compositing screen's localized name (e.g. a display name). A label so a
    /// multi-display session is attributable to the panel actually showing it.
    var screenName: String
    /// True iff the compositing screen supports ProMotion / variable refresh
    /// (`NSScreen.maximumFramesPerSecond` > 60). Pairs with the pacer's realized
    /// refresh-Hz window to tell "panel can't do 120" from "panel ramped down".
    var proMotionCapable: Bool
    /// The panel's advertised maximum refresh (Hz) - the ProMotion ceiling, so a
    /// realized refresh well under it (the pacer's `refresh_min_hz`) reads as a
    /// genuine ramp-down rather than a slow panel.
    var maxRefreshHz: Int
}

/// Accumulator + main-actor sampler for the DISPLAY signals. Owned by the
/// exporter, constructed only on the gate-on path. The sampler timer runs on the
/// MAIN run loop; the accumulator is lock-guarded for the background read.
///
/// `@unchecked Sendable`: the accumulator is guarded by one `os_unfair_lock`; the
/// timer + its main-actor sampler are confined to the main run loop.
final class DisplayTelemetry: @unchecked Sendable {

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    /// The main-actor probe the sampler calls each tick. Set by the exporter from
    /// the `TelemetrySource`. `@MainActor` because EDR/HDR/screen are main-only.
    /// Returns nil before the layer is bound (no screen to probe yet).
    private let probe: @MainActor @Sendable () -> DisplayProbe?

    /// EDR-headroom accumulators over the window SINCE THE LAST snapshot read
    /// (min/avg/max), so the exporter publishes the trend rather than one
    /// instantaneous value. Reset on read. Guarded by `lock`.
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var edrSum: Double = 0
    private var edrSamples: UInt64 = 0
    private var edrMin: Double = .nan
    private var edrMax: Double = .nan
    /// Latest discrete state (last-writer-wins across the window - these change
    /// rarely, so the most-recent sample is the right gauge). nil before the first
    /// successful probe.
    private var latestState: DisplayProbe?

    /// The 1Hz sampler timer, on the MAIN queue. Built in `start()`.
    private var samplerTimer: DispatchSourceTimer?

    init(probe: @escaping @MainActor @Sendable () -> DisplayProbe?) {
        self.probe = probe
        lock.initialize(to: os_unfair_lock_s())
    }
    deinit { lock.deallocate() }

    /// Arm the ~1Hz main-actor sampler. Called by the exporter on the gate-on
    /// path. The timer is scheduled on the MAIN queue so the EDR/HDR/screen reads
    /// run main-actor-isolated; a generous leeway lets the OS coalesce the wakeup.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let sample = self.probe() else { return }
                self.accumulate(sample)
            }
        }
        samplerTimer = timer
        timer.resume()
    }

    /// Stop the sampler. Synchronous teardown semantics (cancel is immediate).
    func stop() {
        samplerTimer?.cancel()
        samplerTimer = nil
    }

    /// Fold one main-actor probe into the accumulator. On the main run loop.
    private func accumulate(_ sample: DisplayProbe) {
        os_unfair_lock_lock(lock)
        edrSum += sample.edrHeadroom
        edrSamples &+= 1
        if !edrMin.isFinite || sample.edrHeadroom < edrMin { edrMin = sample.edrHeadroom }
        if !edrMax.isFinite || sample.edrHeadroom > edrMax { edrMax = sample.edrHeadroom }
        latestState = sample
        os_unfair_lock_unlock(lock)
    }

    /// Read + RESET the EDR trend window, returning it plus the latest discrete
    /// state. Called once per ~1Hz tick by the exporter on its serial queue (the
    /// only consumer - the window resets on read like the pacer's refresh window).
    /// nil min/avg/max when no probe landed this window (layer not bound yet).
    func snapshotAndReset() -> DisplayTelemetrySnapshot {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        defer {
            edrSum = 0; edrSamples = 0
            edrMin = .nan; edrMax = .nan
        }
        let state = latestState
        guard edrSamples > 0 else {
            return DisplayTelemetrySnapshot(
                edrHeadroomMin: nil, edrHeadroomAvg: nil, edrHeadroomMax: nil, state: state)
        }
        return DisplayTelemetrySnapshot(
            edrHeadroomMin: edrMin.isFinite ? edrMin : nil,
            edrHeadroomAvg: edrSum / Double(edrSamples),
            edrHeadroomMax: edrMax.isFinite ? edrMax : nil,
            state: state)
    }
}

/// One tick's resolved DISPLAY telemetry: the EDR-headroom trend (min/avg/max
/// over the window) + the latest discrete state. Built on the exporter queue from
/// `DisplayTelemetry.snapshotAndReset`; rendered to both wire forms.
struct DisplayTelemetrySnapshot: Sendable {
    var edrHeadroomMin: Double?
    var edrHeadroomAvg: Double?
    var edrHeadroomMax: Double?
    /// Latest HDR-engaged / screen / ProMotion state. nil before the first probe.
    var state: DisplayProbe?
}
