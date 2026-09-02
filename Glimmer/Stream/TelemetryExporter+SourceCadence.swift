//
//  TelemetryExporter+SourceCadence.swift
//
//  The SOURCE-CADENCE CLASSIFIER and its session-log claim. The pacer's
//  detector (SourceCadenceDetector, fed from source timestamps) reports
//  sustained under-delivery in whole-frame steps; on its own that signal is
//  AMBIGUOUS. Two measured controls, same game, save and settings at a 4K
//  240 request:
//
//    * CachyOS under load: gaps 60/40 one-or-two periods, ~169fps achieved,
//      host encode ~8.2ms against a 4.17ms budget. The host is SKIPPING
//      captures - frames the game rendered never reach the client - and the
//      stream judders.
//    * Windows: gaps 4% / 58% / 38% of one / two / three periods, ~101fps
//      achieved, host encode 3.8ms inside the budget. Nothing was skipped:
//      the game was simply slower than the request, every delivered frame is
//      one game frame, and the stream is perfectly smooth.
//
//  The detector reads under-delivery on BOTH (0.70 / 0.40 vs 0.42 / 0.99).
//  What tells them apart is Sunshine's per-frame host processing latency
//  against the frame budget (1000 / requested fps) - already collected by
//  StatsCollector and carried on the 1Hz snapshot as hostEncodeLatencyAvgMs.
//  The pacer never sees it and must not depend on it, so the decision lives
//  HERE, on the exporter's 1Hz capture, the one place both inputs meet (and
//  the session-log file sink only exists with telemetry on anyway).
//
//  Rule: the claim "host is skipping frames" requires BOTH sustained
//  under-delivery (the detector's verdict, hysteretic) AND host encode at or
//  above the frame budget (>= 105% of it), for two consecutive 1Hz ticks - a
//  host whose per-frame processing exceeds the period physically cannot keep
//  the cadence, so it skips. Sustained under-delivery with encode inside the
//  budget (< 95%) is the neutral "source rate below request - game-limited"
//  line, once - the Windows control sat at 91% and was smooth. Between 95%
//  and 105% the current verdict holds (no flapping on an encoder hovering at
//  the budget). No encode data means no claim at all. Each classification is
//  written once per under-delivery episode (a genuine change of cause inside
//  an episode - the encoder loading up mid-game - is written once more), and
//  one cleared line closes an episode that claimed something. The three
//  source_* gauges publish regardless of the verdict.
//
//  The classifier is a pure value type (unit-tested with the two controls);
//  the exporter glue below steps it per capture tick on the serial workQueue.
//

import Foundation

/// Pure 1Hz classifier: under-delivery + host encode vs budget -> the claim.
/// Value type; the exporter owns one per session in `CaptureBaselines`.
struct SourceCadenceClassifier: Sendable {

    // MARK: - Tuning

    /// Host encode at or above this fraction of the frame budget, with
    /// sustained under-delivery, is the host skipping captures: once
    /// capture-convert-encode eats more than the period, Sunshine physically
    /// cannot sustain the requested cadence. The measured skipping case sat at
    /// ~197%; 105% keeps a host at exactly its budget out of the claim.
    static let encodeOverBudgetRatio = 1.05
    /// Below this fraction the encoder is inside the budget and under-delivery
    /// is the game's own rate (the smooth Windows control sat at 91%). The
    /// 95..105% band holds whatever verdict stands, so an encoder hovering at
    /// the budget cannot flap it.
    static let encodeWithinBudgetRatio = 0.95
    /// Consecutive 1Hz ticks a verdict must hold before it is written.
    static let sustainTicks = 2

    // MARK: - Types

    enum Verdict: Sendable, Equatable {
        /// Under-delivery with encode over budget: frames the game rendered
        /// never left the host.
        case hostSkipping
        /// Under-delivery with encode inside budget: the game is slower than
        /// the request; every delivered frame is a game frame.
        case gameLimited
    }

    /// The measured inputs behind a verdict, for the log line.
    struct Evidence: Sendable, Equatable {
        var achievedFraction: Double
        var multiPeriodFraction: Double
        var maxGapPeriods: Int
        var hostEncodeAvgMs: Double
        var budgetMs: Double
        var requestedFps: Double { budgetMs > 0 ? 1000.0 / budgetMs : 0 }
        var encodeBudgetRatio: Double { budgetMs > 0 ? hostEncodeAvgMs / budgetMs : 0 }
    }

    enum Event: Sendable, Equatable {
        case classified(Verdict, Evidence)
        /// Under-delivery ended after an episode that claimed `lastVerdict`;
        /// carries the episode length and the window that cleared it.
        case cleared(lastVerdict: Verdict, durationSeconds: Double,
                     achievedFraction: Double, multiPeriodFraction: Double)
    }

    // MARK: - State

    /// The verdict written for the current episode (nil = nothing claimed).
    private(set) var verdict: Verdict?
    /// When the current under-delivery episode began (`seconds` of the first
    /// tick that saw it); NaN outside an episode.
    private(set) var episodeStartSeconds: Double = .nan
    private var overBudgetStreak = 0
    private var withinBudgetStreak = 0

    init() {}

    // MARK: - The 1Hz step

