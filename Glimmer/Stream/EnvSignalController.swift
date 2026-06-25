//
//  EnvSignalController.swift
//
//  The ENV-SIGNAL adaptive layer - SHADOW MODE. A CLEAR/CAUTION/DISTRESS
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
//  SHADOW MODE (the contract for this pass): the state machine RUNS and
//  EXPORTS (env_state / env_state_changes_total / pings_sent counters, plus
//  an `env_state` NDJSON event with the evidence vector + a Diag NOTICE on
//  every transition) but ACTUATES nothing - except the single approved live
//  actuation below. The state machine is judged against felt events for one
//  full session BEFORE any further dial moves; see "Future actuations".
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
    private static let cat = "EnvSignal"

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
    /// process-global flag (read on the actuators' own ticks, set at most once at
    /// bring-up) so we can A/B without a rebuild. `nonisolated(unsafe)`: a plain
    /// Bool read/write is tear-free and it is not flipped mid-window in practice,
    /// so no synchronization is needed (the A/B is a compile-in-and-flip dial).
    nonisolated(unsafe) static var reconcilerEnabled = true

    // MARK: - Link class

    /// The stream route class. `rawValue` IS the on-the-wire/persistence label
    /// (`StreamRouteProbe.classify`, the `stream_link` NDJSON field) - so the
    /// rawValue is used ONLY at that boundary (parse in / publish out); all the
    /// gating logic below compares the enum, never bare literals. An unrecognized
    /// label maps to `.unknown` (fail toward the countermeasure).
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
    /// Send-due slop: the ping threads wake on the fast quantum and gate the
    /// send on elapsed-since-last-ping; without a few ms of slop a 74.9ms
    /// wake against a 75ms interval would skip to 150ms cadence.
    static let pingDueSlopSeconds = 0.005

    /// Nanoseconds after which a ping is due for `interval` (slop applied).
    /// Shared by both receive-loop ping threads so the due math can't drift.
    static func dueNanos(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval - pingDueSlopSeconds) * 1_000_000_000)
    }

    // MARK: - Cross-thread outputs (lock-guarded)

    private let lock = NSLock()
    private var stateValue: EnvState = .clear
    /// Last published stream route class (a `LinkClass.rawValue`:
    /// "wired"/"wifi"/"tunnel"/"unknown").
    private var streamLinkValue = LinkClass.unknown.rawValue
    /// Monotonic instant of the last exporter feed (0 = never) - the cadence
    /// only trusts the route within `routeTrustHorizonNanos` of this.
    private var lastFedNanos: UInt64 = 0

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
    /// route pins), so a clean WIRED link publishes REST.
    private var headroomLevelValue = 0
    /// EWMA-smoothed recv-jitter (ms) that drives the published headroom (weight
    /// `Self.jitterBaseEwmaWeight`, copied from FecHeadroomController so the
    /// jitter-scaled FEC base is byte-identical when consumed). Published so the
    /// FEC actuator can scale its base off the SAME smoothed value both used to
    /// read independently.
    private var smoothedJitterMsValue: Double = 0
    /// Monotonic decision generation, bumped on every reconcile that CHANGES the
    /// published level or smoothed jitter. A consumer caches the last generation
    /// it applied and re-applies only when this advances - so an unchanged
    /// decision costs the hot path one locked `UInt64` compare and nothing more.
    private var decisionGeneration: UInt64 = 0

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
        lock.unlock()
    }

    // MARK: - LIVE ACTUATION #1: the conditional keepalive cadence

    /// The steady keepalive interval the RTP ping loops should honor RIGHT
    /// NOW. Called from both dedicated ping threads each wake (~13Hz); cost is
    /// two short lock reads. Decision table (the header carries the WHY):
    ///   * wired (fresh)  → relaxed 500ms - a wired NIC doesn't doze, so the
    ///     fast cadence would just spend packets for nothing.
    ///   * wifi (fresh)   → fast 75ms when input-idle OR state ≥ CAUTION
    ///     (doze window open / link already degraded); relaxed 500ms during
    ///     active-input CLEAR play (input traffic holds the radio awake).
    ///   * tunnel/unknown/stale → fast 75ms: route truth absent or possibly
    ///     riding the radio - keep the validated countermeasure. Never a
    ///     permanent give-up: the next exporter feed or route probe re-opens
    ///     the relaxed path within a second.
    func steadyPingInterval() -> TimeInterval {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let link = streamLinkValue
        let current = stateValue
        let fed = lastFedNanos
        lock.unlock()
        let routeFresh = fed != 0 && nowNanos &- fed <= Self.routeTrustHorizonNanos
        guard routeFresh else { return Self.fastPingIntervalSeconds }
        switch LinkClass(label: link) {
        case .wired:
            return Self.relaxedPingIntervalSeconds
        case .wifi:
            if current != .clear { return Self.fastPingIntervalSeconds }
            return isInputIdle(nowNanos: nowNanos)
                ? Self.fastPingIntervalSeconds : Self.relaxedPingIntervalSeconds
        case .tunnel, .unknown:
            return Self.fastPingIntervalSeconds
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

    /// Session-relative RSSI distribution: 1dB buckets over 0...−100dBm
    /// (index = −dBm). Integer histogram so the p50 is exact and the memory
    /// is fixed (~0.8KB) over a session of any length.
    private var rssiHistogram = [Int](repeating: 0, count: 101)
    private var rssiSampleCount = 0
    /// Session-relative tx-rate distribution: 25Mbps buckets, capped at
    /// 6Gbps (index 240). Coarse is fine - the thresholds are 0.5×/0.6×.
    private var txHistogram = [Int](repeating: 0, count: 241)
    private var txSampleCount = 0
    private static let txBucketMbps = 25.0

    /// One tick's gap-counter totals (the per-socket >50/>100ms families) plus
    /// the receive-quality totals the reconciler delta-snapshots for its jitter
    /// evidence (out-of-order + ENet retransmit - recv-jitter is a live gauge,
    /// read directly, not a delta).
    private struct GapTotals {
        var net50: UInt64 = 0
        var audio50: UInt64 = 0
        var net100: UInt64 = 0
        var audio100: UInt64 = 0
        var outOfOrder: UInt64 = 0
        var retransmit: UInt64 = 0
    }

    /// Previous-tick gap-counter totals (nil until the first tick arms them,
    /// so pre-session residue can never count as window evidence).
    private var prevGapTotals: GapTotals?

    /// The window being accumulated (tick fold) + the run/dwell counters.
    private var ticksInWindow = 0
    private var window = WindowEvidence()
    private var degradedRun = 0
    /// True iff any window in the CURRENT degraded run carried co-gap
    /// evidence - selects the 3-window entry over the 5-window radio-only one.
    private var runHadCoGap = false
    private var severeRun = 0
    private var quietRun = 0
    private var windowsSinceChange = Int.max
    /// EWMA of the per-window recv-jitter (ms) driving the published headroom's
    /// smoothed jitter - exporter-queue-confined like the rest of the evidence
    /// state; copied into the lock-guarded `smoothedJitterMsValue` at reconcile.
    /// 0 until the first window (the FEC base then stays at its clean floor).
    private var reconcileSmoothedJitterMs: Double = 0

    /// One evidence window's facts - kept whole so a state transition can
    /// emit the exact vector that caused it (the post-hoc judge needs the
    /// evidence, not just the verdict).
    private struct WindowEvidence {
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

    // MARK: - Feed (one exporter capture tick)

    /// Fold one ~1Hz capture tick into the evidence layer and publish the
    /// route + freshness for the cadence decision. Exporter workQueue ONLY.
    /// NWPathMonitor participates through `route`: the probe re-probes on
    /// every path change, so a mid-session undock lands here on the next tick.
    func observeCaptureTick(route: StreamRouteSnapshot?, wifi: WiFiSnapshot?) {
        let link = LinkClass(label: route?.linkLabel)
        lock.lock()
        streamLinkValue = link.rawValue  // rawValue ONLY at the publish boundary
        lastFedNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        // A wired route FORCES CLEAR (the spec's gate), immediately and
        // outside the dwell guard - there is no radio to compensate for, and
        // whatever evidence was mid-run no longer describes the stream path.
        if link == .wired, state != .clear {
            applyTransition(to: .clear, reason: "stream_link_wired")
            resetRuns()
            // Publish REST immediately (don't wait for the window close): a wired
            // route forced CLEAR, so the headroom decision must drop to 0 now -
            // FEC 24ms base + pacer depth 1 = byte-identical to no-reconciler.
            publishRestDecision()
        }

        accumulateRadioBaseline(wifi)
        foldTickIntoWindow(wifi: wifi)
        ticksInWindow += 1
        guard ticksInWindow >= Self.ticksPerWindow else { return }
        evaluateWindow(link: link)
        ticksInWindow = 0
        window = WindowEvidence()
    }

    /// Accumulate the session-relative radio percentile baselines. The radio
    /// is sampled whenever ASSOCIATED (route-independent - the radio is the
    /// same radio while docked); only the EVIDENCE arming is route-gated.
    private func accumulateRadioBaseline(_ wifi: WiFiSnapshot?) {
        guard let wifi, wifi.linkState == .associated else { return }
        if let rssi = wifi.rssiDbm, rssi < 0 {
            rssiHistogram[min(100, -rssi)] += 1
            rssiSampleCount += 1
        }
        if let rate = wifi.txRateMbps, rate > 0 {
            txHistogram[min(240, Int(rate / Self.txBucketMbps))] += 1
            txSampleCount += 1
        }
    }

    /// Fold this tick's gap-counter deltas + radio readings into the current
    /// window. Gap deltas come off the always-live per-socket counters the
    /// receive paths already maintain - no new hot-path cost anywhere. A
    /// non-monotonic step (the connect-edge counter reset of a mid-session
    /// reconnect) re-arms the baseline instead of folding a wrapped delta -
    /// one quiet-looking tick beats a fabricated 2^64-gap "evidence" window.
    private func foldTickIntoWindow(wifi: WiFiSnapshot?) {
        let counters = TelemetryCounters.shared
        let totals = GapTotals(net50: counters.videoGapOver50msTotal.value,
                               audio50: counters.audioGapOver50msTotal.value,
                               net100: counters.videoGapOver100msTotal.value,
                               audio100: counters.audioGapOver100msTotal.value,
                               outOfOrder: counters.videoPacketsOutOfOrderTotal.value,
                               retransmit: counters.enetRetransmitTotal.value)
        if let prev = prevGapTotals,
           totals.net50 >= prev.net50, totals.audio50 >= prev.audio50,
           totals.net100 >= prev.net100, totals.audio100 >= prev.audio100,
           totals.outOfOrder >= prev.outOfOrder, totals.retransmit >= prev.retransmit {
            window.netGap50 &+= totals.net50 &- prev.net50
            window.audioGap50 &+= totals.audio50 &- prev.audio50
            window.netGap100 &+= totals.net100 &- prev.net100
            window.audioGap100 &+= totals.audio100 &- prev.audio100
            window.outOfOrder &+= totals.outOfOrder &- prev.outOfOrder
            window.retransmit &+= totals.retransmit &- prev.retransmit
        }
        prevGapTotals = totals
        // Recv-jitter is a LIVE gauge (last-writer-wins), not a monotonic total -
        // fold the worst (max) reading across the window's ticks, conservative
        // toward detection. Sanitized like the FEC controller does.
        let jitter = counters.recvJitterMs
        if jitter.isFinite, jitter >= 0 { window.maxJitterMs = max(window.maxJitterMs, jitter) }
        if let rssi = wifi?.rssiDbm, rssi < 0 {
            window.rssiDbm = window.rssiDbm.map { min($0, rssi) } ?? rssi
        }
        if let rate = wifi?.txRateMbps, rate > 0 {
            window.txRateMbps = window.txRateMbps.map { min($0, rate) } ?? rate
        }
    }

    /// Close one ~2s window: classify it (degraded / severe / quiet /
    /// neutral), advance the runs, and move the state one step when a run
    /// satisfies the sustained contract. The classification mirrors
    /// FecHeadroomController.observeWindow - escalate thresholds high, relax
    /// thresholds lower, a neutral dead band that resets BOTH runs.
    private func evaluateWindow(link: LinkClass) {
        window.rssiP50 = rssiSessionP50()
        window.txP95 = txRateSessionP95()
        window.radioArmed = link == .wifi && (window.rssiP50 != nil || window.txP95 != nil)

        var radioDegraded = false
        var radioQuiet = true
        if window.radioArmed {
            if let rssi = window.rssiDbm, let p50 = window.rssiP50 {
                radioDegraded = radioDegraded || rssi <= p50 - Self.rssiDegradeDb
                radioQuiet = radioQuiet && rssi > p50 - Self.rssiRelaxDb
            }
            if let rate = window.txRateMbps, let p95 = window.txP95 {
                radioDegraded = radioDegraded || rate <= p95 * Self.txRateDegradeFraction
                radioQuiet = radioQuiet && rate > p95 * Self.txRateRelaxFraction
            }
        }

        // Jitter/loss is now a first-class degradation input
        // alongside co-gap + radio, using FecHeadroomController's already-tuned
        // thresholds (window predicates above). The classifier captures the
        // jitter racer, so the published headroom tracks it instead of two
        // controllers each reading recvJitterMs independently.
        let degraded = window.coGap50 || radioDegraded || window.jitterDegraded
        let severe = window.coGap100 || (window.coGap50 && radioDegraded)
        // Quiet (the relax tier): no >50ms co-gap AND the radio above its
        // relax lines AND jitter/loss below the relax dead band. Single-socket
        // gaps don't block quiet - one path stalling alone is that path's own
        // story, not the link's.
        let quiet = !window.coGap50 && !window.coGap100 && radioQuiet && window.jitterQuiet

        if degraded {
            degradedRun += 1
            runHadCoGap = runHadCoGap || window.coGap50 || window.coGap100
            quietRun = 0
        } else if quiet {
            quietRun += 1
            degradedRun = 0
            runHadCoGap = false
        } else {
            // Neutral: evidence must be CONSECUTIVE to count (the SUSTAINED
            // guarantee), and a not-yet-quiet window can't shorten the dwell.
            degradedRun = 0
            runHadCoGap = false
            quietRun = 0
        }
        severeRun = severe ? severeRun + 1 : 0

        advanceStateMachine(link: link)
        reconcile()
    }

    // MARK: - RECONCILE: publish the shared jitter→headroom decision

    /// Close the window's RECONCILE phase: smooth this window's worst recv-jitter
    /// (EWMA, weight `jitterBaseEwmaWeight` - the FEC controller's), map the
    /// CURRENT link state + smoothed jitter to a desired `headroomLevel`, and
    /// publish both (plus a bumped `generation` on any change) behind `lock` -
    /// the same lock-guarded pattern as `stateValue`/`streamLinkValue`. Both
    /// actuators PULL this on their own ticks; the reconciler never calls into
    /// them and holds only its own lock here.
    ///
    /// The desired level is forced to 0 (REST) whenever the link state is CLEAR
    /// (which a wired route pins), so a clean WIRED link publishes
    /// `headroomLevel == 0` → FEC 24ms base + pacer depth 1 = byte-identical to
    /// no-reconciler. Above CLEAR, the smoothed jitter maps through the same
    /// dead-zone/ladder the FEC soft thresholds use, capped at `maxHeadroomLevel`.
    private func reconcile() {
        // EWMA the worst-jitter of this window (sanitized to the same domain the
        // FEC controller smooths) so a single noisy window can't yank the base.
        let sample = window.maxJitterMs.isFinite ? max(0, window.maxJitterMs) : 0
        reconcileSmoothedJitterMs = reconcileSmoothedJitterMs <= 0
            ? sample
            : reconcileSmoothedJitterMs + Self.jitterBaseEwmaWeight * (sample - reconcileSmoothedJitterMs)

        let desiredLevel = desiredHeadroomLevel(
            smoothedJitterMs: reconcileSmoothedJitterMs,
            outOfOrder: window.outOfOrder, retransmits: window.retransmit)

        lock.lock()
        let changed = desiredLevel != headroomLevelValue
            || reconcileSmoothedJitterMs != smoothedJitterMsValue
        headroomLevelValue = desiredLevel
        smoothedJitterMsValue = reconcileSmoothedJitterMs
        if changed { decisionGeneration &+= 1 }
        lock.unlock()
    }

    /// Map the current link state + the three receive-side health signals
    /// (smoothed jitter, out-of-order, retransmit) to the desired headroom level
    /// (0...`maxHeadroomLevel`). CLEAR (incl. the wired-pinned case) is the REST
    /// decision: level 0. Above CLEAR, the published level is the WORST of the
    /// jitter-derived level and the ooo/retransmit-derived level - so a LOW-jitter
    /// but reordering/retransmitting window (which `evaluateWindow` already counts
    /// as degraded) still publishes headroom, honoring the documented 3-signal
    /// contract instead of riding jitter alone. `max` keeps it bounded at
    /// `maxHeadroomLevel`; each axis can only widen the hold, never shrink it.
    private func desiredHeadroomLevel(smoothedJitterMs: Double,
                                      outOfOrder: UInt64, retransmits: UInt64) -> Int {
        guard state != .clear else { return 0 }
        let overDeadZone = smoothedJitterMs - Self.headroomJitterDeadZoneMs
        let jitterLevel = overDeadZone > 0
            ? Int((overDeadZone / Self.headroomJitterMsPerLevel).rounded(.up)) : 0
        // ooo/retransmit map to one level at the FEC soft-escalate line, two at the
        // hard-spike line - the same thresholds FecHeadroomController.observeWindow
        // self-decided on when the reconciler is off.
        let oooLevel = oooRetransmitLevel(outOfOrder: outOfOrder, retransmits: retransmits)
        return min(Self.maxHeadroomLevel, max(0, max(jitterLevel, oooLevel)))
    }

    /// Discrete headroom level from this window's out-of-order + retransmit deltas,
    /// keyed off FecHeadroomController's soft/hard escalate thresholds: 0 below the
    /// soft line, 1 at/above it, 2 at/above the hard-spike line.
    private func oooRetransmitLevel(outOfOrder: UInt64, retransmits: UInt64) -> Int {
        let hard = outOfOrder >= UInt64(FecHeadroomController.oooHardEscalate)
            || retransmits >= UInt64(FecHeadroomController.retransmitHardEscalate)
        if hard { return 2 }
        let soft = outOfOrder >= UInt64(FecHeadroomController.oooEscalate)
            || retransmits >= UInt64(FecHeadroomController.retransmitEscalate)
        return soft ? 1 : 0
    }

    /// Publish the REST decision (headroom level 0, smoothed jitter 0) and clear
    /// the smoothing accumulator. Called at the wired-forces-CLEAR edge and on a
    /// fresh-session reset so the published decision is at REST the instant the
    /// link is known clean - never a stale escalation an actuator could pull.
    private func publishRestDecision() {
        reconcileSmoothedJitterMs = 0
        lock.lock()
        let changed = headroomLevelValue != 0 || smoothedJitterMsValue != 0
        headroomLevelValue = 0
        smoothedJitterMsValue = 0
        if changed { decisionGeneration &+= 1 }
        lock.unlock()
    }

    /// Apply the run counters to the level - one step at a time, dwell-
    /// guarded, wired pinned to CLEAR (handled at the feed edge).
    private func advanceStateMachine(link: LinkClass) {
        if windowsSinceChange != Int.max { windowsSinceChange += 1 }
        guard link != .wired else { return }
        guard windowsSinceChange >= Self.minDwellWindows else { return }

        let current = state
        // Co-gap runs enter at 3 windows; pure-radio runs need 5 (sustained
        // ~10s - a sag with no delivery impact has to insist).
        let entryWindows = runHadCoGap ? Self.escalateWindows : Self.radioOnlyEscalateWindows
        if current == .clear, degradedRun >= entryWindows {
            applyTransition(to: .caution, reason: runHadCoGap ? "sustained_co_gaps" : "sustained_radio_sag")
            degradedRun = 0
            runHadCoGap = false
            return
        }
        if current == .caution, severeRun >= Self.escalateWindows {
            applyTransition(to: .distress, reason: "sustained_severe_co_gaps")
            severeRun = 0
            return
        }
        if current != .clear, quietRun >= Self.quietWindowsPerStepDown {
            let next = EnvState(rawValue: current.rawValue - 1) ?? .clear
            applyTransition(to: next, reason: "quiet_dwell")
            quietRun = 0
        }
    }

    /// Publish a state change: bump the counter, log the recoverable-state
    /// NOTICE (quiet - never warn/error for a state the machine recovers
    /// from), and emit the `env_state` NDJSON event WITH the evidence vector
    /// so the shadow session is judgeable post-hoc.
    private func applyTransition(to next: EnvState, reason: String) {
        let previous: EnvState
        lock.lock()
        previous = stateValue
        stateValue = next
        lock.unlock()
        guard previous != next else { return }
        windowsSinceChange = 0
        stateChangesTotal.increment()
        Diag.notice("ENV \(previous.label) → \(next.label) (\(reason)) - shadow mode, "
            + "no dial moved (keepalive cadence aside)", Self.cat)
        var fields = [
            "\"event\":\"env_state\"",
            "\"from\":\"\(previous.label)\"",
            "\"to\":\"\(next.label)\"",
            "\"reason\":\"\(reason)\"",
            "\"stream_link\":\"\(TelemetryRenderer.jsonStringEscape(streamLink))\"",
            "\"win_net_gaps_50\":\(window.netGap50)",
            "\"win_audio_gaps_50\":\(window.audioGap50)",
            "\"win_net_gaps_100\":\(window.netGap100)",
            "\"win_audio_gaps_100\":\(window.audioGap100)",
            "\"radio_armed\":\(window.radioArmed)",
            "\"degraded_run\":\(degradedRun)",
            "\"severe_run\":\(severeRun)",
            "\"quiet_run\":\(quietRun)"
        ]
        if let rssi = window.rssiDbm { fields.append("\"rssi_dbm\":\(rssi)") }
        if let p50 = window.rssiP50 { fields.append("\"rssi_session_p50_dbm\":\(p50)") }
        if let rate = window.txRateMbps {
            fields.append("\"tx_rate_mbps\":\(TelemetryRenderer.jsonNumber(rate))")
        }
        if let p95 = window.txP95 {
            fields.append("\"tx_rate_session_p95_mbps\":\(TelemetryRenderer.jsonNumber(p95))")
        }
        TelemetryExporter.recordEvent(fields)
    }

    // MARK: - Session-relative percentiles

    /// Median RSSI (dBm) from the 1dB histogram; nil until warmed.
    private func rssiSessionP50() -> Int? {
        guard rssiSampleCount >= Self.radioBaselineMinSamples else { return nil }
        let target = (rssiSampleCount + 1) / 2
        var cumulative = 0
        for (index, bucket) in rssiHistogram.enumerated() {
            cumulative += bucket
            if cumulative >= target { return -index }
        }
        return nil
    }

    /// p95 tx-rate (Mbps, bucket midpoint) from the 25Mbps histogram; nil
    /// until warmed.
    private func txRateSessionP95() -> Double? {
        guard txSampleCount >= Self.radioBaselineMinSamples else { return nil }
        let target = Int((Double(txSampleCount) * 0.95).rounded(.up))
        var cumulative = 0
        for (index, bucket) in txHistogram.enumerated() {
            cumulative += bucket
            if cumulative >= target { return (Double(index) + 0.5) * Self.txBucketMbps }
        }
        return nil
    }

    // MARK: - Session lifecycle

    /// Reset for a fresh session: state to CLEAR, baselines/window/runs
    /// emptied, the transition counter zeroed. Called from the exporter's
    /// `start()` on its workQueue (the same confinement as the feed; the
    /// first capture tick is at least a second away, so nothing races it).
    /// No transition event is emitted - a fresh session starting at CLEAR is
    /// a baseline, not a recovery. The ping counters reset at their own
    /// loop-start edges instead (see the counter docs above).
    func resetForNewSession() {
        lock.lock()
        stateValue = .clear
        lock.unlock()
        stateChangesTotal.reset()
        rssiHistogram = [Int](repeating: 0, count: 101)
        rssiSampleCount = 0
        txHistogram = [Int](repeating: 0, count: 241)
        txSampleCount = 0
        prevGapTotals = nil
        ticksInWindow = 0
        window = WindowEvidence()
        resetRuns()
        // Publish REST so a fresh session never starts with a prior session's
        // escalated headroom (the actuators reset their own state at session
        // start too, but the published decision must agree from tick zero).
        publishRestDecision()
    }

    private func resetRuns() {
        degradedRun = 0
        runHadCoGap = false
        severeRun = 0
        quietRun = 0
        windowsSinceChange = Int.max
    }

    // MARK: - Future actuations (LISTED BUT DARK - the shadow-mode contract)
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
