//
//  FecHeadroomController.swift
//
//  PROACTIVE FEC headroom: the OURS-OWNED slice of a wifi loss burst -
//  prevent, don't react. Today FEC/recovery is REACTIVE: only once loss has
//  become unrecoverable do we flood RFI + post-invalidation IDR (a long loss
//  burst can overwhelm the host's fixed FEC parity before that ever fires). This
//  adds an EARLY-WARNING that, on a SUSTAINED upward trend in the receive-side
//  health signals (recv-jitter / out-of-order / ENet reliable-retransmit),
//  proactively widens the client-side cross-frame REORDER-HOLD window so more
//  marginal frames complete from the parity the host ALREADY sends BEFORE they
//  tip into unrecoverable - then relaxes back to baseline when the link clears.
//
//  LOSS AXIS: the jitter/ooo/retransmit signals above miss a LOW-jitter but
//  LOSSY link (bursty 5GHz loss, ~0ms jitter) - exactly where frames tip into
//  unrecoverable → IDR while the controller sits at the 24ms floor. A SEPARATE
//  loss accumulator (`observeLoss` / `lossLevel`) escalates the SAME reorder-hold
//  on direct loss evidence (FEC recoveries + unrecoverable frames), combined with
//  the jitter axis via `max` in `holdWindowUs`. It drives ONLY the reorder-hold,
//  never the pacer depth - a deeper present buffer does nothing for loss recovery
//  and only adds latency (the measured present-depth lesson). Same do-no-harm: a
//  clean link keeps `lossLevel` at 0 and behaves byte-identically.
//
//  WHY THE REORDER-HOLD WINDOW IS THE LEVER (the safety crux):
//   * It costs ZERO extra bytes on the wire. Raising the host's FEC ratio means
//     more parity packets = MORE bytes on an already-marginal link, which can
//     itself worsen loss - the exact failure the task warns against. Worse, for
//     this Sunshine 7.1.450 host profile there is NO runtime client→host FEC-
//     ratio or bitrate request message wired at all (FEC% is host-driven per
//     frame via the NV fecInfo field; the per-frame FEC-status feedback moonlight
//     uses collides on the wire with IDX_SET_RGB_LED and is deliberately never
//     sent - see EnetControlChannel.queueFrameFecStatus / SdpCodec). So a wire-
//     side FEC/bitrate nudge is not available without protocol risk.
//   * The reorder-hold window, by contrast, is a pure RECEIVE-side lever already
//     present in RtpVideoQueue: it only governs how long an incomplete
//     frame waits for its late tail/parity shards before we declare loss. Widening
//     it during a degradation trend gives the host's existing parity more time to
//     land and complete the frame via FEC - genuine proactive FEC HEADROOM - with
//     no added traffic and no new wire message. It can only ever turn a frame that
//     WOULD have been declared lost into one recovered from parity already in
//     flight; it can never make the link worse.
//
//  SAFETY CONTRACT (all four, by construction):
//   1. SUSTAINED: escalation requires the degradation to persist for
//      `sustainedWindows` consecutive ~2s windows - never a single noisy sample.
//      A HARD spike (any signal past its higher `*HardEscalate` threshold) is a
//      sharp onset, not a soft trend, so it escalates after the shorter
//      `sustainedWindowsFast` run (still ≥1, still under the dwell guard) - headroom
//      lands DURING a short burst the ~6s sustained gate would have missed.
//   2. BOUNDED + CONSERVATIVE: the hold steps in small increments and is hard-
//      capped at `maxHoldUs`, which stays well under the worst-case ~56ms jitter
//      envelope the FramePacer already absorbs. The base is JITTER-SCALED - a
//      higher-baseline-jitter link starts wider than the clean 24ms floor (bounded
//      at `maxAdaptiveBaseHoldUs`), so a burst shorter than the sustained gate
//      still rides a wider base - but a clean low-jitter link sits at the unchanged
//      24ms baseline.
//   3. CANNOT WORSEN A MARGINAL LINK: the only thing it changes is a local wait;
//      it adds zero bytes, sends nothing, and the reorder-hold is itself gated
//      behind `receivedOosData` + `isFecRecoveryStillPossible()` in the queue, so
//      a frame already mathematically unrecoverable is never held.
//   4. NEVER OSCILLATES: separate (higher) escalate vs (lower) relax thresholds,
//      a minimum dwell between level changes, one-step-at-a-time movement, and an
//      EWMA-smoothed (not per-window) jitter base give it hysteresis - it ramps in
//      and bleeds out smoothly, it does not flap.
//
//  This is purely ADDITIVE early-warning. The reactive RFI/IDR + freeze-recovery
//  paths are untouched; when the link is clean/low-jitter the controller sits at
//  baseline and the queue behaves byte-identically to before.
//
//  THREADING: owned by RtpVideoQueue and driven once per ~2s receive-metrics
//  window from maybeLogMetrics - i.e. on the single RTP receive thread, off the
//  per-datagram hot path. No lock needed (same isolation as the rest of the
//  queue's window bookkeeping). The exporter never reads this directly.
//

