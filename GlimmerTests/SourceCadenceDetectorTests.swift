//
//  SourceCadenceDetectorTests.swift
//
//  The source-cadence detector - the pure telemetry signal that names a host
//  sustainedly skipping frames - driven with synthetic timestamp sequences
//  built from the measured histograms (388k frames of a Cyberpunk 4K240
//  session: source gaps 1 period 59.9% / 2 periods 40.1%, ~169fps achieved;
//  a light-load CachyOS control at 99.1% one-period; a Windows 120fps request
//  whose game wandered 60-120) and with a real slice of the Cyberpunk trace's
//  RTP deltas. The cases guard the contract in the file header of
//  SourceCadenceDetector.swift: the 60/40 mix raises the signal within a
//  couple of seconds with the right evidence; a 99% one-period stream never
//  does; a game wandering 100-120 in a 120 request does not flap it; a source
//  that returns to regular clears it with hysteresis; a stall is never
//  reported as skipping; and the nominal unit is the requested rate, so the
//  same under-delivery reads the same at 120, 144, 165 and 240.
//

import Foundation
import Testing
@testable import Glimmer

struct SourceCadenceDetectorTests {

    // MARK: - Helpers

    /// Deterministic 64-bit LCG (Knuth MMIX constants) so every synthetic
    /// sequence is reproducible - no Foundation randomness in a test verdict.
    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// One recorded detector transition with the SOURCE time it fired at.
    struct Fired: Equatable {
        let seconds: Double
        let transition: SourceCadenceDetector.Transition
    }

    /// Feed a gap sequence (in nominal periods) through a fresh detector,
    /// optionally jittering each delta, and collect the transitions.
    static func run(
        nominalHz: Double, gaps: [Int], jitterPeriods: Double = 0, seed: UInt64 = 7
    ) -> (detector: SourceCadenceDetector, fired: [Fired]) {
        let period = 1.0 / nominalHz
        var detector = SourceCadenceDetector(nominalPeriodSeconds: period)
        var rng = LCG(state: seed)
        var fired: [Fired] = []
        var elapsed = 0.0
        for gap in gaps {
            let jitter = jitterPeriods > 0 ? (rng.next() * 2 - 1) * jitterPeriods : 0
            let delta = (Double(gap) + jitter) * period
            elapsed += delta
            if let transition = detector.observe(deltaSeconds: delta)?.transition {
                fired.append(Fired(seconds: elapsed, transition: transition))
            }
        }
        return (detector, fired)
    }

    /// A weighted random mix of gap values spanning `seconds` of source time.
    static func mix(
        _ weights: [(gap: Int, weight: Double)], seconds: Double, nominalHz: Double, seed: UInt64
    ) -> [Int] {
        var rng = LCG(state: seed)
        let total = weights.reduce(0.0) { $0 + $1.weight }
        var gaps: [Int] = []
        var periods = 0.0
        let budget = seconds * nominalHz
        while periods < budget {
            var pick = rng.next() * total
            var chosen = weights[weights.count - 1].gap
            for entry in weights {
                if pick < entry.weight { chosen = entry.gap; break }
                pick -= entry.weight
            }
            gaps.append(chosen)
            periods += Double(chosen)
        }
        return gaps
    }

    /// The exact Cyberpunk mix as a strict repeating pattern (3 one-period gaps
    /// per 2 two-period gaps = 60/40, ~169.4 of 240).
    static func cyberpunkPattern(seconds: Double, nominalHz: Double) -> [Int] {
        let pattern = [1, 1, 2, 1, 2]
        var gaps: [Int] = []
        var periods = 0.0
        while periods < seconds * nominalHz {
            for gap in pattern {
                gaps.append(gap)
                periods += Double(gap)
            }
        }
        return gaps
    }

