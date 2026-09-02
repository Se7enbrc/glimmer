//
//  FramePacer+CadenceLock.swift
//
//  The pacer side of the SOURCE-CADENCE LOCK: the lock-guarded state group,
//  the submit-path feed into the pure `SourceCadenceDetector`, the present-
//  side rules the due gate / trim / backoff consult while a lock is engaged,
//  the liveness-snapshot gauge, and the OFF-LOCK transition breadcrumbs.
//  Split out by topic like the rest of the FramePacer extensions; the stored
//  `cadenceLock` property itself is declared in FramePacer.swift with the core
//  state (an extension cannot hold stored properties).
//
//  The problem this closes (measured, 388k frames of a Cyberpunk 4K240
//  session): when the host GPU is loaded, Sunshine's capture-convert-encode
//  overruns the 4.17ms budget and SKIPS capture frames - source gaps of 1
//  period 59.9% / 2 periods 40.1%, ~169fps achieved - and the pacer reproduced
//  that irregularity on screen (present gaps 72% one period / 27% two). Its
//  only adaptive input, RFC 3550 transit jitter, cannot see this: timestamps
//  and arrivals stretch together, jitter reads ~0, depth correctly rests at
//  1. The pacer was structurally blind to source under-delivery.
//
//  The lock is client-side and host-agnostic. The detector (see
//  SourceCadenceDetector.swift for the model, thresholds and staircase) reads
//  the source-timestamp deltas the pacer already learns cadence from, and when
//  the host is SUSTAINEDLY under-delivering in period-multiple steps it picks
//  a divisor k of the REQUESTED rate and a reserve cushion. While engaged:
//
//    * the due gate releases on every k-th refresh of the requested rate (the
//      grid interval is k x the nominal period - NOT k x the PTS-refined
//      interval, which a uniformly-halved source would already have doubled);
//      between grid ticks the head is deliberately HELD (`heldForGrid`), which
//      the starvation failsafe must not read as a wedge;
//    * the trim ceiling is `max(jitter depth, cushion) + 1` - additive and
//      explicit with the adaptive jitter buffer, so a wifi link that also
//      skips keeps its measured jitter depth and a clean link holds exactly
//      the reserve the source gaps need. Frames arriving faster than the grid
//      drop-to-newest exactly as today (counted as presentation-late drops AND
//      on the lock's own drop counter, so the two can be told apart);
//    * the over-target short-circuit changes shape, not purpose: a backlog
//      above the trim ceiling (only reachable inside gap recovery, where the
//      ceiling lifts to the cap) still force-drains at one per vsync; a full
//      reserve at `cushion + 1` is the DESIGNED state, not a backlog, and
//      waits for the grid. The grid guarantees a release every k ticks, so the
//      not-due latch the short-circuit exists to break cannot form;
//    * the present-loop backoff, the on-grid anchor and the cadence-error
//      metric all measure against the LOCKED grid interval, so a locked stream
//      reads near-zero cadence error and the backoff never mistakes a normal
//      k-tick wait for hopeless lateness.
//
//  Passthrough is untouched: `divisor == 1` short-circuits every rule above to
//  the pre-existing code path byte-for-byte, and the detector only ever
//  engages on the structured multi-period signal (a 99% one-period stream
//  never engages). The freeze-recovery watchdog, the tick-deficit machinery
//  and the present-stall protections are unaffected: the longest grid this
//  lock can produce (nominal / 5, floor 30Hz) is ~33ms, an order of magnitude
//  under the watchdog's 250ms present-stall trip.
//
//  Threading: `observeSourceGapLocked` / `resetSourceCadenceLocked` run on the
//  decode queue under the pacer lock (a handful of integer adds per frame; the
//  window evaluation is 4x per second); the present-side helpers run on the
//  pacing queue under the same lock; transition breadcrumbs (Diag/LogStore
//  takes its own lock) run OFF the lock via the returned event, exactly like
//  the tick-deficit events. No allocation per frame anywhere on the path.
//

