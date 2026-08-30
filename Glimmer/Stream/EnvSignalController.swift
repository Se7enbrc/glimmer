//
//  EnvSignalController.swift
//
//  The ENV-SIGNAL adaptive layer. A CLEAR/CAUTION/DISTRESS
//  link-condition state machine fed once per telemetry capture tick (~1Hz)
//  with the stream ROUTE (StreamRouteProbe - the honest stream_link, re-probed
//  on every NWPathMonitor change), the associated-radio physics (RSSI / PHY
//  tx-rate), and the per-socket gap-event counters. It models the in-repo
//  FecHeadroomController safety contract:
//
//   1. SUSTAINED: escalation needs CONSECUTIVE ~2s evidence windows - co-gap
//      evidence needs 3 (~6s), pure-radio evidence needs 5 (~10s; a radio sag
//      with no delivery impact must prove itself longer). Never one sample.
//   2. SESSION-RELATIVE, never prescriptive absolutes: radio thresholds key
//      off THIS session's own RSSI p50 / tx-rate p95 (a -70dBm apartment and
//      a -45dBm desk are both "normal" for their own sessions).
//   3. HYSTERESIS, never latched: lower relax thresholds + a long quiet dwell
//      (30s) per de-escalation step + a minimum dwell between any two level
//      changes. Every state is always recoverable; reset per session.
//   4. GATED: radio evidence arms ONLY when stream_link == wifi, and a wired
//      route FORCES CLEAR - environmental signals gate radio compensation but
//      must never explain away client-side present-path collapses (a felt jank
//      marker on a FLAT-RSSI link is the pipeline's fault, not the radio's).
//      DISTRESS seconds are excluded from present-path quality scorecards,
//      never added.
//
//  EVIDENCE (per 2s window):
//   * co-gap: the video AND audio sockets both logged a >50ms inter-arrival
//     gap in the same window - the link-common-cause discriminator (one
//     socket gapping alone is that path's own story; both together is the
//     radio). Severe tier: both logged >100ms. The enet gap family is
//     deliberately NOT consumed here (expectation-gated only recently; its
//     idle-cadence artifact polluted exactly this kind of read).
//   * radio: RSSI ≤ session-p50 − 8dB, or tx-rate ≤ 0.5× session-p95 -
//     armed only on a wifi stream route, only after a ~1min baseline warmup.
//
//  LIVE ACTUATIONS (the shadow-mode contract of the original pass is
//  superseded): the state machine RUNS, EXPORTS (env_state /
//  env_state_changes_total / pings_sent counters, plus an `env_state` NDJSON
//  event with the evidence vector + a Diag NOTICE on every transition), and
//  moves TWO dials - the conditional keepalive cadence (#1 below) and, with
//  `reconcilerEnabled`, the unified jitter→headroom decision consumed by the
//  FramePacer adaptive depth and the FEC reorder-hold. Anything further stays
//  dark; see "Future actuations".
//
//  LIVE ACTUATION #1 - CONDITIONAL KEEPALIVE (`steadyPingInterval()`):
//  75ms steady ping cadence only when stream_link == wifi AND (input-idle OR
//  state ≥ CAUTION); 500ms (upstream's cadence) otherwise. Safe on a jittery
//  link because the gate only ever RELAXES the 75ms doze countermeasure
//  (UdpPinger.steadyPingIntervalSeconds carries the numbers) where the doze
//  mechanism is absent: a wired NIC doesn't doze, and active input traffic
//  holds the radio awake (a busy input stream is far less blip-prone than an
//  idle one). If 500ms ever proves insufficient on active-input wifi, the gaps
//  it causes ARE the co-gap evidence that escalates to CAUTION and re-tightens
//  the cadence - the safeguard recovers itself, never gives up.
//  Unknown/tunnel/stale routes FAIL TOWARD 75ms: wrongly fast costs a few
//  kbps; wrongly slow on a dozing radio costs a felt multi-frame gap.
//
//  THREADING: evidence/baseline state is confined to the exporter's serial
//  workQueue (the only `observeCaptureTick` caller; exactly one exporter
//  exists at a time - the CaptureBaselines discipline). The few outputs that
//  cross threads (state, stream link, feed freshness) sit behind one lock;
//  the ping counters are self-locked. When telemetry is OFF the state
//  machine is never fed, the cadence reads "unknown route", and the loops
//  hold the validated 75ms everywhere - gate-off behavior is byte-identical
//  to the pre-conditional shipped dial.
//

