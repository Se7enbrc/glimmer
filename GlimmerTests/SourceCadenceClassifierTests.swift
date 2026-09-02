//
//  SourceCadenceClassifierTests.swift
//
//  The source-cadence CLASSIFIER: the pure 1Hz rule that turns the pacer's
//  sustained under-delivery verdict plus host encode time against the frame
//  budget into the session-log claim. Two measured controls, same game, save
//  and settings at a 4K 240 request: CachyOS under load (source gaps 60/40
//  one-or-two periods, ~169fps achieved, host encode ~8.2ms against a 4.17ms
//  budget - the host SKIPPING captures, juddery) and Windows (gaps 4% / 58% /
//  38% of one / two / three periods, ~101fps achieved, host encode 3.8ms
//  inside the budget - the game simply SLOWER than the request, every
//  delivered frame a game frame, perfectly smooth). The multi-period signal
//  reads under-delivery on both; only host encode tells them apart.
//

import Foundation
import Testing
@testable import Glimmer

struct SourceCadenceClassifierTests {

    typealias Snapshot = TelemetryCounters.SourceCadenceSnapshot
    typealias Classifier = SourceCadenceClassifier

    /// Drive the real detector over 20s of a gap mix at a 240 request and hand
    /// back the gauge sample the pacer would publish - the classifier's input.
    static func sample(mix: [(gap: Int, weight: Double)], seed: UInt64) -> Snapshot {
        let nominalHz = 240.0
        let gaps = SourceCadenceDetectorTests.mix(mix, seconds: 20, nominalHz: nominalHz, seed: seed)
        let result = SourceCadenceDetectorTests.run(nominalHz: nominalHz, gaps: gaps, jitterPeriods: 0.15)
        #expect(result.detector.underDelivering, "the mix must read as under-delivery")
        let stats = result.detector.lastStats ?? SourceCadenceDetector.Stats()
        return Snapshot(
            achievedFraction: stats.achievedFraction, multiPeriodFraction: stats.multiPeriodFraction,
            maxGapPeriods: stats.maxGapPeriods, underDelivering: result.detector.underDelivering,
            requestedPeriodMs: 1000.0 / nominalHz)
    }

    static let cachyOSMix: [(gap: Int, weight: Double)] = [(1, 0.60), (2, 0.40)]
    static let windowsMix: [(gap: Int, weight: Double)] = [(1, 0.04), (2, 0.58), (3, 0.38)]

    /// Step the classifier `ticks` times at 1Hz with a constant encode time.
    static func step(
        _ classifier: inout Classifier, cadence: Snapshot?, encodeMs: Double?, ticks: Int, from seconds: Double
    ) -> [Classifier.Event] {
        var events: [Classifier.Event] = []
        for tick in 0..<ticks {
            if let event = classifier.observe(
                cadence: cadence, hostEncodeAvgMs: encodeMs, seconds: seconds + Double(tick)) {
                events.append(event)
            }
        }
        return events
    }

    // MARK: - The two measured controls