    static func detected(_ fired: [Fired]) -> [Fired] {
        fired.filter { if case .detected = $0.transition { return true } else { return false } }
    }
    static func cleared(_ fired: [Fired]) -> [Fired] {
        fired.filter { if case .cleared = $0.transition { return true } else { return false } }
    }
    static func stats(_ fired: Fired) -> SourceCadenceDetector.Stats {
        switch fired.transition {
        case let .detected(stats), let .cleared(stats): return stats
        }
    }

    // MARK: - (a) the measured 60/40 mix at 240 raises the signal

    @Test func cyberpunkMixIsDetectedWithinTwoSeconds() {
        for (label, gaps) in [
            ("pattern", Self.cyberpunkPattern(seconds: 20, nominalHz: 240)),
            ("random", Self.mix([(1, 0.6), (2, 0.4)], seconds: 20, nominalHz: 240, seed: 11))
        ] {
            let result = Self.run(nominalHz: 240, gaps: gaps, jitterPeriods: 0.15)
            let detections = Self.detected(result.fired)
            #expect(detections.count == 1, "\(label): exactly one detection")
            guard let first = detections.first else { continue }
            #expect(first.seconds <= 3.0, "\(label): detected at \(first.seconds)s")
            #expect(Self.cleared(result.fired).isEmpty, "\(label): holds for the whole span")
            #expect(result.detector.underDelivering, "\(label)")
            let stats = Self.stats(first)
            #expect(abs(stats.achievedFraction - 0.705) < 0.05, "\(label): achieved \(stats.achievedFraction)")
            #expect(abs(stats.multiPeriodFraction - 0.40) < 0.06, "\(label): multi \(stats.multiPeriodFraction)")
            #expect(stats.maxGapPeriods == 2, "\(label)")
        }
    }

    /// Every evaluation (4x per second of source time) carries the live window
    /// stats for the exporter gauge, whether or not the signal moved.
    @Test func everyBucketBoundaryPublishesStats() {
        var detector = SourceCadenceDetector(nominalPeriodSeconds: 1.0 / 240.0)
        var evaluations = 0
        for gap in Self.cyberpunkPattern(seconds: 4, nominalHz: 240) {
            if let evaluation = detector.observe(deltaSeconds: Double(gap) / 240.0) {
                evaluations += 1
                #expect(evaluation.stats.frames > 0)
            }
        }
        #expect(evaluations >= 14 && evaluations <= 16, "4s of source time = ~16 evaluations: \(evaluations)")
        #expect(detector.lastStats != nil)
    }

    // MARK: - (b) the clean control never raises it

    @Test func cleanStreamIsNeverDetected() {
        let gaps = Self.mix([(1, 0.991), (2, 0.009)], seconds: 60, nominalHz: 240, seed: 3)
        let result = Self.run(nominalHz: 240, gaps: gaps, jitterPeriods: 0.2)
        #expect(result.fired.isEmpty)
        #expect(!result.detector.underDelivering)
        if let stats = result.detector.lastStats {
            #expect(stats.achievedFraction > 0.98)
            #expect(stats.multiPeriodFraction < 0.03)
        }
    }

    // MARK: - (c) a 120 request with the game at 100-120 does not flap it

    @Test func wanderingGameAt120DoesNotFlap() {
        // The game's rate re-rolls every second, uniformly in 100...120 of a 120
        // request (gaps of 1 and 2 periods at 120: the Windows session's shape).
        var rng = LCG(state: 21)
        var gaps: [Int] = []
        for _ in 0..<60 {
            let rate = 100.0 + rng.next() * 20.0
            let multi = 120.0 / rate - 1.0
            gaps += Self.mix([(1, 1 - multi), (2, multi)], seconds: 1, nominalHz: 120, seed: rng.state)
        }
        let result = Self.run(nominalHz: 120, gaps: gaps, jitterPeriods: 0.1)
        #expect(result.fired.count <= 2, "no flapping over 60s: \(result.fired.count) transitions")
        for pair in zip(result.fired, result.fired.dropFirst()) {
            #expect(pair.1.seconds - pair.0.seconds >= 3.0, "transitions are seconds apart")
        }
        // Steady 110 of 120 (91.7%, 9% multi-period) sits above the detect band
        // even at the 2-sigma edge of a 2s window's sampling noise.
        let steady = Self.mix([(1, 0.91), (2, 0.09)], seconds: 30, nominalHz: 120, seed: 4)
        #expect(Self.run(nominalHz: 120, gaps: steady, jitterPeriods: 0.1).fired.isEmpty)
        // A game holding 60 in a 120 request (every gap 2 periods) IS the host
        // sampling at half rate: reported once and held, by design.
        let halved = [Int](repeating: 2, count: 60 * 60)
        let halvedResult = Self.run(nominalHz: 120, gaps: halved, jitterPeriods: 0.1)
        #expect(Self.detected(halvedResult.fired).count == 1)
        #expect(halvedResult.detector.underDelivering)
    }

