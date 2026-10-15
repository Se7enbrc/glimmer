// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension EnvSignalController {

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
    package enum EnvState: Int, Sendable {
        /// No sustained evidence - the baseline. Wired routes are pinned here.
        case clear = 0
        /// Sustained degradation evidence (co-gaps and/or a radio sag): the
        /// "arm the gentle compensations" tier.
        case caution = 1
        /// Sustained SEVERE evidence (>100ms co-gaps): the link is actively
        /// hurting delivery. Excluded from present-path quality scorecards.
        case distress = 2

        package var label: String {
            switch self {
            case .clear: return "clear"
            case .caution: return "caution"
            case .distress: return "distress"
            }
        }
    }

    // MARK: - Tunables (the sustained/hysteresis contract numbers)

    /// Session ticks folded into one evidence window: the tick is 2 s, the cadence the RTP
    /// receive path refreshes `recvJitterMs` on, so one tick is one window.
    static let ticksPerWindow = 1
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
    /// floor on top of the asymmetric run counters).
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
    /// Radio samples (2 s ticks) before the session-relative baseline is trusted: no radio
    /// evidence can fire in the first ~minute, so a cold session never escalates off an
    /// unwarmed percentile.
    static let radioBaselineMinSamples = 30

    // MARK: - Jitter/loss window thresholds

    /// A window is jitter-degraded at or past any escalate line and jitter-quiet
    /// only under all three relax lines; the gap between them is the dead band
    /// that keeps a value on the boundary from flapping.
    static let jitterEscalateMs = 8.0
    static let jitterRelaxMs = 4.0
    static let outOfOrderEscalate: UInt64 = 6
    static let outOfOrderRelax: UInt64 = 2
    static let retransmitEscalate: UInt64 = 4
    static let retransmitRelax: UInt64 = 1

    // MARK: - Reconciler decision tunables

    /// Maximum published headroom level. The pacer depth maps `targetDepth +
    /// level`, capped at `maxTargetDepth` (level 3 → depth 4, under the depth-5
    /// cap), so the reconciler can never ask for more than the cap allows.
    static let maxHeadroomLevel = 3
    /// Jitter at/under `headroomJitterDeadZoneMs` → level 0 (REST); each
    /// `headroomJitterMsPerLevel` of excess above it adds one level. Bridges the
    /// jitter trend into the shared level the consumers read.
    static let headroomJitterDeadZoneMs = jitterRelaxMs
    static let headroomJitterMsPerLevel = 8.0
    /// EWMA weight smoothing the per-window recv-jitter behind the published
    /// headroom, so one noisy window can't yank the level.
    static let jitterBaseEwmaWeight = 0.3

    // MARK: - Keepalive cadence dials

    /// FAST cadence = the validated 75ms anti-doze dial (verdict KEEP - the
    /// WHY/JUDGE/COST live on that constant).
    static let fastPingIntervalSeconds = UdpPinger.steadyPingIntervalSeconds
    /// RELAXED cadence = upstream moonlight's 500ms keepalive - the proven-
    /// sufficient rate wherever NIC doze is not in play.
    static let relaxedPingIntervalSeconds = UdpPinger.relaxedPingIntervalSeconds
    /// One second separates active sub-100ms input gaps from radio doze; the telemetry idle gap
    /// is a different two-second UX threshold. A fresh connection with no input remains idle.
    package static let keepaliveIdleSeconds = 1.0
    /// How long a published stream_link stays trusted without a fresh feed. The session feeds
    /// every 2 s; once feeds stop the route claim expires and the cadence falls back to the
    /// validated fast dial - stale knowledge never relaxes the countermeasure.
    static let routeTrustHorizonNanos: UInt64 = 30_000_000_000
    /// Pin fast pings for90s after every flow:6GHz/-43dBm measurements (2026-08-17) saw36 gaps
    /// >100ms in30s while cadence flapped, then zero in150s pinned fast. The audio floor already
    /// covers an independently measured~80s warmup;~13Hz tiny UDP pings cost negligible airtime.
    static let wifiWarmupPingNanos: UInt64 = 90_000_000_000
    /// Send-due slop: the ping threads wake on the fast quantum and gate the
    /// send on elapsed-since-last-ping; without a few ms of slop a 74.9ms
    /// wake against a 75ms interval would skip to 150ms cadence.
    static let pingDueSlopSeconds = UdpPinger.pingDueSlopSeconds

    /// Nanoseconds after which a ping is due for `interval` (slop applied).
    /// Shared by both receive-loop ping threads so the due math can't drift.
    static func dueNanos(for interval: TimeInterval) -> UInt64 {
        UdpPinger.dueNanos(for: interval)
    }
}
