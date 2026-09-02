//
//  FramePacer+SourceCadence.swift
//
//  The pacer's SOURCE-CADENCE telemetry: the lock-guarded state group that
//  owns the pure `SourceCadenceDetector`, the submit-path feed, and the
//  OFF-LOCK publish (the exporter gauge + the rate-limited session-log
//  notices that name the HOST as the cause of a juddery stream). Split out by
//  topic like the rest of the FramePacer extensions; the stored
//  `sourceCadence` property itself is declared in FramePacer.swift with the
//  core state (an extension cannot hold stored properties).
//
//  This is observability ONLY. The presentation path (due gate, trim,
//  backoff, watchdog, cadence-error metric) does not read any of it: a
//  presentation-side lock onto a slower grid was built on this signal, judged
//  live (a flat 120Hz metronome that felt no better, +8ms glass-to-glass,
//  sample-and-hold on a 240Hz panel) and removed - the judder is in the
//  content, an uncapped game sampled irregularly by a host that skips
//  captures, and presentation cannot fix that. What the client CAN do is say
//  so: the measured evidence (achieved % of the requested rate, multi-period
//  gap %, max gap) lands on every exporter row and, on the sustained edges,
//  in the glimmer-*.log file sink where a postmortem reads it.
//
//  Threading: `noteSourceTimestampDeltaLocked` runs on the decode queue under
//  the pacer lock (a handful of integer adds per frame; the detector's window
//  evaluation is 4x per second); the publish + notices run OFF the lock via
//  the returned event, exactly like the tick-deficit events (the gauge and
//  LogStore take their own locks). No allocation per frame anywhere.
//

