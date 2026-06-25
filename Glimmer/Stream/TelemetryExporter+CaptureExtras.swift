//
//  TelemetryExporter+CaptureExtras.swift
//
//  The Extras sidecar - the pacer/suppression/control/audio-trim counter
//  sample taken once per capture tick - and the cross-tick rate baselines
//  behind it and the pkts/s fold-time fix. Split from
//  TelemetryExporter+Capture.swift - pure move (the FramePacer-split idiom) to
//  keep that file under the file-length budget; the sample, its delta
//  baselines, and the only code that fills it stay together here as one unit.
//  On the exporter's serial `workQueue` - never a hot path.
//

import Foundation

extension TelemetryExporter {

    /// Sample the sidecar Extras (pacer over-target / suppression+gate /
    /// control / audio-trim / rumble / per-socket gap counters + the pacer
    /// tick/release rates) once for this tick. Totals are carried as-is; the
    /// per-second rates derive from deltas against the previous tick exactly
    /// like the other per_s fields, with their cross-tick baselines in
    /// `Self.captureBaselines`. `audioState` is the gauge value `capture()`
    /// read once for this tick (shared with `fillAudio` so one tick's two
    /// sinks can never disagree). On the exporter queue - never a hot path.
    func fillExtras(
        now: DispatchTime, pacing: FramePacer.LivenessSnapshot?,
        audioState: TelemetryCounters.AudioState?
    ) -> TelemetrySnapshot.Extras {
        var extras = TelemetrySnapshot.Extras()
        let baselines = Self.captureBaselines
        let overTargetTotal = counters.pacerOverTargetReleaseTotal.value
        let trimTotal = counters.audioTrimTotal.value
        let rumbleTotal = counters.rumbleEventTotal.value
        extras.pacerOverTargetReleaseTotal = overTargetTotal
        extras.audioTrimTotal = trimTotal
        extras.suppressedDropTotal = counters.suppressedDropTotal.value
        extras.presentSuppressed = counters.presentSuppressed
        extras.ctrlIgnoredTotal = counters.ctrlIgnoredTotal.value
        extras.audioFecMismatchTotal = counters.audioFecMismatchTotal.value
        // The third hidden-window state: gated (decode stopped) vs merely
        // suppressed (decoded, dropped-to-newest) - plus its designed drops.
        extras.decodeGated = counters.decodeGated
        extras.decodeGatedDropTotal = counters.decodeGatedDropTotal.value
        extras.rumbleEventTotal = rumbleTotal
        // Defect sibling of the receipt counter (truncated / slot-out-of-range
        // drops). Total only - ~0 in practice, so a per-second rate would be
        // noise; the NDJSON row gives it time-locality when it ever fires.
        extras.rumbleDroppedInvalidTotal = counters.rumbleDroppedInvalidTotal.value
        // The adaptive playout target rides Extras (the AudioSnapshot type is
        // the snapshot's; this sidecar is where post-snapshot fields live).
        extras.audioPlayoutTargetMs = audioState?.playoutTargetMs
        // Stream ROUTE (stream_link/stream_if): the lock-guarded cached probe
        // value - no syscalls on this tick (re-probes run on the probe queue).
        extras.streamRoute = route.current()
        // Per-socket gap-event totals (video/audio/ENet × 20/50/100ms).
        extras.videoGapOver20msTotal = counters.videoGapOver20msTotal.value
        extras.videoGapOver50msTotal = counters.videoGapOver50msTotal.value
        extras.videoGapOver100msTotal = counters.videoGapOver100msTotal.value
        extras.audioGapOver20msTotal = counters.audioGapOver20msTotal.value
        extras.audioGapOver50msTotal = counters.audioGapOver50msTotal.value
        extras.audioGapOver100msTotal = counters.audioGapOver100msTotal.value
        extras.enetGapOver20msTotal = counters.enetGapOver20msTotal.value
        extras.enetGapOver50msTotal = counters.enetGapOver50msTotal.value
        extras.enetGapOver100msTotal = counters.enetGapOver100msTotal.value
        if let prev = prevCaptureTime {
            let dt = Double(now.uptimeNanoseconds &- prev.uptimeNanoseconds) / 1_000_000_000.0
            if dt > 0.05 {
                extras.pacerOverTargetReleasesPerSecond =
                    Double(overTargetTotal &- baselines.pacerOverTargetReleaseTotal) / dt
                extras.audioTrimsPerSecond = Double(trimTotal &- baselines.audioTrimTotal) / dt
                extras.rumbleEventsPerSecond =
                    Double(rumbleTotal &- baselines.rumbleEventTotal) / dt
                // The liveness totals are PER-PACER (a rebuilt pacer restarts at
                // 0) and the snapshot is nil while the pacer is disabled - emit
                // only across a monotonic window with a baseline, skipping (and
                // re-arming below) on a restart/re-enable edge.
                if let pacing,
                   let prevTicks = baselines.pacerTicksTotal,
                   let prevReleases = baselines.pacerReleasesTotal,
                   pacing.totalTicks >= prevTicks, pacing.totalReleases >= prevReleases {
                    let releasesDelta = pacing.totalReleases &- prevReleases
                    extras.pacerTicksPerSecond = Double(pacing.totalTicks &- prevTicks) / dt
                    extras.pacerReleasesPerSecond = Double(releasesDelta) / dt
                    // Over-target / present ratio: fraction of this window's releases the
                    // gate force-out as over-target. <10% healthy; sustained-high is the
                    // fps≈refresh self-oscillation. Same window's deltas → self-consistent.
                    if releasesDelta > 0 {
                        let overDelta = overTargetTotal &- baselines.pacerOverTargetReleaseTotal
                        extras.pacerOverTargetReleaseRatio = Double(overDelta) / Double(releasesDelta)
                    }
                }
            }
        }
        baselines.pacerOverTargetReleaseTotal = overTargetTotal
        baselines.audioTrimTotal = trimTotal
        baselines.rumbleEventTotal = rumbleTotal
        baselines.pacerTicksTotal = pacing?.totalTicks
        baselines.pacerReleasesTotal = pacing?.totalReleases
        return extras
    }