    // MARK: - (d) a source that returns to regular clears with hysteresis

    @Test func regularSourceClearsWithHysteresis() {
        let loaded = Self.mix([(1, 0.6), (2, 0.4)], seconds: 10, nominalHz: 240, seed: 8)
        let clean = [Int](repeating: 1, count: 240 * 20)
        let result = Self.run(nominalHz: 240, gaps: loaded + clean, jitterPeriods: 0.15)
        let detections = Self.detected(result.fired)
        let clears = Self.cleared(result.fired)
        #expect(detections.count == 1)
        #expect(clears.count == 1)
        #expect(result.fired.count == 2, "\(result.fired)")
        guard let detection = detections.first, let clear = clears.first else { return }
        #expect(detection.seconds <= 3.0)
        // The window must first CLEAR (2s) and the verdict must then HOLD for
        // consecutive evaluations: never before ~12s, comfortably by 16s.
        #expect(clear.seconds > 12.0, "hysteresis: cleared at \(clear.seconds)s")
        #expect(clear.seconds < 16.0, "still prompt: cleared at \(clear.seconds)s")
        #expect(!result.detector.underDelivering)
        let stats = Self.stats(clear)
        #expect(stats.achievedFraction > 0.98 && stats.multiPeriodFraction < 0.03)
    }

    // MARK: - (e) a stall is not reported as skipping

    @Test func stallIsNotReportedAsSkipping() {
        // Regular frames with a 10-period stall every fourth frame: the rate
        // (31%) and multi-period fraction (25%) would both pass, the max-gap
        // bound must refuse it.
        var gaps: [Int] = []
        while gaps.count < 240 * 30 { gaps += [1, 1, 1, 10] }
        let result = Self.run(nominalHz: 240, gaps: gaps)
        #expect(result.fired.isEmpty)
        #expect(!result.detector.underDelivering)
        // Whole-second stalls (a >1s gap the pacer's cadence estimator rejects
        // outright) must also be seen by the detector as a veto, never a signal.
        var bursty: [Int] = []
        while bursty.count < 240 * 30 { bursty += [Int](repeating: 1, count: 120) + [300] }
        let burstyResult = Self.run(nominalHz: 240, gaps: bursty)
        #expect(burstyResult.fired.isEmpty)
        // An ISOLATED stall inside an otherwise skipping source only delays the
        // signal until the stall leaves the window; it does not forbid it.
        let mixed = Self.cyberpunkPattern(seconds: 1, nominalHz: 240) + [12]
            + Self.cyberpunkPattern(seconds: 10, nominalHz: 240)
        let mixedResult = Self.run(nominalHz: 240, gaps: mixed)
        let detections = Self.detected(mixedResult.fired)
        #expect(detections.count == 1)
        if let detection = detections.first {
            #expect(detection.seconds > 3.0 && detection.seconds < 6.0, "delayed at \(detection.seconds)s")
        }
    }

    @Test func timestampDiscontinuityResetsTheWindow() {
        let gaps = Self.cyberpunkPattern(seconds: 6, nominalHz: 240)
        var (detector, _) = Self.run(nominalHz: 240, gaps: gaps)
        #expect(detector.underDelivering)
        #expect(detector.observe(deltaSeconds: -0.5) == nil)
        #expect(!detector.underDelivering)
        #expect(detector.lastStats == nil)
    }