    @Test func cachyOSMixWithEncodeOverBudgetIsHostSkipping() {
        let cadence = Self.sample(mix: Self.cachyOSMix, seed: 11)
        #expect(abs(cadence.achievedFraction - 0.70) < 0.05)
        var classifier = Classifier()
        let events = Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 10, from: 100)
        #expect(events.count == 1, "one claim per episode: \(events)")
        guard case let .classified(verdict, evidence)? = events.first else {
            Issue.record("expected a classification, got \(events)")
            return
        }
        #expect(verdict == .hostSkipping)
        #expect(classifier.verdict == .hostSkipping)
        #expect(abs(evidence.hostEncodeAvgMs - 8.2) < 0.001)
        #expect(abs(evidence.budgetMs - 4.1667) < 0.01)
        #expect(evidence.encodeBudgetRatio > 1.9)
        let text = TelemetryExporter.sourceCadenceNoticeText(events[0])
        #expect(text.hasPrefix("Host is skipping frames"), "\(text)")
        #expect(text.contains("8.2 ms") && text.contains("4.2 ms"), "\(text)")
        #expect(text.contains("240 fps"), "\(text)")
    }

    @Test func windowsMixWithEncodeInsideBudgetIsGameLimited() {
        let cadence = Self.sample(mix: Self.windowsMix, seed: 13)
        #expect(abs(cadence.achievedFraction - 0.427) < 0.04, "\(cadence.achievedFraction)")
        #expect(cadence.multiPeriodFraction > 0.9)
        #expect(cadence.maxGapPeriods == 3)
        var classifier = Classifier()
        let events = Self.step(&classifier, cadence: cadence, encodeMs: 3.8, ticks: 30, from: 100)
        #expect(events.count == 1, "one neutral line per episode, never the skipping claim: \(events)")
        guard case let .classified(verdict, evidence)? = events.first else {
            Issue.record("expected a classification, got \(events)")
            return
        }
        #expect(verdict == .gameLimited)
        #expect(classifier.verdict == .gameLimited)
        #expect(evidence.encodeBudgetRatio < Classifier.encodeOverBudgetRatio)
        let text = TelemetryExporter.sourceCadenceNoticeText(events[0])
        #expect(text.hasPrefix("Source rate below request - game-limited"), "\(text)")
        #expect(!text.lowercased().contains("skipping frames"), "\(text)")
        #expect(text.contains("3.8 ms") && text.contains("within"), "\(text)")
    }

    // MARK: - The rule's edges

    /// The claim needs two consecutive 1Hz ticks of evidence: one tick says
    /// nothing, so a single noisy encode sample cannot mint a claim.
    @Test func claimRequiresSustainedEvidence() {
        let cadence = Self.sample(mix: Self.cachyOSMix, seed: 11)
        var classifier = Classifier()
        #expect(Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 1, from: 0).isEmpty)
        #expect(classifier.verdict == nil)
        #expect(Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 1, from: 1).count == 1)
    }

    /// Without host encode data (a host that does not report it) the
    /// classifier says nothing - under-delivery alone is not a claim.
    @Test func noEncodeEvidenceSaysNothing() {
        let cadence = Self.sample(mix: Self.cachyOSMix, seed: 11)
        var classifier = Classifier()
        #expect(Self.step(&classifier, cadence: cadence, encodeMs: nil, ticks: 10, from: 0).isEmpty)
        #expect(Self.step(&classifier, cadence: cadence, encodeMs: 0, ticks: 10, from: 10).isEmpty)
        #expect(classifier.verdict == nil)
        // ...and clearing an episode that never claimed anything is silent too.
        var clear = cadence
        clear.underDelivering = false
        #expect(Self.step(&classifier, cadence: clear, encodeMs: 3.0, ticks: 3, from: 20).isEmpty)
    }

    /// A claimed episode ends with one cleared line naming the last verdict
    /// and how long the episode ran.
    @Test func clearedReportsTheLastVerdictAndDuration() {
        let cadence = Self.sample(mix: Self.cachyOSMix, seed: 11)
        var classifier = Classifier()
        _ = Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 5, from: 100)
        var clear = cadence
        clear.achievedFraction = 0.99
        clear.multiPeriodFraction = 0.01
        clear.underDelivering = false
        let events = Self.step(&classifier, cadence: clear, encodeMs: 2.0, ticks: 5, from: 185)
        #expect(events.count == 1, "\(events)")
        guard case let .cleared(lastVerdict, duration, achieved, _)? = events.first else {
            Issue.record("expected cleared, got \(events)")
            return
        }
        #expect(lastVerdict == .hostSkipping)
        #expect(abs(duration - 85.0) < 0.001)
        #expect(abs(achieved - 0.99) < 0.001)
        #expect(classifier.verdict == nil)
        let text = TelemetryExporter.sourceCadenceNoticeText(events[0])
        #expect(text.hasPrefix("Source back at the requested rate after 85"), "\(text)")
        #expect(text.contains("host skipping frames"), "\(text)")
        // A gauge going dark mid-episode (session reset) also closes it.
        _ = Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 3, from: 200)
        let dark = Self.step(&classifier, cadence: nil, encodeMs: nil, ticks: 2, from: 203)
        #expect(dark.count == 1)
    }

    /// Host encode hovering just under the budget does not flip a skipping
    /// verdict back to game-limited (the 95..105% band holds); inside the
    /// budget does, after two ticks.
    @Test func encodeHysteresisBandHolds() {
        let cadence = Self.sample(mix: Self.cachyOSMix, seed: 11)
        var classifier = Classifier()
        _ = Self.step(&classifier, cadence: cadence, encodeMs: 8.2, ticks: 3, from: 0)
        #expect(classifier.verdict == .hostSkipping)
        // 4.1ms at a 4.17ms budget = 0.98: inside the band, no change.
        #expect(Self.step(&classifier, cadence: cadence, encodeMs: 4.1, ticks: 10, from: 3).isEmpty)
        #expect(classifier.verdict == .hostSkipping)
        // 3.0ms = 0.72: inside the budget, reclassified once.
        let events = Self.step(&classifier, cadence: cadence, encodeMs: 3.0, ticks: 10, from: 13)
        #expect(events.count == 1)
        #expect(classifier.verdict == .gameLimited)
        // And the encoder loading up again re-raises the claim, once.
        let reload = Self.step(&classifier, cadence: cadence, encodeMs: 4.5, ticks: 10, from: 23)
        #expect(reload.count == 1)
        #expect(classifier.verdict == .hostSkipping)
    }
}