import Foundation

/// Process-global env-signal state machine + the conditional-keepalive dial.
/// Fed by the telemetry exporter (gate-on only); read by the always-live RTP
/// ping loops. `@unchecked Sendable`: cross-thread fields are lock-guarded,
/// evidence state is exporter-queue-confined (see the header).
final class EnvSignalController: @unchecked Sendable {
    static let shared = EnvSignalController()
    // Module-internal (not private) so the transition breadcrumb in
    // EnvSignalController+Evidence.swift logs under the same category.
    static let cat = "EnvSignal"

    // The reconciler kill-switch, the `LinkClass` / `EnvState` vocabulary,
    // the FecHeadroomController contract numbers, the reconciler decision
    // mapping constants and the keepalive cadence dials live in
    // EnvSignalController+Tunables.swift - moved there to keep THIS file
    // under the length limit.

    // MARK: - Cross-thread outputs (lock-guarded)
    //
    // Module-internal (not private) so the feed / state machine / reconcile
    // in EnvSignalController+Evidence.swift can publish through the same
    // lock across the file split. `pingLoopStartNanos` below stays private:
    // only this file's keepalive actuation touches it.

    let lock = NSLock()
    var stateValue: EnvState = .clear
    /// Last published stream route class (a `LinkClass.rawValue`:
    /// "wired"/"wifi"/"tunnel"/"unknown").
    var streamLinkValue = LinkClass.unknown.rawValue
    /// Monotonic instant of the last exporter feed (0 = never) - the cadence
    /// only trusts the route within `routeTrustHorizonNanos` of this.
    var lastFedNanos: UInt64 = 0
    /// Monotonic instant of the most recent ping-loop bring-up edge (stream
    /// start or silent reconnect; stamped in `expireRouteClaim`, the shared
    /// bring-up path) - the wifi keepalive warm-up window measures from here.
    /// A reconnect re-earns the warm-up deliberately: the radio renegotiates
    /// its power-save posture on every fresh flow. 0 = no session yet.
    private var pingLoopStartNanos: UInt64 = 0

    // MARK: - Published reconciler decision (lock-guarded)
    //
    // The single jitter→headroom decision both actuators PULL on their own
    // ticks. Computed in the reconcile phase at window close (`reconcileLocked`)
    // and published behind THIS controller's `lock` - the same pattern as
    // `stateValue`/`streamLinkValue`. Each consumer reads these with one short
    // lock on its own thread, under its OWN existing lock, and never calls back
    // into this controller. The `generation` counter lets a consumer no-op when
    // the decision is unchanged, so the hot RTP receive thread takes the lock
    // only to compare a `UInt64` on the common (unchanged) path.

    /// Desired headroom level (0...`Self.maxHeadroomLevel`). 0 = clear / jitter
    /// under the dead-zone - the REST decision: FEC reorder-hold at its 24ms
    /// base, pacer adaptive depth at 1 (byte-identical to no-reconciler). Each
    /// level up = +1 FEC step (8ms) + 1 pacer depth, capped at FEC 48ms / the
    /// mapped depth. Forced to 0 whenever the link state is CLEAR (which a wired
    /// route pins), so a clean WIRED link publishes REST. Module-internal
    /// (not private), with the two fields below, so the reconcile phase in
    /// EnvSignalController+Evidence.swift can publish them under `lock`.
    var headroomLevelValue = 0
    /// EWMA-smoothed recv-jitter (ms) that drives the published headroom (weight
    /// `Self.jitterBaseEwmaWeight`, copied from FecHeadroomController so the
    /// jitter-scaled FEC base is byte-identical when consumed). Published so the
    /// FEC actuator can scale its base off the SAME smoothed value both used to
    /// read independently.
    var smoothedJitterMsValue: Double = 0
    /// Monotonic decision generation, bumped on every reconcile that CHANGES the
    /// published level or smoothed jitter. A consumer caches the last generation
    /// it applied and re-applies only when this advances - so an unchanged
    /// decision costs the hot path one locked `UInt64` compare and nothing more.
    var decisionGeneration: UInt64 = 0

    /// The published reconciler decision, read in one short lock. Returned whole
    /// so a consumer takes the lock exactly once per pull and the three fields
    /// are mutually consistent. Any thread.
    struct Decision: Sendable {
        let headroomLevel: Int
        let smoothedJitterMs: Double
        let generation: UInt64
    }