    // MARK: - The nominal unit is the requested rate

    /// The same 1-or-2-period skip mix (~43% multi-period, ~0.7x achieved)
    /// reads the same at every common requested rate - the detector measures
    /// in requested periods, never display refreshes.
    @Test(arguments: [120.0, 144.0, 165.0, 240.0])
    func skipMixReadsTheSameAtEveryRequestedRate(nominalHz: Double) {
        let gaps = Self.mix([(1, 0.57), (2, 0.43)], seconds: 20, nominalHz: nominalHz, seed: 31)
        let result = Self.run(nominalHz: nominalHz, gaps: gaps, jitterPeriods: 0.15)
        let detections = Self.detected(result.fired)
        #expect(detections.count == 1, "\(nominalHz): \(result.fired)")
        #expect(result.detector.underDelivering)
        if let detection = detections.first {
            let stats = Self.stats(detection)
            #expect(abs(stats.achievedFraction - 0.70) < 0.05, "\(nominalHz): \(stats.achievedFraction)")
            #expect(abs(stats.multiPeriodFraction - 0.43) < 0.06, "\(nominalHz): \(stats.multiPeriodFraction)")
            #expect(stats.maxGapPeriods == 2)
        }
    }

    // MARK: - Replay of the real Cyberpunk trace

    /// 2400 consecutive RTP timestamp deltas (90kHz ticks; 375 per 240Hz
    /// period) from telemetry-frames-2026-09-02T20:31:17Z.ndjson, ~14s of the
    /// loaded-GPU session: 58% one-period / 42% two-period, 169fps achieved.
    static let cyberpunkRtpDeltas: [Int] = {
        let text = """
        375,750,374,750,376,750,375,375,375,375,750,750,375,750,374,376,750,374,376,750,375,749,375,751,
        375,750,374,375,750,375,750,375,375,751,375,750,375,375,750,749,375,750,376,377,372,750,376,374,
        751,374,750,376,750,375,374,378,372,381,744,375,375,750,378,747,375,376,375,750,375,375,750,750,
        375,749,375,750,375,753,372,750,375,750,375,750,751,378,750,371,750,375,375,750,375,750,376,374,
        376,374,376,747,378,750,375,750,375,750,375,751,374,750,370,755,375,375,750,375,749,751,375,750,
        375,749,376,374,750,375,750,375,750,376,749,375,750,375,750,375,750,376,750,375,375,375,750,375,
        750,375,750,374,376,750,374,751,377,749,374,750,374,747,378,750,375,375,375,750,375,750,375,375,
        375,750,375,376,750,375,374,753,372,750,375,750,376,374,375,375,376,750,375,750,375,749,376,749,
        375,750,375,751,746,378,375,750,375,750,375,750,375,752,373,751,374,750,375,750,375,750,750,375,
        757,369,750,375,749,376,750,375,374,376,751,373,751,375,750,375,374,751,374,757,368,375,375,750,
        376,750,374,750,375,375,375,750,375,750,375,375,751,375,750,374,747,753,375,750,375,750,375,375,
        750,375,751,374,751,374,376,750,375,749,378,747,376,376,749,375,750,375,750,377,753,370,749,375,
        748,377,751,374,751,375,375,374,751,374,750,375,750,375,755,370,751,375,750,375,749,375,375,751,
        375,749,375,375,750,375,750,753,372,375,376,750,752,373,374,751,374,750,376,750,375,749,375,375,
        376,750,375,749,376,750,374,750,376,374,750,750,375,750,377,373,750,375,750,375,376,375,750,750,
        374,376,750,375,750,375,375,750,375,375,375,750,749,375,750,376,749,375,375,750,375,372,753,375,
        750,375,750,375,750,375,750,375,375,756,369,750,375,750,375,751,375,750,375,375,382,367,375,375,
        750,376,374,751,374,750,375,375,375,751,374,750,375,751,375,750,375,749,376,374,750,753,372,750,
        375,750,375,375,750,754,372,375,752,372,375,375,750,375,750,750,375,376,376,749,374,750,750,375,
        375,750,375,750,375,375,375,750,750,375,750,375,750,375,375,750,750,375,750,378,374,373,375,750,
        375,751,374,751,375,750,375,750,374,376,374,750,376,374,376,375,749,376,750,375,750,375,750,375,
        375,750,376,749,750,374,750,376,750,374,751,374,375,750,375,750,375,750,375,375,751,374,375,751,
        374,750,376,750,374,750,376,750,374,750,375,750,378,372,750,375,750,378,372,750,376,750,762,362,
        752,374,374,750,376,750,750,375,750,373,751,375,750,375,750,375,750,375,375,750,375,375,376,749,
        375,750,375,375,750,375,375,750,751,374,750,372,378,750,375,751,374,751,375,375,375,749,376,750,
        375,750,375,749,376,374,750,750,376,750,375,750,375,750,375,375,750,375,750,375,376,373,381,369,
        750,375,750,375,750,750,376,375,375,751,374,750,750,375,375,375,750,375,375,750,374,375,750,375,
        751,374,753,372,751,374,750,376,749,375,750,376,374,751,374,375,751,375,751,374,374,750,376,750,
        374,750,375,750,375,375,750,752,373,375,751,374,750,376,750,371,753,375,376,375,374,751,374,750,
        375,375,751,374,750,375,750,375,750,375,750,375,750,376,375,750,375,750,374,750,376,750,374,750,
        376,749,375,750,375,750,375,375,750,376,374,751,375,749,375,750,375,750,375,750,376,749,375,748,
        377,751,375,375,749,375,750,375,750,375,751,375,750,750,375,750,375,375,749,375,750,375,750,375,
        375,750,375,750,375,750,375,750,376,749,375,750,375,750,376,375,750,374,376,374,750,750,375,752,
        374,374,375,750,751,374,751,374,375,375,750,375,750,375,753,373,750,375,750,750,375,375,375,750,
        375,750,753,372,375,375,375,748,379,747,375,374,377,753,373,374,750,374,751,374,750,375,375,750,
        375,750,375,753,372,750,375,750,375,375,376,375,374,375,750,376,374,750,751,375,749,376,750,374,
        750,375,375,375,750,375,750,376,749,375,750,375,750,375,750,375,750,750,375,751,374,750,375,750,
        376,749,375,750,375,750,750,376,749,375,375,750,375,751,375,749,375,755,371,749,375,750,379,371,
        750,376,375,750,374,375,751,750,375,750,375,749,376,749,375,751,374,750,375,750,376,750,375,375,
        377,748,375,750,750,375,749,376,750,375,375,750,375,375,750,374,375,750,375,750,375,750,375,375,
        750,375,750,375,375,375,751,375,375,749,375,375,375,751,375,750,375,750,375,750,375,750,374,375,
        376,750,750,374,376,375,750,375,750,750,374,750,375,375,375,750,375,375,750,751,374,376,374,750,
        375,375,376,749,376,750,375,750,375,750,375,750,750,375,375,375,376,752,372,750,374,751,374,751,
        375,750,375,375,749,750,375,750,375,375,750,378,747,375,750,375,375,750,377,373,751,374,750,375,
        750,376,749,751,375,375,750,375,750,374,376,750,374,750,375,750,375,750,375,375,375,750,375,749,
        752,374,750,375,750,375,375,750,375,750,375,375,751,375,749,376,750,375,750,375,750,375,749,751,
        375,750,375,375,750,375,749,376,375,750,375,750,375,750,375,751,373,750,375,750,375,750,375,751,
        374,751,374,750,375,751,375,375,750,750,375,375,375,750,375,750,749,377,373,751,374,375,375,751,
        374,750,751,375,750,375,751,374,749,376,750,375,375,749,376,374,750,376,750,375,750,752,377,746,
        375,750,374,375,750,375,750,375,750,375,750,375,750,375,750,376,750,374,750,376,375,750,375,375,
        750,375,749,375,375,375,751,375,374,750,376,753,372,375,375,747,378,374,750,376,750,374,376,375,
        375,750,374,376,749,375,751,374,751,375,375,750,375,750,750,375,749,375,375,375,376,374,376,750,
        375,752,372,750,375,375,750,375,750,379,372,750,749,375,750,375,750,373,756,371,751,375,749,375,
        751,375,750,749,375,375,750,375,750,376,750,374,750,376,374,376,750,374,750,375,751,376,748,376,
        749,376,750,374,754,372,750,375,750,375,375,375,758,367,750,375,750,374,750,375,750,750,376,749,
        375,747,377,751,375,750,376,749,375,750,375,750,375,750,376,750,374,747,379,750,374,750,376,376,
        748,375,750,375,751,375,749,375,750,375,375,750,750,375,375,375,750,375,751,379,746,375,750,375,
        750,375,374,375,750,375,375,375,750,375,751,374,750,376,749,375,751,374,750,750,375,375,375,751,
        374,750,375,375,375,375,750,375,751,374,750,375,375,750,375,750,375,750,376,749,375,750,375,750,
        750,375,375,750,375,375,375,375,750,375,750,375,750,376,750,750,375,375,750,371,379,375,750,375,
        750,374,750,376,749,375,376,750,374,376,750,374,751,374,376,750,374,377,749,375,750,374,376,749,
        375,750,375,750,375,751,374,376,750,375,750,374,375,751,374,750,375,376,749,375,375,750,375,751,
        375,375,749,376,752,373,378,753,369,375,749,376,749,375,750,749,376,750,375,751,374,751,374,751,
        374,750,375,375,750,378,747,375,751,374,750,375,750,750,375,751,374,751,375,750,374,376,375,749,
        376,750,375,750,751,374,375,375,750,375,379,371,375,749,375,376,374,750,376,749,375,375,375,750,
        375,750,375,374,751,375,750,375,750,750,377,373,750,375,750,378,747,750,376,374,750,375,750,375,
        751,374,748,377,751,375,749,375,751,375,750,374,376,374,751,375,750,375,750,375,750,371,754,374,
        751,375,750,374,750,375,750,376,750,375,749,376,374,750,375,750,750,375,750,375,750,376,374,375,
        375,378,747,375,750,375,750,750,372,379,374,375,750,375,750,376,749,375,750,375,753,372,750,375,
        750,375,750,375,752,373,750,376,750,374,376,374,750,376,374,375,751,374,750,375,375,375,750,376,
        750,374,750,375,375,375,750,375,375,750,375,375,750,375,750,375,375,751,374,750,750,375,375,375,
        750,376,750,374,750,375,754,371,376,374,750,375,750,375,750,375,750,375,750,375,375,750,375,750,
        375,750,750,376,374,750,376,750,375,749,376,750,374,751,375,750,375,375,375,747,377,375,750,375,
        375,375,751,749,375,750,375,375,375,750,375,750,375,747,378,750,375,375,750,375,750,376,749,375,
        752,373,750,375,376,750,374,375,750,751,374,375,377,749,375,749,751,374,376,375,750,374,751,749,
        376,749,376,374,750,376,750,374,750,375,382,744,750,375,750,375,375,750,375,750,374,750,376,374,
        750,376,375,375,750,753,371,752,374,750,374,750,376,750,374,751,370,379,751,374,750,750,376,374,
        376,750,374,376,750,374,750,376,750,749,376,372,378,750,375,375,750,375,750,375,749,376,750,374,
        376,750,375,375,375,375,750,375,750,375,375,750,753,372,750,375,750,375,375,374,750,375,750,375,
        750,375,378,747,375,750,375,750,375,750,376,750,374,750,376,750,375,374,750,375,750,375,750,376,
        374,376,375,750,374,751,375,750,375,374,376,374,750,375,750,376,750,374,750,376,750,374,747,378,
        750,375,750,375,750,375,750,375,377,373,750,375,750,375,375,750,375,750,752,373,750,375,375,750,
        376,750,374,750,376,374,750,376,749,376,749,376,374,376,749,375,375,750,376,750,750,374,751,375,
        375,375,749,376,750,374,750,376,750,374,750,751,375,749,375,375,375,375,751,374,378,748,374,750,
        376,749,375,750,375,375,750,375,750,376,375,750,375,374,750,375,375,750,375,375,750,375,751,375,
        750,374,376,750,374,750,376,750,374,751,375,375,750,374,751,749,376,749,376,375,375,750,749,376,
        749,376,377,373,750,375,374,750,376,750,374,750,376,749,375,376,749,375,375,375,375,750,376,749,
        375,375,378,372,750,378,747,379,746,375,375,750,376,375,375,750,750,374,750,376,374,750,375,750,
        752,374,750,374,376,751,374,750,750,374,376,374,750,750,377,748,375,750,375,375,750,750,375,376,
        375,375,749,376,746,379,375,375,750,375,375,749,376,749,375,375,750,375,375,376,749,375,750,376,
        375,375,375,750,375,750,374,750,376,750,374,376,374,376,376,374,375,377,372,376,374,375,750,375,
        750,375,750,376,375,750,375,750,375,750,374,750,375,750,750,376,374,376,750,379,746,749,376,375,
        375,750,375,375,750,375,750,749,375,750,376,374,751,374,375,750,375,375,375,750,375,750,375,750,
        375,750,375,375,375,375,750,379,372,749,751,375,375,375,750,375,750,375,374,377,749,374,751,375,
        749,376,750,374,750,375,379,371,750,375,376,374,750,375,375,375,375,750,375,750,756,369,376,375,
        750,375,375,750,375,749,375,376,749,750,377,373,375,752,374,375,750,374,750,375,375,750,375,750,
        376,750,374,750,375,750,375,376,749,375,750,375,750,375,750,375,750,375,750,375,375,376,374,750,
        375,750,376,374,376,374,750,750,376,374,376,749,375,750,375,750,373,753,374,750,376,374,376,374,
        750,376,750,374,376,750,375,750,375,749,375,375,750,375,375,750,375,375,750,378,372,750,750,375,
        375,375,376,375,748,376,750,375,750,375,751,375,750,375,750,375,375,750,750,374,376,374,376,750
        """
        return text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
            .compactMap { Int($0) }
    }()

