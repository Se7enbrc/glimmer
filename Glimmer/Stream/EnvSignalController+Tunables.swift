//
//  EnvSignalController+Tunables.swift
//
//  The env-signal layer's VOCABULARY and DIALS: the reconciler kill-switch,
//  the link-class + state enums (whose ordinals/rawValues are the wire and
//  persistence labels), the FecHeadroomController contract numbers the
//  sustained/hysteresis guarantees are expressed in, the reconciler decision
//  mapping constants, and the conditional-keepalive cadence dials. Split out
//  of EnvSignalController.swift (pure move) to keep each unit under the
//  length limit; see that file for the header contract, the lock-guarded
//  outputs, and the keepalive actuation that reads these.
//
//  Everything here is a compile-time constant or a plain value type -
//  immutable, so it is concurrency-safe by construction and callable from
//  any thread.
//

import Foundation

extension EnvSignalController {

    // MARK: - Reconciler kill-switch (the A/B flag)

    /// When TRUE (the default) the unified LINK RECONCILER is live: this
    /// controller publishes ONE jitter→headroom decision (`headroomLevel` +
    /// `smoothedJitterMs`) and both jitter-racing actuators - the FramePacer
    /// adaptive depth and the FecHeadroomController reorder-hold - CONSUME it
    /// instead of each reading `TelemetryCounters.recvJitterMs` independently.
    ///
    /// When FALSE both actuators fall back to their CURRENT self-deciding
    /// behavior, unchanged - the old code paths stay reachable behind this flag,
    /// so the build compiles to "identical to today" with the flag off. A simple
    /// process-global flag, read on the actuators' own ticks. A compile-time
    /// constant (`let`): there is no runtime writer, so the A/B is a flip-and-
    /// rebuild dial - concurrency-safe by immutability, no `nonisolated(unsafe)`.
    static let reconcilerEnabled = true

    // MARK: - Link class

    /// The stream route class. `rawValue` IS the wire/persistence label
    /// (`StreamRouteProbe.classify`, the `stream_link` field) - used ONLY at that
    /// boundary; gating logic compares the enum. Unknown label → `.unknown` (fail safe).
    enum LinkClass: String {
        case wired, wifi, tunnel, unknown
        init(label: String?) { self = label.flatMap(LinkClass.init(rawValue:)) ?? .unknown }
    }

    // MARK: - State

    /// The three-level link-condition state. Ordinals are stable (exported as
    /// the `env_state` gauge): 0 clear, 1 caution, 2 distress.
    enum EnvState: Int, Sendable {
        /// No sustained evidence - the baseline. Wired routes are pinned here.
        case clear = 0
        /// Sustained degradation evidence (co-gaps and/or a radio sag): the
        /// "arm the gentle compensations" tier.
        case caution = 1
        /// Sustained SEVERE evidence (>100ms co-gaps): the link is actively
        /// hurting delivery. Excluded from present-path quality scorecards.
        case distress = 2

        var label: String {
            switch self {
            case .clear: return "clear"
            case .caution: return "caution"
            case .distress: return "distress"
            }
        }
    }

    // MARK: - Tunables (the FecHeadroomController contract numbers)

    /// Capture ticks folded into one evidence window (~2s at the exporter's
    /// 1Hz - the same window size the FEC headroom controller trends on).
    static let ticksPerWindow = 2
    /// Consecutive evidence windows before an escalation when the run carried
    /// CO-GAP evidence (~6s) - actual delivery impact earns the faster entry.
    static let escalateWindows = 3
    /// Consecutive evidence windows for a PURE-RADIO run (~10s): a signal sag
    /// that isn't hurting delivery yet must sustain longer before it counts.
    static let radioOnlyEscalateWindows = 5
    /// Consecutive quiet windows per ONE de-escalation step (~30s dwell).
    /// Asymmetric with entry (slow out, one step at a time) so the machine
    /// bleeds out smoothly and can never flap around a noisy boundary.
    static let quietWindowsPerStepDown = 15
    /// Minimum windows between ANY two level changes (the final anti-flap
    /// floor, same role as FecHeadroomController.minDwellWindows).
    static let minDwellWindows = 2
    /// Escalate radio threshold: RSSI at or below session-p50 minus this many
    /// dB counts as degraded. Relax needs to clear a SMALLER deficit - the
    /// gap between the two is the dead band that prevents flapping.
    static let rssiDegradeDb = 8
    static let rssiRelaxDb = 6
    /// Escalate radio threshold: tx-rate at or below this fraction of the
    /// session p95 counts as degraded; relax requires recovering above the
    /// (higher) relax fraction.
    static let txRateDegradeFraction = 0.5
    static let txRateRelaxFraction = 0.6
    /// Radio samples (~seconds) before the session-relative baseline is
    /// trusted: no radio evidence can fire in the first ~minute, so a cold
    /// session can never escalate off an unwarmed percentile.
    static let radioBaselineMinSamples = 60