import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - Tuning

    /// Minimum seconds between Diag NOTICE lines for signal transitions. The
    /// detector's own sustain/hysteresis already spaces transitions seconds
    /// apart; this is the belt-and-braces bound so a pathological source can
    /// never turn the session log into a flood. Suppressed lines are counted
    /// and reported on the next one that logs.
    static let sourceCadenceNoticeMinInterval: CFTimeInterval = 5.0

    // MARK: - State (guarded by `lock`)

    /// Source-cadence state group (guarded by `lock`).
    struct SourceCadenceState {
        /// The pure detector, fed every consecutive source-timestamp delta.
        var detector: SourceCadenceDetector
        /// When the under-delivery signal last came on (for the cleared notice).
        var detectedAtHostTime: CFTimeInterval = .nan
        /// Notice rate-limit clock + the count suppressed since the last logged line.
        var lastNoticeHostTime: CFTimeInterval = .nan
        var noticesSuppressed = 0

        init(nominalPeriodSeconds: Double) {
            detector = SourceCadenceDetector(nominalPeriodSeconds: nominalPeriodSeconds)
        }
    }

    /// The off-lock work one window evaluation produced: the stats to publish
    /// and, on a transition, the notice bookkeeping (the same discipline as
    /// `TickDeficitEvent`: decided under the lock, acted on off it).
    struct SourceCadenceEvent {
        let stats: SourceCadenceDetector.Stats
        let transition: SourceCadenceDetector.Transition?
        /// Seconds the signal had been on (a cleared transition; 0 otherwise).
        let durationSeconds: Double
        /// Whether this transition may log a NOTICE (rate limit), and how many
        /// were suppressed since the last one that did.
        let logNotice: Bool
        let suppressedNotices: Int
    }

    // MARK: - Feed (decode queue, under `lock`)

    /// The submit path's single entry point: every consecutive source-
    /// timestamp delta, a >1s stall included (the detector's window veto must
    /// SEE a stall to refuse to read one as skipping); a non-positive delta is
    /// a discontinuity the detector resets on. Returns the off-lock work (an
    /// evaluation lands 4x per second; nil on every other frame). The clock is
    /// read only on a transition - never on the per-frame path.
    func noteSourceTimestampDeltaLocked(_ deltaSeconds: Double) -> SourceCadenceEvent? {
        assertLockHeld()
        guard let evaluation = sourceCadence.detector.observe(deltaSeconds: deltaSeconds) else { return nil }
        guard let transition = evaluation.transition else {
            return SourceCadenceEvent(
                stats: evaluation.stats, transition: nil, durationSeconds: 0,
                logNotice: false, suppressedNotices: 0)
        }
        let now = CFAbsoluteTimeGetCurrent()
        var duration = 0.0
        switch transition {
        case .detected:
            sourceCadence.detectedAtHostTime = now
        case .cleared:
            duration = sourceCadence.detectedAtHostTime.isFinite ? now - sourceCadence.detectedAtHostTime : 0
            sourceCadence.detectedAtHostTime = .nan
        }
        let allowed = !sourceCadence.lastNoticeHostTime.isFinite
            || now - sourceCadence.lastNoticeHostTime >= FramePacer.sourceCadenceNoticeMinInterval
        var suppressed = 0
        if allowed {
            sourceCadence.lastNoticeHostTime = now
            suppressed = sourceCadence.noticesSuppressed
            sourceCadence.noticesSuppressed = 0
        } else {
            sourceCadence.noticesSuppressed += 1
        }
        return SourceCadenceEvent(
            stats: evaluation.stats, transition: transition, durationSeconds: duration,
            logNotice: allowed, suppressedNotices: suppressed)
    }

    /// Pacer restart (`stop()`): a fresh detector - a restart is a new source
    /// era, and an inherited window must never judge the next link's frames.
    func resetSourceCadenceLocked() {
        assertLockHeld()
        sourceCadence = SourceCadenceState(nominalPeriodSeconds: configuredFrameIntervalSeconds)
    }

    // MARK: - Publish (OFF the lock)

    /// Publish the window stats to the exporter gauge (`source_achieved_frac`
    /// / `source_multi_period_frac` / `source_max_gap_periods`) and, on a
    /// transition, write the rate-limited NOTICE that names the host. Callable
    /// from any thread; never under the pacer lock (the gauge and LogStore
    /// take their own). Takes the optional the submit path carries so the
    /// common no-evaluation frame is one nil check.
    func handleSourceCadenceEvent(_ event: SourceCadenceEvent?) {
        guard let event else { return }
        assertLockNotHeld()
        if event.stats.achievedFraction.isFinite {
            TelemetryCounters.shared.setSourceCadence(TelemetryCounters.SourceCadenceSnapshot(
                achievedFraction: event.stats.achievedFraction,
                multiPeriodFraction: event.stats.multiPeriodFraction,
                maxGapPeriods: event.stats.maxGapPeriods))
        }
        guard let transition = event.transition, event.logNotice else { return }
        // `configuredFrameIntervalSeconds` is immutable - the nominal rate is
        // read from it, never from the lock-guarded detector, off the lock.
        let nominalHz = configuredFrameIntervalSeconds > 0 ? 1.0 / configuredFrameIntervalSeconds : 0
        Diag.notice(Self.sourceCadenceNoticeText(transition, event: event, nominalHz: nominalHz), "Stream.Pacer")
    }

    /// The NOTICE text for a transition: the measured evidence (achieved % of
    /// the requested rate, multi-period %, max gap) that justified it, and the
    /// span on a clear. Pure formatting, kept off the hot path.
    static func sourceCadenceNoticeText(
        _ transition: SourceCadenceDetector.Transition, event: SourceCadenceEvent, nominalHz: Double
    ) -> String {
        let stats = event.stats
        let achieved = String(format: "%.0f", stats.achievedFraction * 100)
        let multi = String(format: "%.0f", stats.multiPeriodFraction * 100)
        let nominal = String(format: "%.0f", nominalHz)
        let evidence = "source \(achieved)% of \(nominal) fps, \(multi)% multi-period gaps, "
            + "max gap \(stats.maxGapPeriods)"
        let suppressed = event.suppressedNotices > 0
            ? " [\(event.suppressedNotices) transition(s) since the last notice not logged]" : ""
        switch transition {
        case .detected:
            return "FramePacer: host is skipping frames - \(evidence) - capture/encode over budget "
                + "on the host; the judder is in the delivered content, presentation is unchanged\(suppressed)"
        case .cleared:
            let span = String(format: "%.1f", event.durationSeconds)
            return "FramePacer: host frame skipping cleared after \(span)s - \(evidence)\(suppressed)"
        }
    }
}