    /// Fold one capture tick. `cadence` is the pacer's latest gauge sample
    /// (nil before the first judged window or after a session reset),
    /// `hostEncodeAvgMs` the window's mean host processing latency (nil when
    /// the host reports none), `seconds` a monotonic clock for durations.
    mutating func observe(
        cadence: TelemetryCounters.SourceCadenceSnapshot?, hostEncodeAvgMs: Double?, seconds: Double
    ) -> Event? {
        guard let cadence, cadence.underDelivering else {
            return closeEpisode(cadence: cadence, seconds: seconds)
        }
        if !episodeStartSeconds.isFinite { episodeStartSeconds = seconds }
        // No encode evidence: under-delivery alone is not a claim.
        guard let encode = hostEncodeAvgMs, encode.isFinite, encode > 0,
              cadence.requestedPeriodMs.isFinite, cadence.requestedPeriodMs > 0 else {
            return nil
        }
        let ratio = encode / cadence.requestedPeriodMs
        if ratio >= Self.encodeOverBudgetRatio {
            overBudgetStreak += 1
            withinBudgetStreak = 0
        } else if ratio < Self.encodeWithinBudgetRatio {
            withinBudgetStreak += 1
            overBudgetStreak = 0
        } else {
            // The hold band: neither streak accrues, the current verdict stands.
            overBudgetStreak = 0
            withinBudgetStreak = 0
        }
        let evidence = Evidence(
            achievedFraction: cadence.achievedFraction, multiPeriodFraction: cadence.multiPeriodFraction,
            maxGapPeriods: cadence.maxGapPeriods, hostEncodeAvgMs: encode, budgetMs: cadence.requestedPeriodMs)
        if overBudgetStreak >= Self.sustainTicks, verdict != .hostSkipping {
            verdict = .hostSkipping
            return .classified(.hostSkipping, evidence)
        }
        if withinBudgetStreak >= Self.sustainTicks, verdict != .gameLimited {
            verdict = .gameLimited
            return .classified(.gameLimited, evidence)
        }
        return nil
    }

    /// Under-delivery is over (or the gauge went dark): close the episode,
    /// writing a cleared line only if it had claimed something.
    private mutating func closeEpisode(
        cadence: TelemetryCounters.SourceCadenceSnapshot?, seconds: Double
    ) -> Event? {
        let last = verdict
        let start = episodeStartSeconds
        verdict = nil
        episodeStartSeconds = .nan
        overBudgetStreak = 0
        withinBudgetStreak = 0
        guard let last else { return nil }
        return .cleared(
            lastVerdict: last, durationSeconds: start.isFinite ? seconds - start : 0,
            achievedFraction: cadence?.achievedFraction ?? .nan,
            multiPeriodFraction: cadence?.multiPeriodFraction ?? .nan)
    }
}

// MARK: - Exporter glue (1Hz capture, serial workQueue)

extension TelemetryExporter {

    /// Step the per-session classifier with this tick's gauge + host encode
    /// mean and write its (rare) verdict to the session log. On `workQueue`,
    /// once per capture - never a hot path.
    func observeSourceCadence(snap: TelemetrySnapshot, now: DispatchTime) {
        let seconds = Double(now.uptimeNanoseconds) / 1_000_000_000.0
        guard let event = Self.captureBaselines.sourceCadenceClassifier.observe(
            cadence: counters.sourceCadence, hostEncodeAvgMs: snap.hostEncodeLatencyAvgMs,
            seconds: seconds) else { return }
        Diag.notice(Self.sourceCadenceNoticeText(event), "Stream.Pacer")
    }

    /// The session-log line for a classifier event: the claim first, then the
    /// measured evidence on both axes (delivery and encode vs budget) so a
    /// postmortem can check the verdict against the numbers. Pure formatting.
    static func sourceCadenceNoticeText(_ event: SourceCadenceClassifier.Event) -> String {
        func percent(_ fraction: Double) -> String {
            fraction.isFinite ? String(format: "%.0f", fraction * 100) : "n/a"
        }
        switch event {
        case let .classified(verdict, evidence):
            let delivery = "source \(percent(evidence.achievedFraction))% of "
                + "\(String(format: "%.0f", evidence.requestedFps)) fps "
                + "(\(percent(evidence.multiPeriodFraction))% multi-period gaps, max gap "
                + "\(evidence.maxGapPeriods))"
            let encode = "host encode \(String(format: "%.1f", evidence.hostEncodeAvgMs)) ms"
            let budget = "\(String(format: "%.1f", evidence.budgetMs)) ms frame budget"
            switch verdict {
            case .hostSkipping:
                return "Host is skipping frames - \(delivery) with \(encode) against a \(budget): "
                    + "capture/encode over budget on the host, so frames the game rendered never "
                    + "left it; the judder is in the delivered content, presentation is unchanged"
            case .gameLimited:
                return "Source rate below request - game-limited: \(delivery) with \(encode) "
                    + "within the \(budget); every delivered frame is a game frame, nothing skipped"
            }
        case let .cleared(lastVerdict, duration, achieved, multi):
            let cause = lastVerdict == .hostSkipping ? "host skipping frames" : "game-limited"
            return "Source back at the requested rate after \(String(format: "%.0f", duration))s "
                + "(was: \(cause)) - source \(percent(achieved))% of the requested rate, "
                + "\(percent(multi))% multi-period gaps"
        }
    }
}