    /// Sample the ENV-SIGNAL shadow state + the keepalive cadence + the
    /// per-socket pings_sent counters for this tick. Called AFTER
    /// `observeCaptureTick` so the row carries the state the tick produced.
    /// The pings/s rates derive from deltas like every other per_s field, but
    /// re-arm on a counter reset (the loops reset at their own start edges -
    /// a reconnect mid-session restarts them at zero, and a wrapped delta
    /// must not render as a 2^64 spike). On the exporter queue.
    func fillEnvSignal(into extras: inout TelemetrySnapshot.Extras, now: DispatchTime) {
        let controller = EnvSignalController.shared
        let baselines = Self.captureBaselines
        extras.envStateOrdinal = controller.state.rawValue
        extras.envStateLabel = controller.state.label
        extras.envStateChangesTotal = controller.stateChangesTotal.value
        // The cadence the ping loops would honor RIGHT NOW (ms) - makes the
        // conditional keepalive's live regime visible per row, so the cadence
        // can never again live only in a code comment.
        extras.keepaliveIntervalMs = controller.steadyPingInterval() * 1000
        let videoPings = controller.videoPingsSentTotal.value
        let audioPings = controller.audioPingsSentTotal.value
        extras.videoPingsSentTotal = videoPings
        extras.audioPingsSentTotal = audioPings
        if let prev = prevCaptureTime {
            let dt = Double(now.uptimeNanoseconds &- prev.uptimeNanoseconds) / 1_000_000_000.0
            if dt > 0.05 {
                if let prevPings = baselines.videoPingsSentTotal, videoPings >= prevPings {
                    extras.videoPingsPerSecond = Double(videoPings &- prevPings) / dt
                }
                if let prevPings = baselines.audioPingsSentTotal, audioPings >= prevPings {
                    extras.audioPingsPerSecond = Double(audioPings &- prevPings) / dt
                }
            }
        }
        baselines.videoPingsSentTotal = videoPings
        baselines.audioPingsSentTotal = audioPings
    }
}