import Foundation

/// Drives the proactive widening/relaxing of the cross-frame reorder-hold window
/// from a sustained trend in the three receive-side health signals. A value type
/// stored on RtpVideoQueue and stepped once per receive-metrics window.
struct FecHeadroomController {
    // MARK: - Tunables (conservative by design)

    /// Baseline reorder-hold window (µs) on a CLEAN/LOW-jitter link - the floor the
    /// adaptive base sits at when jitter is sub-`jitterBaseFloorMs`. A non-degrading
    /// low-jitter stream sits here, identical to the pre-controller behavior.
    static let baseHoldUs: UInt64 = 24_000
    /// Per-escalation step (µs). Small so the ramp is gentle and one noisy window
    /// can never jump the hold far even past the sustained gate.
    static let stepUs: UInt64 = 8_000
    /// Hard ceiling (µs). 48ms = clean baseline + 3 steps; stays under the
    /// worst-case ~56ms cross-frame jitter envelope the FramePacer absorbs, so even
    /// fully escalated the added wait never exceeds what pacing already tolerates.
    static let maxHoldUs: UInt64 = 48_000
    /// Max discrete levels above baseline ((max - base) / step = 3).
    static let maxLevel = Int((maxHoldUs - baseHoldUs) / stepUs)

    // MARK: - Jitter-scaled base (the higher-baseline-jitter link starts wider)

    /// Smoothed recv-jitter (ms) below which the adaptive base is the clean
    /// `baseHoldUs`. A LAN/clean-wifi link (sub-few-ms jitter) gets no extra base
    /// headroom - byte-identical to the pre-adaptive controller.
    static let jitterBaseFloorMs: Double = 4.0
    /// Per-ms-of-jitter-above-floor widening of the adaptive base (µs/ms). A
    /// 22ms-jitter wifi link (18ms over floor) earns +18ms of base headroom before
    /// any sustained escalation, so a short loss/reorder burst on a high-baseline
    /// link no longer rides entirely on the clean 24ms base. Bounded by
    /// `maxAdaptiveBaseHoldUs`.
    static let jitterBaseScaleUsPerMs: Double = 1_000
    /// Ceiling on the jitter-scaled base (µs). 40ms = clean base + 16ms; the level
    /// steps still ride on TOP of this up to `effectiveMaxHoldUs`, and the whole
    /// hold stays bounded under the pacer's jitter envelope. A wedged jitter gauge
    /// can't grow the base without limit.
    static let maxAdaptiveBaseHoldUs: UInt64 = 40_000
    /// EWMA weight smoothing the per-window jitter that drives the adaptive base, so
    /// a single noisy window can't yank the base - it tracks the link's standing
    /// jitter level, not a spike (spikes drive the FAST-escalation path instead).
    static let jitterBaseEwmaWeight: Double = 0.3

    /// Consecutive degrading windows required before the FIRST escalation (and
    /// before each further step). ~3 windows ≈ ~6s of sustained degradation - a
    /// genuine trend, not a transient microburst (which the existing reorder-hold
    /// + FEC already ride out).
    static let sustainedWindows = 3
    /// Consecutive degrading windows required when the window is a HARD spike (any
    /// signal past its `*HardEscalate` threshold). A sharp onset - a sudden loss/
    /// reorder burst on a bursty VPN, shorter than the ~6s `sustainedWindows` gate
    /// - escalates after just this many windows so headroom lands DURING the burst
    /// instead of after it. Still ≥1 (never a single-sample reaction to a soft
    /// trend) and still bounded + hysteretic by the same dwell/relax guards.
    static let sustainedWindowsFast = 1
    /// HARD-spike escalate thresholds - comfortably above the soft `*Escalate`
    /// thresholds, so only a genuine sharp burst (not a slow drift) takes the fast
    /// path. Same three signals as the soft gate.
    static let jitterHardEscalateMs: Double = 16.0
    static let oooHardEscalate = 12
    static let retransmitHardEscalate = 8
    /// Consecutive CLEAN windows required before a relax step. Asymmetric with the
    /// escalate count (and paired with the lower relax thresholds below) so the
    /// controller has hysteresis and won't oscillate around a noisy boundary.
    static let clearWindows = 2