    /// Pull the current published decision (lock-guarded read; any thread). The
    /// ONLY cross-thread surface the actuators touch - they never call back in.
    var decision: Decision {
        lock.lock(); defer { lock.unlock() }
        return Decision(headroomLevel: headroomLevelValue,
                        smoothedJitterMs: smoothedJitterMsValue,
                        generation: decisionGeneration)
    }

    /// Current state (lock-guarded read; any thread).
    var state: EnvState {
        lock.lock(); defer { lock.unlock() }
        return stateValue
    }

    /// Current stream-link label as last fed (lock-guarded read; any thread).
    var streamLink: String {
        lock.lock(); defer { lock.unlock() }
        return streamLinkValue
    }

    // MARK: - Ping counters (the keepalive cadence judge)

    // pings_sent, PER SOCKET - without this counter the keepalive A/B is
    // unjudgeable from data ("was it even active?"); this makes it legible.
    // Counted at the send site; transmit failures keep their own streak-edge
    // logging. Each resets at ITS OWN producer's start edge (note*PingLoopStart
    // below), NOT the exporter start: the audio loop starts mid-handshake,
    // before any exporter exists, so an exporter-time reset would wipe the burst
    // pings - and loop-start IS the session edge for these.
    let videoPingsSentTotal = TelemetryCounters.Counter()
    let audioPingsSentTotal = TelemetryCounters.Counter()
    /// State transitions this session (`env_state_changes_total`).
    let stateChangesTotal = TelemetryCounters.Counter()

    /// Video ping loop bring-up edge: reset the video pings counter and drop
    /// any prior session's route claim (the new session must re-prove its
    /// route before the cadence may relax - fail toward the countermeasure).
    func noteVideoPingLoopStart() {
        videoPingsSentTotal.reset()
        expireRouteClaim()
    }

