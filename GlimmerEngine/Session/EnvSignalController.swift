// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Process-global env-signal state machine + the conditional-keepalive dial. Fed by every
/// session's 2 s tick; read by the RTP ping loops and the pacer. `@unchecked Sendable`:
/// cross-thread fields are lock-guarded, evidence state is `feedQueue`-confined.
package final class EnvSignalController: @unchecked Sendable {
    package static let shared = EnvSignalController(transportRoute: .shared, pacerHeadroom: .shared)
    // Module-internal (not private) so the transition breadcrumb in
    // EnvSignalController+Evidence.swift logs under the same category.
    static let cat = "EnvSignal"

    // Link/state vocabulary and unchanged measured thresholds live in +Tunables.

    // MARK: - Cross-thread outputs (lock-guarded)

    let transportRoute: TransportRoute

    let pacerHeadroom: PacerHeadroom

    package init(transportRoute: TransportRoute = TransportRoute(), pacerHeadroom: PacerHeadroom = PacerHeadroom()) {
        self.pacerHeadroom = pacerHeadroom
        self.transportRoute = transportRoute
    }

    let lock = NSLock()
    var stateValue: EnvState = .clear
    /// Last published stream route class (a `LinkClass.rawValue`:
    /// "wired"/"wifi"/"tunnel"/"unknown").
    var streamLinkValue: String {
        get { transportRoute.streamLink }
        set { transportRoute.streamLink = newValue }
    }
    /// Monotonic instant of the last session feed (0 = never) - the cadence
    /// only trusts the route within `routeTrustHorizonNanos` of this.
    var lastFedNanos: UInt64 = 0
    /// Each stream/reconnect re-earns Wi-Fi warmup because the radio renegotiates its power-save
    /// posture for every fresh flow. Zero means no ping loop has started.
    private var pingLoopStartNanos: UInt64 = 0

    // MARK: - Session feed (StreamSession's 2 s present-metric tick)

    /// Serial home of the evidence state: every fold runs here, whatever thread posts it.
    let feedQueue = DispatchQueue(label: "io.ugfugl.Glimmer.envsignal", qos: .utility)
    // Sampling runs outside these locks; only its current session may publish evidence.
    let observationLock = NSLock()
    var observationID: UUID?
    var observations: EnvObservationSource?

    package var routeSnapshot: StreamRouteSnapshot? {
        let source = observationLock.withLock { observations }
        return source?.route()
    }

    // MARK: - Published reconciler decision (lock-guarded)
    // Consumers pull one snapshot on their existing ticks; generation0 means never published.

    /// Desired headroom level (0...`maxHeadroomLevel`), +1 pacer depth per level.
    /// 0 is REST (depth 1, as with no reconciler), forced while the state is CLEAR,
    /// which a wired route pins. Internal so the Evidence reconcile can publish it.
    var headroomLevelValue = 0
    /// EWMA-smoothed recv-jitter (ms) that drives the published headroom (weight
    /// `Self.jitterBaseEwmaWeight`). Published so the audio cushion can seed off
    /// the same smoothed value.
    var smoothedJitterMsValue: Double = 0
    /// Only changed level/jitter advances this generation; unchanged decisions cost consumers
    /// one locked comparison and no reconfiguration.
    var decisionGeneration: UInt64 = 0

    /// The published reconciler decision, read in one short lock. Returned whole
    /// so a consumer takes the lock exactly once per pull and the three fields
    /// are mutually consistent. Any thread.
    package struct Decision: Sendable {
        package let headroomLevel: Int
        package let smoothedJitterMs: Double
        package let generation: UInt64
    }

    /// Pull the current published decision (lock-guarded read; any thread). The
    /// ONLY cross-thread surface the actuators touch - they never call back in.
    package var decision: Decision {
        lock.lock(); defer { lock.unlock() }
        return Decision(headroomLevel: headroomLevelValue,
                        smoothedJitterMs: smoothedJitterMsValue,
                        generation: decisionGeneration)
    }

    /// Current state (lock-guarded read; any thread).
    package var state: EnvState {
        lock.lock(); defer { lock.unlock() }
        return stateValue
    }

    /// Current stream-link label as last fed (lock-guarded read; any thread).
    package var streamLink: String {
        lock.lock(); defer { lock.unlock() }
        return streamLinkValue
    }

    // MARK: - Ping counters (the keepalive cadence judge)

    // Each producer resets its own counter at bring-up, including reconnect. Exporter-time reset
    // would erase audio handshake bursts because the loop starts before telemetry exists.
    package let videoPingsSentTotal = TelemetryCounters.Counter()
    package let audioPingsSentTotal = TelemetryCounters.Counter()
    /// State transitions this session (`env_state_changes_total`).
    package let stateChangesTotal = TelemetryCounters.Counter()

    /// Video ping loop bring-up edge: reset the video pings counter and drop
    /// any prior session's route claim (the new session must re-prove its
    /// route before the cadence may relax - fail toward the countermeasure).
    package func noteVideoPingLoopStart() {
        videoPingsSentTotal.reset()
        expireRouteClaim()
    }

    /// Audio ping loop bring-up edge (mid-handshake - the earliest of the two).
    package func noteAudioPingLoopStart() {
        audioPingsSentTotal.reset()
        expireRouteClaim()
    }

    private func expireRouteClaim() {
        lock.lock()
        streamLinkValue = LinkClass.unknown.rawValue
        lastFedNanos = 0
        pingLoopStartNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    // MARK: - LIVE ACTUATION #1: the conditional keepalive cadence

    /// Both RTP ping threads read the live cadence each wake (~13Hz), using two short lock reads.
    package func steadyPingInterval() -> TimeInterval {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let link = streamLinkValue
        let current = stateValue
        let fed = lastFedNanos
        let loopStart = pingLoopStartNanos
        lock.unlock()
        let routeFresh = fed != 0 && nowNanos &- fed <= Self.routeTrustHorizonNanos
        let inWarmup = loopStart != 0 && nowNanos &- loopStart < Self.wifiWarmupPingNanos
        return Self.resolveSteadyPingInterval(
            link: LinkClass(label: link), state: current, routeFresh: routeFresh,
            inputIdle: isInputIdle(nowNanos: nowNanos), inWarmup: inWarmup)
    }

    /// Stale/unknown/tunnel routes fail toward75ms; fresh wired routes use500ms. Wi-Fi pins75ms
    /// during warmup, idle input or caution; active clear Wi-Fi may relax. Fresh evidence always
    /// reopens that decision, so the countermeasure never permanently gives up.
    static func resolveSteadyPingInterval(
        link: LinkClass, state: EnvState, routeFresh: Bool,
        inputIdle: Bool, inWarmup: Bool
    ) -> TimeInterval {
        guard routeFresh else { return fastPingIntervalSeconds }
        switch link {
        case .wired:
            return relaxedPingIntervalSeconds
        case .wifi:
            if inWarmup { return fastPingIntervalSeconds }
            if state != .clear { return fastPingIntervalSeconds }
            return inputIdle ? fastPingIntervalSeconds : relaxedPingIntervalSeconds
        case .tunnel, .unknown:
            return fastPingIntervalSeconds
        }
    }

    /// The always-live input stamp resets at connect; no input yet means idle and keeps fast pings.
    private func isInputIdle(nowNanos: UInt64) -> Bool {
        guard let last = TelemetryCounters.shared.lastInputNanos else { return true }
        return nowNanos &- last >= UInt64(Self.keepaliveIdleSeconds * 1_000_000_000)
    }

    // MARK: - Evidence state (feedQueue-confined)

    /// Session-relative RSSI distribution: 1dB buckets over 0...−100dBm
    /// (index = −dBm). Integer histogram so the p50 is exact and the memory
    /// is fixed (~0.8KB) over a session of any length.
    var rssiHistogram = [Int](repeating: 0, count: 101)
    var rssiSampleCount = 0
    /// Session-relative tx-rate distribution: 25Mbps buckets, capped at
    /// 6Gbps (index 240). Coarse is fine - the thresholds are 0.5×/0.6×.
    var txHistogram = [Int](repeating: 0, count: 241)
    var txSampleCount = 0
    static let txBucketMbps = 25.0

    /// Delta-snapshot per-socket gaps, out-of-order packets and ENet retransmits. Receive jitter
    /// is a live gauge, not a delta.
    struct GapTotals {
        var net50: UInt64 = 0
        var audio50: UInt64 = 0
        var net100: UInt64 = 0
        var audio100: UInt64 = 0
        var outOfOrder: UInt64 = 0
        var retransmit: UInt64 = 0
    }

    /// Previous-tick gap-counter totals (nil until the first tick arms them,
    /// so pre-session residue can never count as window evidence).
    var prevGapTotals: GapTotals?
    /// Previous-tick video datagram clock; a newer stamp means video arrived.
    var prevDatagramUs: UInt64?

    /// The window being accumulated (tick fold) + the run/dwell counters.
    var ticksInWindow = 0
    var window = WindowEvidence()
    var degradedRun = 0
    /// True iff any window in the CURRENT degraded run carried co-gap
    /// evidence - selects the 3-window entry over the 5-window radio-only one.
    var runHadCoGap = false
    /// True iff any window in the current run showed a radio sag; with
    /// `runHadCoGap` it names the evidence behind a CAUTION entry.
    var runHadRadioSag = false
    var severeRun = 0
    var quietRun = 0
    var windowsSinceChange = Int.max
    /// EWMA of the per-window recv-jitter (ms) driving the published headroom's smoothed
    /// jitter - `feedQueue`-confined like the rest of the evidence state; copied into the
    /// lock-guarded `smoothedJitterMsValue` at reconcile. 0 until the first window.
    var reconcileSmoothedJitterMs: Double = 0

    /// One evidence window's facts - kept whole so a state transition can
    /// emit the exact vector that caused it (the post-hoc judge needs the
    /// evidence, not just the verdict).
    struct WindowEvidence {
        /// A video datagram arrived during the window. A dead stream's window
        /// (sleep, undock) carries no link evidence: its retransmits are the
        /// control channel knocking on a closed door.
        var videoArrived = false
        var netGap50: UInt64 = 0
        var audioGap50: UInt64 = 0
        var netGap100: UInt64 = 0
        var audioGap100: UInt64 = 0
        /// Worst (minimum) radio readings across the window's ticks -
        /// conservative toward detection; the sustained-run requirement is
        /// what keeps one bad probe from ever escalating anything.
        var rssiDbm: Int?
        var txRateMbps: Double?
        var rssiP50: Int?
        var txP95: Double?
        var radioArmed = false
        // JITTER evidence: the worst recv-jitter (ms) across the window's ticks
        // (live gauge, max-folded) plus the window-summed out-of-order + ENet
        // retransmit deltas, folded delta-snapshotted like the gap counters.
        var maxJitterMs: Double = 0
        var outOfOrder: UInt64 = 0
        var retransmit: UInt64 = 0
        var coGap50: Bool { netGap50 > 0 && audioGap50 > 0 }
        var coGap100: Bool { netGap100 > 0 && audioGap100 > 0 }
        /// Jitter/loss escalate predicate (jitter ≥8ms, ooo ≥6, retx ≥4).
        var jitterDegraded: Bool {
            maxJitterMs >= EnvSignalController.jitterEscalateMs
                || outOfOrder >= EnvSignalController.outOfOrderEscalate
                || retransmit >= EnvSignalController.retransmitEscalate
        }
        /// Jitter/loss relax predicate - ALL three under the relax lines (jitter
        /// ≤4ms, ooo ≤2, retx ≤1); the gap to `jitterDegraded` is the dead band.
        var jitterQuiet: Bool {
            maxJitterMs <= EnvSignalController.jitterRelaxMs
                && outOfOrder <= EnvSignalController.outOfOrderRelax
                && retransmit <= EnvSignalController.retransmitRelax
        }
    }

    // The session FEED, the window fold + classifier, the state machine, the RECONCILE
    // publish, the session-relative percentiles and the session lifecycle live in
    // EnvSignalController+Evidence.swift. They run on `feedQueue` and mutate the evidence above.

    // Audio pre-ratchet and an extra pacer floor remain unwired; enabling either requires fresh
    // stream measurements, including display-callback-gap attribution for pacing.
}