    /// Escalate threshold: recv-jitter (ms) above which a window counts as
    /// degrading. Comfortably above a healthy LAN/wifi N jitter (sub-few-ms) so
    /// normal variation never trips it.
    static let jitterEscalateMs: Double = 8.0
    /// Relax threshold: recv-jitter (ms) BELOW which a window counts as clean.
    /// Strictly below the escalate threshold → a dead band that prevents flapping.
    static let jitterRelaxMs: Double = 4.0
    /// Escalate threshold: per-window out-of-order packets above which the window
    /// counts as degrading (a reorder burst that precedes a wifi loss burst).
    static let oooEscalate = 6
    /// Relax threshold: per-window out-of-order at/below which the window is clean.
    static let oooRelax = 2
    /// Escalate threshold: per-window ENet reliable retransmits above which the
    /// window counts as degrading (the control-stream-stall precursor).
    static let retransmitEscalate = 4
    /// Relax threshold: per-window retransmits at/below which the window is clean.
    static let retransmitRelax = 1

    /// Minimum windows to dwell at a level before the next change in EITHER
    /// direction - a floor on how fast the level can move, the final anti-flap
    /// guard on top of the asymmetric counters.
    static let minDwellWindows = 2

    // MARK: - Loss axis: widen the hold on ACTUAL loss, not just jitter
    // (Rationale: the file header's LOSS AXIS note and observeLoss() below; the
    // per-field docs that follow give the cadence numbers.)

    /// Consecutive loss-active windows before a loss-axis escalation. 1 = a single
    /// window with FEC recovery / an unrecoverable frame steps the hold (still
    /// dwell-guarded) - loss bursts are sharp, sparse onsets, not slow trends, so
    /// waiting ~6s like the jitter axis would miss the burst entirely.
    static let lossEscalateWindows = 1
    /// Consecutive CLEAN windows (no recovery, no unrecoverable) before the loss
    /// axis bleeds ONE step. ~10 windows ≈ ~20s - much slower out than the jitter
    /// axis so the widened hold persists across the quiet gaps between loss bursts
    /// instead of collapsing the instant one window looks clean.
    static let lossClearWindows = 10
    /// Minimum windows between loss-axis level changes (its own anti-flap floor).
    static let lossMinDwellWindows = 2

    // MARK: - State (single-thread: the RTP receive thread, via maybeLogMetrics)

    /// Current escalation level: 0 = adaptive base, up to `maxLevel` further steps.
    private(set) var level = 0
    /// Run of consecutive degrading windows (reset by any clean/neutral window).
    private var degradingRun = 0
    /// Run of consecutive clean windows (reset by any degrading/neutral window).
    private var clearRun = 0
    /// Windows elapsed since the last level change (the dwell guard).
    private var windowsSinceChange = Int.max
    /// EWMA of the per-window recv-jitter (ms) that drives the adaptive base. 0
    /// until the first window - the base stays at the clean `baseHoldUs` floor.
    private var smoothedJitterMs: Double = 0

    /// Loss-axis escalation level (0...`maxLevel`), SEPARATE from the jitter `level`
    /// and combined with it via `max` in `holdWindowUs`. 0 on a clean link.
    private(set) var lossLevel = 0
    /// Run of consecutive loss-active windows (FEC recovery or unrecoverable seen).
    private var lossEventRun = 0
    /// Run of consecutive clean windows on the loss axis (reset by any loss).
    private var lossClearRun = 0
    /// Windows since the last loss-axis level change (its dwell guard).
    private var lossWindowsSinceChange = Int.max

    /// The level the reorder-hold actually rides: the WORSE of the jitter axis and
    /// the loss axis. `max` (not sum) keeps the total bounded at `maxHoldUs` and
    /// means a link that's both jittery and lossy doesn't double-count.
    var effectiveLevel: Int { max(level, lossLevel) }

    /// The jitter-scaled BASE hold (µs): the clean `baseHoldUs` plus a bounded
    /// widening for the link's standing jitter above `jitterBaseFloorMs`. A
    /// higher-baseline-jitter link starts with more headroom, so a short burst
    /// that escalation can't reach in time still rides a wider base. Bounded by
    /// `maxAdaptiveBaseHoldUs`.
    var adaptiveBaseHoldUs: UInt64 {
        let overFloor = smoothedJitterMs - Self.jitterBaseFloorMs
        guard overFloor > 0 else { return Self.baseHoldUs }
        let widenUs = UInt64(min(overFloor * Self.jitterBaseScaleUsPerMs,
                                 Double(Self.maxAdaptiveBaseHoldUs - Self.baseHoldUs)))
        return Self.baseHoldUs + widenUs
    }