    // MARK: - Reconciler decision tunables

    /// Maximum published headroom level. Matches FecHeadroomController.maxLevel
    /// (3 = (48ms − 24ms) / 8ms) so a clean link→0 and full escalation→3 maps
    /// one-to-one onto the FEC reorder-hold steps; the pacer depth maps
    /// `targetDepth + level`, capped at `maxTargetDepth` (level 3 → depth 4,
    /// under the depth-5 cap). The reconciler can never publish a level the FEC
    /// actuator's `maxHoldUs` cap or the pacer's `maxTargetDepth` cap couldn't
    /// already reach on its own.
    static let maxHeadroomLevel = FecHeadroomController.maxLevel
    /// Per-jitter-ms-of-excess that buys one headroom level, mirroring the FEC
    /// soft `jitterEscalateMs` ladder: jitter at/under `headroomJitterDeadZoneMs`
    /// → level 0 (REST); each `headroomJitterMsPerLevel` of excess above it adds
    /// one level. Bridges the OBSERVE jitter trend into the shared level both
    /// actuators consume.
    static let headroomJitterDeadZoneMs = FecHeadroomController.jitterRelaxMs
    static let headroomJitterMsPerLevel = FecHeadroomController.stepUs == 0 ? 8.0
        : Double(FecHeadroomController.stepUs) / 1_000.0
    /// EWMA weight smoothing the per-window recv-jitter that drives the published
    /// headroom - copied from FecHeadroomController.jitterBaseEwmaWeight so the
    /// FEC actuator's jitter-scaled base is byte-identical whether it consumes
    /// the published value or (flag off) smooths its own.
    static let jitterBaseEwmaWeight = FecHeadroomController.jitterBaseEwmaWeight

    // MARK: - Keepalive cadence dials

    /// FAST cadence = the validated 75ms anti-doze dial (verdict KEEP - the
    /// WHY/JUDGE/COST live on that constant).
    static let fastPingIntervalSeconds = UdpPinger.steadyPingIntervalSeconds
    /// RELAXED cadence = upstream moonlight's 500ms keepalive - the proven-
    /// sufficient rate wherever NIC doze is not in play.
    static let relaxedPingIntervalSeconds = UdpPinger.relaxedPingIntervalSeconds
    /// Input-silence gate for "input-idle": NIC power-save doze sets in well
    /// under a second after uplink traffic stops, and active-play inter-input
    /// gaps are sub-100ms - 1s cleanly separates the regimes (deliberately
    /// NOT TelemetryCounters.idleGapSeconds, which is a 2s telemetry-UX edge,
    /// not a radio constant).
    static let keepaliveIdleSeconds = 1.0
    /// How long a published stream_link stays trusted without a fresh feed.
    /// The exporter feeds every ~1s while telemetry is on; once feeds stop
    /// (telemetry off, session over) the route claim expires and the cadence
    /// falls back to the validated fast dial - stale knowledge never relaxes
    /// the countermeasure.
    static let routeTrustHorizonNanos: UInt64 = 30_000_000_000
    /// Wi-Fi keepalive WARM-UP window (ns), measured from the ping-loop
    /// bring-up edge (stream start or silent reconnect). For its duration the
    /// wifi branch pins the FAST cadence unconditionally - ignoring the
    /// "active input holds the radio awake" relaxation - because in a stream's
    /// opening stretch that assumption is measurably false: the AP-side
    /// power-save / aggregation ramp gaps the DOWNLINK even with steady
    /// uplink input traffic (2026-08-17, 6GHz at -43dBm: 36 gaps >100ms in
    /// the first 30s while the cadence flapped fast↔relaxed, then ZERO for
    /// the next 150s once fast pings pinned - the clear→gap→caution→fast→
    /// clear→relaxed limit cycle). 90s matches the independently measured
    /// ~80s wifi warm-up the audio floor-learning gate already covers
    /// (AudioDecoder+Meter.startupFloorGateNanos, measured 2026-07-21).
    /// Cost: ~13Hz of tiny UDP pings for 90s - negligible airtime.
    static let wifiWarmupPingNanos: UInt64 = 90_000_000_000
    /// Send-due slop: the ping threads wake on the fast quantum and gate the
    /// send on elapsed-since-last-ping; without a few ms of slop a 74.9ms
    /// wake against a 75ms interval would skip to 150ms cadence.
    static let pingDueSlopSeconds = 0.005

    /// Nanoseconds after which a ping is due for `interval` (slop applied).
    /// Shared by both receive-loop ping threads so the due math can't drift.
    static func dueNanos(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval - pingDueSlopSeconds) * 1_000_000_000)
    }
}