// MARK: - Extras (the sidecar counter sample)

extension TelemetrySnapshot {
    /// The pacer/suppression/control/audio-trim counters and gauges, sampled
    /// once per capture tick ALONGSIDE the main snapshot and handed to both
    /// renderers as one value - the same read-once / two-sinks discipline as the
    /// snapshot itself (each counter is read exactly once per tick, so the
    /// Prometheus and NDJSON forms of one tick can never disagree). A sidecar
    /// rather than more snapshot fields so the sample, its delta baselines, and
    /// the only code that fills it stay together in this capture unit.
    struct Extras: Sendable {
        /// OVER-TARGET force-release total + per-second rate (see
        /// `TelemetryCounters.pacerOverTargetReleaseTotal`). Zero in steady
        /// state; a per-second SPIKE is the no-network present-stall
        /// self-oscillation signature, observable directly instead of by
        /// absence-of-symptom.
        var pacerOverTargetReleaseTotal: UInt64 = 0
        var pacerOverTargetReleasesPerSecond: Double?
        /// Over-target force-releases ÷ total releases this window. Normalizes the raw
        /// rate against present rate so it reads the same at 60/120/240Hz; sustained-high
        /// is the fps≈refresh self-oscillation. nil when no releases yet.
        var pacerOverTargetReleaseRatio: Double?
        /// Designed drops-to-newest while presentation is suppressed, plus the
        /// live 0/1 suppression gauge that gives them (and every other field on
        /// the same line) their context.
        var suppressedDropTotal: UInt64 = 0
        var presentSuppressed: Bool = false
        /// Unknown inbound control datagrams ignored - the volume signal behind
        /// the once-per-type log suppression.
        var ctrlIgnoredTotal: UInt64 = 0
        /// Designed audio playout-backlog trims (5ms chops) total + per-second
        /// rate; `audio_overrun_total` is the ceiling backstop only.
        var audioTrimTotal: UInt64 = 0
        var audioTrimsPerSecond: Double?
        /// Audio FEC blocks dropped on a parity/data block-size mismatch.
        var audioFecMismatchTotal: UInt64 = 0
        /// Pacer display-link ticks + frame releases per second, from the
        /// liveness totals - the DIRECT measure of display-link callback misses
        /// (previously only reconstructable as rendered+stale).
        var pacerTicksPerSecond: Double?
        var pacerReleasesPerSecond: Double?
        /// DECODE-GATE state (0/1) + the frames quietly dropped while gated -
        /// the third hidden-window state, split from the suppression pair above
        /// so a gated zero-decode span never reads as a decode wedge.
        var decodeGated: Bool = false
        var decodeGatedDropTotal: UInt64 = 0
        /// Host RUMBLE events dispatched to pad actuators, total + per-second
        /// rate - the shipped feature's volume signal (and the input-intensity
        /// correlate for the doze analysis).
        var rumbleEventTotal: UInt64 = 0
        var rumbleEventsPerSecond: Double?
        /// Host RUMBLE events dropped as invalid (truncated payload /
        /// slot-out-of-range) - deposited = events − dropped, so both the
        /// receipt counter's zero AND its nonzero stay provable.
        var rumbleDroppedInvalidTotal: UInt64 = 0
        /// ADAPTIVE PLAYOUT TARGET (ms): what `audio_buffer_fill_ms` is being
        /// steered toward - fill vs target is the cushion judge (base 30 /
        /// cap 150 / ceiling 190). nil until the playout path stamps it.
        var audioPlayoutTargetMs: Double?
        /// Stream ROUTE (`stream_link`/`stream_if`): which interface the
        /// stream's packets actually traverse, from `StreamRouteProbe` - the
        /// PATH truth next to the wifi_* ASSOCIATION truth. nil only before
        /// the probe's first sample.
        var streamRoute: StreamRouteSnapshot?
        /// Per-socket inter-arrival GAP-EVENT totals (video/audio/ENet ×
        /// 20/50/100ms) - the honest link-health counters the jitter EWMA and
        /// windowed gap gauges are blind to. See `TelemetryCounters`.
        var videoGapOver20msTotal: UInt64 = 0
        var videoGapOver50msTotal: UInt64 = 0
        var videoGapOver100msTotal: UInt64 = 0
        var audioGapOver20msTotal: UInt64 = 0
        var audioGapOver50msTotal: UInt64 = 0
        var audioGapOver100msTotal: UInt64 = 0
        var enetGapOver20msTotal: UInt64 = 0
        var enetGapOver50msTotal: UInt64 = 0
        var enetGapOver100msTotal: UInt64 = 0
        /// ROLLING 60s latency window (current − the cumulative snapshot from
        /// 60 ticks ago) for the NDJSON `_60s` percentile fields - the "is
        /// bad" view next to the cumulative "was bad" one. nil when the
        /// latency rig has no data this tick.
        var latencyRolling60s: LatencyHistogramSnapshot?
        /// ENV-SIGNAL shadow state (0 clear / 1 caution / 2 distress) + label
        /// + transition count, the LIVE keepalive cadence (ms), and the
        /// per-socket pings_sent counters + per-second rates - the cadence
        /// judge for evaluating keepalive-interval changes from data. nil only
        /// before the controller's first fed tick.
        var envStateOrdinal: Int?
        var envStateLabel: String?
        var envStateChangesTotal: UInt64?
        var keepaliveIntervalMs: Double?
        var videoPingsSentTotal: UInt64?
        var audioPingsSentTotal: UInt64?
        var videoPingsPerSecond: Double?
        var audioPingsPerSecond: Double?
    }
}