    /// The reorder-hold window (µs) the queue should use this instant: the
    /// jitter-scaled base plus the discrete escalation level, ALWAYS hard-capped at
    /// `maxHoldUs` so the total never exceeds the pacer's jitter envelope however
    /// high the base scaled. Equals the clean `baseHoldUs` on a low-jitter,
    /// non-degrading link (byte-identical to the pre-adaptive behavior).
    var holdWindowUs: UInt64 {
        min(adaptiveBaseHoldUs + UInt64(effectiveLevel) * Self.stepUs, Self.maxHoldUs)
    }

    /// Feed one receive-metrics window's health signals and advance the level if a
    /// sustained trend warrants it. Returns true iff the level (hence the hold
    /// window) changed this call, so the caller can log the transition. Cheap:
    /// a few compares + integer bumps, once per ~2s window.
    ///
    /// - Parameters:
    ///   - recvJitterMs: the window's smoothed RFC-3550 inter-arrival jitter (ms).
    ///   - outOfOrder: genuine reorders observed this window (windowOutOfOrder).
    ///   - retransmits: ENet reliable retransmits THIS window (a delta - see the
    ///     caller; the controller never sees the monotonic total).
    @discardableResult
    mutating func observeWindow(recvJitterMs: Double, outOfOrder: Int,
                                retransmits: Int) -> Bool {
        if windowsSinceChange != Int.max { windowsSinceChange &+= 1 }

        // Track the link's STANDING jitter (EWMA) - this drives the jitter-scaled
        // base so a high-baseline-jitter link starts wider. Smoothed (not the raw
        // window) so a single spike moves the FAST-escalation path, not the base.
        let sanitizedJitter = recvJitterMs.isFinite ? max(0, recvJitterMs) : 0
        smoothedJitterMs = smoothedJitterMs <= 0
            ? sanitizedJitter
            : smoothedJitterMs + Self.jitterBaseEwmaWeight * (sanitizedJitter - smoothedJitterMs)

        let degrading = recvJitterMs >= Self.jitterEscalateMs
            || outOfOrder >= Self.oooEscalate
            || retransmits >= Self.retransmitEscalate
        // A HARD spike - any signal past its (higher) hard threshold - is a sharp
        // onset, not a soft trend. It escalates after `sustainedWindowsFast` windows
        // (vs the slower `sustainedWindows`), so headroom lands DURING a short burst.
        let hardSpike = recvJitterMs >= Self.jitterHardEscalateMs
            || outOfOrder >= Self.oooHardEscalate
            || retransmits >= Self.retransmitHardEscalate
        // A window is CLEAN only if ALL three signals are below their (lower) relax
        // thresholds - one elevated signal keeps us out of the clean run. The gap
        // between degrading and clean is the neutral dead band that resets both
        // runs, which is what stops a value hovering on the boundary from flapping.
        let clean = recvJitterMs <= Self.jitterRelaxMs
            && outOfOrder <= Self.oooRelax
            && retransmits <= Self.retransmitRelax

        if degrading {
            degradingRun &+= 1
            clearRun = 0
        } else if clean {
            clearRun &+= 1
            degradingRun = 0
        } else {
            // Neutral window: not a trend in either direction. Reset both runs so a
            // trend must be CONSECUTIVE to count (the SUSTAINED guarantee).
            degradingRun = 0
            clearRun = 0
        }

        // Dwell guard: never change level faster than minDwellWindows.
        guard windowsSinceChange >= Self.minDwellWindows else { return false }

        // A hard spike escalates on the FAST window count; a soft trend needs the
        // full sustained run. `hardSpike` implies `degrading` (its thresholds are
        // strictly higher), so a current hard spike means degradingRun is live.
        let escalateAfter = hardSpike ? Self.sustainedWindowsFast : Self.sustainedWindows
        if degradingRun >= escalateAfter, level < Self.maxLevel {
            level &+= 1
            degradingRun = 0           // require a fresh sustained run for the next step
            windowsSinceChange = 0
            return true
        }
        if clearRun >= Self.clearWindows, level > 0 {
            level -= 1                 // bleed out one step at a time
            clearRun = 0
            windowsSinceChange = 0
            return true
        }
        return false
    }