    @Test func cyberpunkTraceReplayIsDetectedAndHolds() {
        let deltas = Self.cyberpunkRtpDeltas
        #expect(deltas.count == 2400)
        var detector = SourceCadenceDetector(nominalPeriodSeconds: 1.0 / 240.0)
        var fired: [Fired] = []
        var elapsed = 0.0
        for ticks in deltas {
            let delta = Double(ticks) / 90_000.0
            elapsed += delta
            if let transition = detector.observe(deltaSeconds: delta)?.transition {
                fired.append(Fired(seconds: elapsed, transition: transition))
            }
        }
        #expect(elapsed > 13.0 && elapsed < 16.0, "slice spans ~14s at ~169fps: \(elapsed)")
        let detections = Self.detected(fired)
        #expect(detections.count == 1, "\(fired)")
        #expect(fired.count == 1, "detected once and held, never cleared: \(fired)")
        guard let detection = detections.first else { return }
        #expect(detection.seconds <= 3.0, "detected at \(detection.seconds)s")
        #expect(detector.underDelivering)
        if let stats = detector.lastStats {
            #expect(abs(stats.achievedFraction - 0.70) < 0.04, "achieved \(stats.achievedFraction)")
            #expect(abs(stats.multiPeriodFraction - 0.42) < 0.05, "multi \(stats.multiPeriodFraction)")
            #expect(stats.maxGapPeriods == 2)
        }
    }
}