    /// Audio ping loop bring-up edge (mid-handshake - the earliest of the two).
    func noteAudioPingLoopStart() {
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

    /// The steady keepalive interval the RTP ping loops should honor RIGHT
    /// NOW. Called from both dedicated ping threads each wake (~13Hz); cost is
    /// two short lock reads. Gathers the live inputs and delegates the table
    /// to `resolveSteadyPingInterval` (pure, unit-tested).
    func steadyPingInterval() -> TimeInterval {
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

    /// The keepalive decision table, pure (the header carries the WHY):
    ///   * stale route    → fast 75ms: route truth absent or possibly riding
    ///     the radio - keep the validated countermeasure. Never a permanent
    ///     give-up: the next exporter feed re-opens the relaxed path.
    ///   * wired (fresh)  → relaxed 500ms - a wired NIC doesn't doze, so the
    ///     fast cadence would just spend packets for nothing (warm-up
    ///     included: there is no radio to hold awake).
    ///   * wifi WARM-UP   → fast 75ms unconditionally for the first
    ///     `wifiWarmupPingNanos` of a session/reconnect: the "input traffic
    ///     holds the radio awake" relaxation below is measurably false while
    ///     the AP's power-save/aggregation posture is still ramping - the
    ///     gaps hit the DOWNLINK regardless of uplink input (36 gaps >100ms
    ///     in a measured first-30s, zero once fast pings pinned).
    ///   * wifi (fresh)   → fast 75ms when input-idle OR state ≥ CAUTION
    ///     (doze window open / link already degraded); relaxed 500ms during
    ///     active-input CLEAR play (input traffic holds the radio awake).
    ///   * tunnel/unknown → fast 75ms.
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

    /// True when no input event landed within `keepaliveIdleSeconds`. Reads
    /// the always-live last-input stamp (one unfair-lock read; the stamp is
    /// reset at the connect edge, so "no input yet this session" reads idle -
    /// the correct doze posture for a freshly opened stream).
    private func isInputIdle(nowNanos: UInt64) -> Bool {
        guard let last = TelemetryCounters.shared.lastInputNanos else { return true }
        return nowNanos &- last >= UInt64(Self.keepaliveIdleSeconds * 1_000_000_000)
    }

    // MARK: - Evidence state (exporter-workQueue-confined)
    //
    // Module-internal (not private) so the feed / window fold / classifier
    // in EnvSignalController+Evidence.swift - the ONLY writers, all on the
    // exporter workQueue - can reach this state across the file split. The
    // queue confinement is unchanged: nothing else touches these.

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

    /// One tick's gap-counter totals (the per-socket >50/>100ms families) plus
    /// the receive-quality totals the reconciler delta-snapshots for its jitter
    /// evidence (out-of-order + ENet retransmit - recv-jitter is a live gauge,
    /// read directly, not a delta).
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

    /// The window being accumulated (tick fold) + the run/dwell counters.
    var ticksInWindow = 0
    var window = WindowEvidence()
    var degradedRun = 0
    /// True iff any window in the CURRENT degraded run carried co-gap
    /// evidence - selects the 3-window entry over the 5-window radio-only one.
    var runHadCoGap = false
    var severeRun = 0
    var quietRun = 0
    var windowsSinceChange = Int.max
    /// EWMA of the per-window recv-jitter (ms) driving the published headroom's
    /// smoothed jitter - exporter-queue-confined like the rest of the evidence
    /// state; copied into the lock-guarded `smoothedJitterMsValue` at reconcile.
    /// 0 until the first window (the FEC base then stays at its clean floor).
    var reconcileSmoothedJitterMs: Double = 0

    /// One evidence window's facts - kept whole so a state transition can
    /// emit the exact vector that caused it (the post-hoc judge needs the
    /// evidence, not just the verdict).
    struct WindowEvidence {
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
        // JITTER evidence: the worst recv-jitter (ms) seen across
        // the window's ticks (live gauge, max-folded), plus the window-summed
        // out-of-order + ENet-retransmit deltas. Folded delta-snapshotted like
        // the gap counters so the state classifier captures the jitter racer the
        // FecHeadroomController already tuned thresholds for - not just co-gap /
        // radio. Worst-jitter (max) keeps it conservative toward detection; the
        // sustained-run requirement keeps a single noisy window from escalating.
        var maxJitterMs: Double = 0
        var outOfOrder: UInt64 = 0
        var retransmit: UInt64 = 0
        var coGap50: Bool { netGap50 > 0 && audioGap50 > 0 }
        var coGap100: Bool { netGap100 > 0 && audioGap100 > 0 }
        /// Jitter/loss escalate predicate - FecHeadroomController's already-tuned
        /// soft thresholds (jitter ≥8ms, ooo ≥6, retx ≥4).
        var jitterDegraded: Bool {
            maxJitterMs >= FecHeadroomController.jitterEscalateMs
                || outOfOrder >= UInt64(FecHeadroomController.oooEscalate)
                || retransmit >= UInt64(FecHeadroomController.retransmitEscalate)
        }
        /// Jitter/loss relax predicate - ALL three under FEC's lower relax lines
        /// (jitter ≤4ms, ooo ≤2, retx ≤1). The gap to `jitterDegraded` is the
        /// dead band that prevents flapping.
        var jitterQuiet: Bool {
            maxJitterMs <= FecHeadroomController.jitterRelaxMs
                && outOfOrder <= UInt64(FecHeadroomController.oooRelax)
                && retransmit <= UInt64(FecHeadroomController.retransmitRelax)
        }
    }

    // The capture-tick FEED, the window fold + classifier, the state
    // machine, the RECONCILE publish, the session-relative percentiles and
    // the per-session reset live in EnvSignalController+Evidence.swift -
    // moved there to keep THIS file under the length limit. They run on the
    // exporter workQueue and mutate the evidence state declared above.

    // MARK: - Future actuations (LISTED BUT DARK)
    //
    // Every candidate below is an EXISTING, bounded, reversible dial. None is
    // wired; each gets enabled ONE AT A TIME, only after a full shadow
    // session judges this state machine against felt events (and each then
    // states its own validated-on-jittery-link reasoning, as the keepalive
    // gate above does). Listed here so the inventory can't drift into lore:
    //
    //  * AUDIO PLAYOUT PRE-RATCHET (dark): on CLEAR→CAUTION, pre-ratchet the
    //    audio playout target ONE 10ms step (within AudioDecoder's existing
    //    base/cap envelope) - pays 10ms of latency BEFORE the gap instead of
    //    one audible blip after it (the one-blip-per-upward-ratchet pattern).
    //    Decays via the existing 60s target decay.
    //
    //  * PACER DEPTH FLOOR +1 (dark, double-gated): raise FramePacer's
    //    adaptive depth floor by one within its existing cap during CAUTION+.
    //    BLOCKED until the display-link threading rework lands and drops are
    //    re-measured: most drops today are callback-gap-driven, so a depth-2
    //    simulated win is unattributable until that confound is removed.
}