    /// RECONCILED drive. Adopt the UNIFIED jitter→headroom decision
    /// the EnvSignalController publishes instead of self-deciding from raw jitter:
    /// the published `headroomLevel` becomes this controller's `level`, and the
    /// published `smoothedJitterMs` drives the jitter-scaled base (the SAME EWMA
    /// the self-decide path used, so the base is byte-identical for a given jitter
    /// value). Returns true iff the level changed (so the caller logs it), matching
    /// `observeWindow`'s contract.
    ///
    /// THE HARD FLOORS ARE UNTOUCHED. This only sets `level`/`smoothedJitterMs`;
    /// the reorder-hold the queue actually applies is still `holdWindowUs`, which
    /// caps at `maxHoldUs` (48ms) however high the published level - the published
    /// level is itself clamped to `maxLevel` here as a belt-and-suspenders, but
    /// even an out-of-range value could not breach the cap. And the queue's
    /// `isFecRecoveryStillPossible()` gate (RtpVideoQueue+AddPacket.swift) is a
    /// SEPARATE hard floor in the add path the reconciler never reaches: a frame
    /// already mathematically unrecoverable is never held, whatever the hold window.
    ///
    /// Runs on the SAME single RTP receive thread as `observeWindow` (driven from
    /// maybeLogMetrics), off the per-datagram hot path. The published values are
    /// passed in by the caller (which read them with ONE short controller-lock
    /// pull); this method takes no lock and never calls into the reconciler.
    @discardableResult
    mutating func reconcile(headroomLevel: Int, smoothedJitterMs publishedJitterMs: Double) -> Bool {
        let sanitized = publishedJitterMs.isFinite ? max(0, publishedJitterMs) : 0
        smoothedJitterMs = sanitized
        let newLevel = min(Self.maxLevel, max(0, headroomLevel))
        let changed = newLevel != level
        level = newLevel
        return changed
    }

    /// LOSS AXIS. Feed one window's direct-loss evidence and step the
    /// SEPARATE `lossLevel` (combined with the jitter axis via `max` in
    /// `holdWindowUs`). Returns true iff `lossLevel` changed, so the caller can log
    /// it. Called every window REGARDLESS of `reconcilerEnabled` - the loss axis is
    /// orthogonal to the jitter→headroom decision and drives ONLY the reorder-hold.
    ///
    /// - Parameters:
    ///   - fecRecovered: frames the host's parity had to RECOVER this window (the
    ///     proactive signal - parity is being consumed, the link is near the edge).
    ///   - unrecoverable: frames that went UNRECOVERABLE this window (the reactive
    ///     safety net - a delta off the monotonic total; see the caller).
    ///
    /// A loss BURST is a sharp, sparse onset, so a qualifying window escalates fast
    /// (`lossEscalateWindows`, dwell-guarded) and the bleed-out is slow
    /// (`lossClearWindows`) so the widened hold rides across the gaps between
    /// bursts. A clean link (both zero) keeps `lossLevel` at 0 → byte-identical.
    /// The hold still hard-caps at `maxHoldUs`, and the queue's
    /// `isFecRecoveryStillPossible()` gate is the separate floor that never holds a
    /// mathematically-unrecoverable frame, whatever the window.
    @discardableResult
    mutating func observeLoss(fecRecovered: Int, unrecoverable: Int) -> Bool {
        if lossWindowsSinceChange != Int.max { lossWindowsSinceChange &+= 1 }
        let lossy = fecRecovered > 0 || unrecoverable > 0
        if lossy {
            lossEventRun &+= 1
            lossClearRun = 0
        } else {
            lossClearRun &+= 1
            lossEventRun = 0
        }

        guard lossWindowsSinceChange >= Self.lossMinDwellWindows else { return false }
        // An unrecoverable frame escalates immediately (a frame was actually lost -
        // react now); pure FEC-recovery activity escalates on the (still fast) event
        // run. Either way one step at a time, bounded at `maxLevel`.
        let escalate = unrecoverable > 0 || lossEventRun >= Self.lossEscalateWindows
        if escalate, lossLevel < Self.maxLevel {
            lossLevel &+= 1
            lossEventRun = 0
            lossWindowsSinceChange = 0
            return true
        }
        if lossClearRun >= Self.lossClearWindows, lossLevel > 0 {
            lossLevel -= 1                 // slow bleed, one step at a time
            lossClearRun = 0
            lossWindowsSinceChange = 0
            return true
        }
        return false
    }

    /// Reset to baseline. Called when the queue resets its per-window accumulators
    /// for a fresh session so the controller never carries a stale escalation into
    /// a new stream.
    mutating func reset() {
        level = 0
        degradingRun = 0
        clearRun = 0
        windowsSinceChange = Int.max
        smoothedJitterMs = 0
        lossLevel = 0
        lossEventRun = 0
        lossClearRun = 0
        lossWindowsSinceChange = Int.max
    }
}