// MARK: - Cross-tick rate baselines

extension TelemetryExporter {
    /// Cross-tick baselines for the Extras per-second rates and the pkts/s
    /// fold-time fix: the previous totals, plus the capture instant the packet
    /// totals last advanced. `startCaptureTimer()` installs a fresh instance so
    /// every session starts from zero - the same per-session lifetime as the
    /// exporter's stored prev*-totals. `nonisolated(unsafe)`: mutated only on
    /// the exporter's serial `workQueue` (timer start + each capture tick), and
    /// exactly one exporter exists at a time (one streaming session) - the same
    /// single-writer confinement discipline as the engine's other
    /// `nonisolated(unsafe)` slots.
    final class CaptureBaselines {
        var pacerOverTargetReleaseTotal: UInt64 = 0
        var audioTrimTotal: UInt64 = 0
        var rumbleEventTotal: UInt64 = 0
        /// ROLLING 60s latency ring (per-session, like every baseline here -
        /// a fresh instance per `startCaptureTimer()` keeps the window from
        /// straddling a session boundary). Exporter-queue-confined.
        let latencyRolling = LatencyRollingWindow()
        /// Pacer liveness totals from the PREVIOUS tick. Optional: nil while the
        /// pacer is disabled (no snapshot), so the first tick after a re-enable
        /// arms a fresh baseline instead of emitting a bogus whole-total spike.
        var pacerTicksTotal: UInt64?
        var pacerReleasesTotal: UInt64?
        /// Capture instant the video / audio packet totals last ADVANCED (the
        /// receive paths fold them once per metrics window, not per tick) - the
        /// dt base that makes pkts/s the true wire rate. nil until armed.
        var videoPacketsCapturedAt: DispatchTime?
        var audioPacketsCapturedAt: DispatchTime?
        /// Previous-tick pings_sent totals (per socket). Optional like the
        /// pacer pair: nil (or a smaller current total) re-arms the baseline
        /// instead of emitting a wrapped-delta spike across a ping-loop
        /// restart (the counters reset at their own loop-start edges).
        var videoPingsSentTotal: UInt64?
        var audioPingsSentTotal: UInt64?
    }
    nonisolated(unsafe) static var captureBaselines = CaptureBaselines()
}