import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - Tuning

    /// Minimum seconds between Diag NOTICE lines for lock transitions. The
    /// detector's own sustain/hysteresis already spaces transitions seconds
    /// apart; this is the belt-and-braces bound so a pathological source can
    /// never turn the session log into a transition flood. Suppressed lines are
    /// counted and reported on the next one that logs.
    static let cadenceLockNoticeMinInterval: CFTimeInterval = 5.0

    // MARK: - State (guarded by `lock`)

    /// Cadence-lock state group (guarded by `lock`).
    struct CadenceLockState {
        /// The pure detector, fed every consecutive source-timestamp delta.
        var detector: SourceCadenceDetector
        /// 1 = passthrough (every rule short-circuits to the pre-lock path);
        /// k >= 2 = present on every k-th refresh of the requested rate.
        var divisor = 1
        /// Reserve frames held while engaged (0 in passthrough).
        var cushion = 0
        /// Engage bookkeeping for the disengage breadcrumb (duration + releases).
        var engagedAtHostTime: CFTimeInterval = .nan
        var engageReleaseCount: UInt64 = 0
        /// Notice rate-limit clock + the count suppressed since the last logged line.
        var lastNoticeHostTime: CFTimeInterval = .nan
        var noticesSuppressed = 0

        init(nominalPeriodSeconds: Double) {
            detector = SourceCadenceDetector(nominalPeriodSeconds: nominalPeriodSeconds)
        }

        var isEngaged: Bool { divisor > 1 }
    }

    /// The lock as the liveness snapshot / exporter see it. `divisor` is 0 in
    /// passthrough and k while engaged (the telemetry contract: "0 or k");
    /// the fractions are NaN until the detector's window has judged once.
    struct CadenceLockSnapshot: Sendable {
        let divisor: Int
        let cushion: Int
        let achievedFraction: Double
        let multiPeriodFraction: Double
        let maxGapPeriods: Int

        static let passthrough = CadenceLockSnapshot(
            divisor: 0, cushion: 0, achievedFraction: .nan, multiPeriodFraction: .nan, maxGapPeriods: 0)
    }

    /// One lock transition, surfaced from under the lock so the breadcrumb +
    /// counters run OFF it (the same discipline as `TickDeficitEvent`).
    struct CadenceLockEvent {
        enum Kind { case engaged, retuned, disengaged }
        let kind: Kind
        /// The lock before / after (nil = passthrough on that side).
        let from: SourceCadenceDetector.Lock?
        let to: SourceCadenceDetector.Lock?
        let stats: SourceCadenceDetector.Stats
        /// Seconds the previous lock was engaged and the frames released
        /// under it (0 on an engage).
        let durationSeconds: Double
        let releasesDuringLock: UInt64
        let depth: Int
        /// Whether this transition may log a NOTICE (rate limit), and how many
        /// were suppressed since the last one that did.
        let logNotice: Bool
        let suppressedNotices: Int
    }

    // MARK: - Feed (decode queue, under `lock`)

    /// The submit path's single entry point: a positive delta is observed
    /// (a >1s stall included - the window veto must see it); a non-positive
    /// one is a timestamp discontinuity (IDR PTS reset / reorder) that resets
    /// the window and stands any engaged lock down.
    func noteSourceTimestampDeltaLocked(_ deltaSeconds: Double) -> CadenceLockEvent? {
        deltaSeconds > 0
            ? observeSourceGapLocked(deltaSeconds: deltaSeconds)
            : resetSourceCadenceLocked()
    }

    /// Feed one positive source-timestamp delta to the detector and mirror any
    /// resulting transition into the present-side fields. Returns the event to
    /// hand to `handleCadenceLockEvent` OFF the lock. Per-frame cost: the
    /// detector's integer adds; the clock is read only on a transition.
    func observeSourceGapLocked(deltaSeconds: Double) -> CadenceLockEvent? {
        assertLockHeld()
        let transition = cadenceLock.detector.observe(deltaSeconds: deltaSeconds)
        return syncCadenceLockLocked(transitionStats: transition.map(Self.stats(of:)))
    }

    /// A source-timestamp discontinuity (IDR PTS reset / reorder): the window
    /// is meaningless across it, so the detector forgets everything and any
    /// engaged lock stands down - a new source era must re-prove itself.
    func resetSourceCadenceLocked() -> CadenceLockEvent? {
        assertLockHeld()
        cadenceLock.detector.reset()
        return syncCadenceLockLocked(transitionStats: nil)
    }

    /// Pacer restart (`stop()`): back to passthrough with a fresh detector.
    func resetCadenceLockLocked() {
        assertLockHeld()
        cadenceLock = CadenceLockState(nominalPeriodSeconds: configuredFrameIntervalSeconds)
    }

    private static func stats(of transition: SourceCadenceDetector.Transition) -> SourceCadenceDetector.Stats {
        switch transition {
        case let .engaged(_, stats), let .retuned(_, _, stats), let .disengaged(_, stats):
            return stats
        }
    }

    /// Reconcile the present-side fields with the detector's lock BY DIFF (not
    /// by transition), so the two can never drift apart - whatever path moved
    /// the detector (observe, reset), the pacer mirrors it here. Under `lock`.
    private func syncCadenceLockLocked(transitionStats: SourceCadenceDetector.Stats?) -> CadenceLockEvent? {
        let target = cadenceLock.detector.lock
        let wasEngaged = cadenceLock.isEngaged
        let previous = wasEngaged
            ? SourceCadenceDetector.Lock(divisor: cadenceLock.divisor, cushion: cadenceLock.cushion) : nil
        let kind: CadenceLockEvent.Kind
        if let target {
            guard target != previous else { return nil }
            kind = wasEngaged ? .retuned : .engaged
            cadenceLock.divisor = target.divisor
            cadenceLock.cushion = target.cushion
        } else {
            guard wasEngaged else { return nil }
            kind = .disengaged
            cadenceLock.divisor = 1
            cadenceLock.cushion = 0
        }
        // Transitions are rare (seconds apart by construction) - one clock read
        // here, never on the per-frame path.
        let now = CFAbsoluteTimeGetCurrent()
        let duration = cadenceLock.engagedAtHostTime.isFinite ? now - cadenceLock.engagedAtHostTime : 0
        let releases = wasEngaged ? liveness.releaseCount &- cadenceLock.engageReleaseCount : 0
        if kind == .engaged {
            cadenceLock.engagedAtHostTime = now
            cadenceLock.engageReleaseCount = liveness.releaseCount
        } else if kind == .disengaged {
            cadenceLock.engagedAtHostTime = .nan
            cadenceLock.engageReleaseCount = 0
        }
        let allowed = !cadenceLock.lastNoticeHostTime.isFinite
            || now - cadenceLock.lastNoticeHostTime >= FramePacer.cadenceLockNoticeMinInterval
        var suppressed = 0
        if allowed {
            cadenceLock.lastNoticeHostTime = now
            suppressed = cadenceLock.noticesSuppressed
            cadenceLock.noticesSuppressed = 0
        } else {
            cadenceLock.noticesSuppressed += 1
        }
        return CadenceLockEvent(
            kind: kind, from: previous, to: target,
            stats: transitionStats ?? cadenceLock.detector.lastStats ?? SourceCadenceDetector.Stats(),
            durationSeconds: duration, releasesDuringLock: releases, depth: queue.count,
            logNotice: allowed, suppressedNotices: suppressed)
    }

    // MARK: - Present-side rules (pacing queue, under `lock`)

    /// The interval the due gate, backoff, on-grid anchor and cadence-error
    /// metric pace against: the LOCKED grid (k x the nominal period) while
    /// engaged, the PTS-refined stream interval in passthrough - the exact
    /// pre-lock value, so passthrough behavior is unchanged.
    @inline(__always)
    func pacingIntervalLocked() -> Double {
        cadenceLock.divisor > 1
            ? configuredFrameIntervalSeconds * Double(cadenceLock.divisor)
            : streamFrameIntervalSeconds
    }

    /// The trim / due-gate target while engaged: the adaptive jitter depth OR
    /// the lock's reserve cushion, whichever is deeper (additive, explicit).
    /// Passthrough returns the jitter depth untouched.
    @inline(__always)
    func effectiveTargetLocked(jitterTarget: Int) -> Int {
        cadenceLock.divisor > 1 ? max(jitterTarget, cadenceLock.cushion) : jitterTarget
    }

    /// The due-gate verdict while a lock is engaged. See the header for why a
    /// full reserve waits for the grid while an over-ceiling backlog drains.
    struct GridVerdict {
        let due: Bool
        let heldForGrid: Bool
        let forcedOverTarget: Bool
    }

    /// Decide whether the head is due on the LOCKED grid. `sinceLast` is the
    /// display time since the last present (finite, non-negative, sane - the
    /// timebase clamp in the caller owns the rest). Under `lock`.
    func gridDueLocked(sinceLast: CFTimeInterval, vsyncInterval: CFTimeInterval, effectiveTarget: Int) -> GridVerdict {
        // Above the trim ceiling: a genuine drainable backlog (gap-recovery
        // catch-up, where the ceiling lifts to the cap). Holding is always
        // wrong - drain at one per vsync until it is back under the ceiling,
        // then the grid resumes. Same signal the over-target counter reports.
        if queue.count > effectiveTarget + 1 {
            return GridVerdict(due: true, heldForGrid: false, forcedOverTarget: true)
        }
        // On the grid: the same half-vsync slack the passthrough gate uses, so
        // a grid tick that lands a hair early still presents on that vsync.
        let due = sinceLast >= pacingIntervalLocked() - vsyncInterval * 0.5
        return GridVerdict(due: due, heldForGrid: !due, forcedOverTarget: false)
    }

    /// The gauge the liveness snapshot carries to the exporter. Under `lock`.
    func cadenceLockSnapshotLocked() -> CadenceLockSnapshot {
        let stats = cadenceLock.detector.lastStats
        return CadenceLockSnapshot(
            divisor: cadenceLock.isEngaged ? cadenceLock.divisor : 0,
            cushion: cadenceLock.isEngaged ? cadenceLock.cushion : 0,
            achievedFraction: stats?.achievedFraction ?? .nan,
            multiPeriodFraction: stats?.multiPeriodFraction ?? .nan,
            maxGapPeriods: stats?.maxGapPeriods ?? 0)
    }

    // MARK: - Breadcrumbs + counters (OFF the lock)

    /// Count the transition, mark the profile, and (rate-limited) write the
    /// NOTICE with the measured stats that justified it - the postmortem-
    /// visible line that lets a session log answer "did the lock engage, on
    /// what evidence, and for how long". Callable from any thread; never
    /// under the pacer lock (LogStore takes its own). Takes the optional the
    /// submit path carries so the common no-transition frame is one nil check.
    func handleCadenceLockEvent(_ event: CadenceLockEvent?) {
        guard let event else { return }
        assertLockNotHeld()
        let counters = TelemetryCounters.shared
        switch event.kind {
        case .engaged: counters.cadenceLockEngageTotal.increment()
        case .disengaged: counters.cadenceLockDisengageTotal.increment()
        case .retuned: break
        }
        let toDivisor = event.to?.divisor ?? 0
        OSSignposter.render.emitEvent(
            "PacerCadenceLock",
            "divisor=\(toDivisor, privacy: .public) cushion=\(event.to?.cushion ?? 0, privacy: .public) depth=\(event.depth, privacy: .public)")
        guard event.logNotice else { return }
        // `configuredFrameIntervalSeconds` is immutable - the nominal rate is
        // read from it, never from the lock-guarded detector, off the lock.
        let nominalHz = configuredFrameIntervalSeconds > 0 ? 1.0 / configuredFrameIntervalSeconds : 0
        Diag.notice(Self.cadenceLockNoticeText(event, nominalHz: nominalHz), "Stream.Pacer")
    }

    /// The NOTICE text for a transition: achieved %, multi-period %, max gap,
    /// the chosen k (as a grid rate) and cushion, plus the engaged span on a
    /// disengage. Pure formatting, kept off the hot path.
    static func cadenceLockNoticeText(_ event: CadenceLockEvent, nominalHz: Double) -> String {
        let stats = event.stats
        // A discontinuity-forced disengage carries no window (the detector was
        // reset) - say so rather than printing NaN.
        func percent(_ fraction: Double) -> String {
            fraction.isFinite ? String(format: "%.1f", fraction * 100) : "n/a"
        }
        let achieved = percent(stats.achievedFraction)
        let multi = percent(stats.multiPeriodFraction)
        let nominal = String(format: "%.0f", nominalHz)
        let evidence = "source \(achieved)% of \(nominal)fps requested, \(multi)% multi-period gaps, "
            + "max gap \(stats.maxGapPeriods) period(s)"
        func describe(_ lock: SourceCadenceDetector.Lock) -> String {
            let grid = String(format: "%.1f", nominalHz / Double(lock.divisor))
            return "every \(lock.divisor)th refresh (\(grid)Hz grid), cushion \(lock.cushion) frame(s)"
        }
        let suppressed = event.suppressedNotices > 0
            ? " [\(event.suppressedNotices) transition(s) since the last notice not logged]" : ""
        let span = String(format: "%.1f", event.durationSeconds)
        switch event.kind {
        case .engaged:
            let to = event.to.map(describe) ?? "?"
            return "FramePacer cadence lock ENGAGED - \(evidence) -> presenting on \(to)\(suppressed)"
        case .retuned:
            let from = event.from.map(describe) ?? "?"
            let to = event.to.map(describe) ?? "?"
            return "FramePacer cadence lock RETUNED - \(evidence) -> \(from) becomes \(to) "
                + "after \(span)s (\(event.releasesDuringLock) frames released on the old grid)\(suppressed)"
        case .disengaged:
            let from = event.from.map(describe) ?? "?"
            return "FramePacer cadence lock DISENGAGED after \(span)s on \(from) "
                + "(\(event.releasesDuringLock) frames released) - \(evidence); back to passthrough\(suppressed)"
        }
    }
}
