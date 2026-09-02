//
//  SourceCadenceDetectorTests.swift
//
//  The source-cadence lock's detector and its grid / cushion selection, which
//  are pure by design so they can be driven with synthetic timestamp sequences
//  built from the measured histograms (388k frames of a Cyberpunk 4K240
//  session: source gaps 1 period 59.9% / 2 periods 40.1%, ~169fps achieved;
//  a light-load CachyOS control at 99.1% one-period; a Windows 120fps request
//  whose game wandered 60-120) and with a real slice of the Cyberpunk trace's
//  RTP deltas. The cases guard the contract in the file header of
//  SourceCadenceDetector.swift: the 60/40 mix engages k=2 cushion 1 within a
//  couple of seconds and covers every grid slot; a 99% one-period stream never
//  engages; a game wandering 100-120 in a 120 request does not thrash; a source
//  that returns to regular disengages with hysteresis; a stall is not a
//  cadence; and the divisor staircase has no rate-specific constants (the same
//  under-delivery picks the same k at 120, 144, 165 and 240 nominal).
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
            if let transition = detector.observe(deltaSeconds: delta) {
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

    static func engaged(_ fired: [Fired]) -> [Fired] {
        fired.filter { if case .engaged = $0.transition { return true } else { return false } }
    }
    static func disengaged(_ fired: [Fired]) -> [Fired] {
        fired.filter { if case .disengaged = $0.transition { return true } else { return false } }
    }
    static func lock(_ fired: Fired) -> SourceCadenceDetector.Lock? {
        switch fired.transition {
        case let .engaged(lock, _): return lock
        case let .retuned(_, lock, _): return lock
        case .disengaged: return nil
        }
    }

    /// Slot-coverage model of the pacer's depth semantics under a lock: ticks
    /// at every nominal period (a panel at the requested rate), grid slots on
    /// every `divisor`-th tick, arrivals jittered and phase-shifted against the
    /// tick grid, the FIFO trimmed drop-to-newest to `cushion + 1` on every
    /// tick, the head released on every grid tick. Returns the fraction of grid
    /// slots that presented a fresh frame. `divisor == 1` with `cushion == 1`
    /// is passthrough (the pre-lock rest state: target 1, ceiling 2).
    static func slotCoverage(
        gaps: [Int], divisor: Int, cushion: Int, jitterPeriods: Double, phase: Double, seed: UInt64
    ) -> Double {
        var rng = LCG(state: seed)
        var arrivals: [Double] = []
        var time = 0.0
        for gap in gaps {
            time += Double(gap)
            arrivals.append(time + (rng.next() * 2 - 1) * jitterPeriods)
        }
        arrivals.sort()
        let ceiling = cushion + 1
        var queue: [Double] = []
        var next = 0
        var slots = 0
        var covered = 0
        var tick = 0
        let lastTick = Int(time) - 2
        // Skip the first few slots so the reserve can prime, as the pacer's
        // does within a few grid ticks of engaging.
        let warmupTicks = divisor * 4
        while tick < lastTick {
            let tickTime = Double(tick) + phase
            while next < arrivals.count, arrivals[next] <= tickTime {
                queue.append(arrivals[next])
                next += 1
            }
            while queue.count > ceiling { queue.removeFirst() }
            if tick % divisor == 0 {
                if tick >= warmupTicks { slots += 1 }
                if !queue.isEmpty {
                    queue.removeFirst()
                    if tick >= warmupTicks { covered += 1 }
                }
            }
            tick += 1
        }
        return slots > 0 ? Double(covered) / Double(slots) : 0
    }

    // MARK: - (a) the measured 60/40 mix at 240

    @Test func cyberpunkMixEngagesK2Cushion1WithinTwoSeconds() {
        for (label, gaps) in [
            ("pattern", Self.cyberpunkPattern(seconds: 20, nominalHz: 240)),
            ("random", Self.mix([(1, 0.6), (2, 0.4)], seconds: 20, nominalHz: 240, seed: 11))
        ] {
            let result = Self.run(nominalHz: 240, gaps: gaps, jitterPeriods: 0.15)
            let engages = Self.engaged(result.fired)
            #expect(engages.count == 1, "\(label): exactly one engage")
            guard let first = engages.first else { continue }
            #expect(first.seconds <= 3.0, "\(label): engaged at \(first.seconds)s")
            #expect(Self.lock(first) == SourceCadenceDetector.Lock(divisor: 2, cushion: 1), "\(label)")
            #expect(Self.disengaged(result.fired).isEmpty, "\(label): holds for the whole span")
            #expect(result.detector.lock == SourceCadenceDetector.Lock(divisor: 2, cushion: 1), "\(label)")
            if case let .engaged(_, stats) = first.transition {
                #expect(abs(stats.achievedFraction - 0.705) < 0.05, "\(label): achieved \(stats.achievedFraction)")
                #expect(abs(stats.multiPeriodFraction - 0.40) < 0.06, "\(label): multi \(stats.multiPeriodFraction)")
                #expect(stats.maxGapPeriods == 2, "\(label)")
            }
        }
    }

    @Test func cyberpunkMixK2Cushion1CoversEverySlot() {
        let gaps = Self.mix([(1, 0.6), (2, 0.4)], seconds: 30, nominalHz: 240, seed: 5)
        for phase in [0.0, 0.25, 0.5, 0.75] {
            let locked = Self.slotCoverage(
                gaps: gaps, divisor: 2, cushion: 1, jitterPeriods: 0.3, phase: phase, seed: 9)
            #expect(locked == 1.0, "k=2 cushion 1 covers every 120Hz slot (phase \(phase)): \(locked)")
            let passthrough = Self.slotCoverage(
                gaps: gaps, divisor: 1, cushion: 1, jitterPeriods: 0.3, phase: phase, seed: 9)
            #expect(passthrough < 0.8, "passthrough reproduces the 60/40 present pattern: \(passthrough)")
        }
    }

    // MARK: - (b) the clean control never engages

    @Test func cleanStreamNeverEngages() {
        let gaps = Self.mix([(1, 0.991), (2, 0.009)], seconds: 60, nominalHz: 240, seed: 3)
        let result = Self.run(nominalHz: 240, gaps: gaps, jitterPeriods: 0.2)
        #expect(result.fired.isEmpty)
        #expect(result.detector.lock == nil)
        if let stats = result.detector.lastStats {
            #expect(stats.achievedFraction > 0.98)
            #expect(stats.multiPeriodFraction < 0.03)
        }
    }

    // MARK: - (c) a 120 request with the game at 100-120 does not thrash

    @Test func wanderingGameAt120DoesNotThrash() {
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
        #expect(result.fired.count <= 2, "no thrash over 60s: \(result.fired.count) transitions")
        for pair in zip(result.fired, result.fired.dropFirst()) {
            #expect(pair.1.seconds - pair.0.seconds >= 3.0, "transitions are seconds apart")
        }
        // Steady 110 of 120 (91.7%, 9% multi-period) sits above the engage band
        // even at the 2-sigma edge of a 2s window's sampling noise (a source
        // hovering AT the 85% edge may legitimately cross it on one window and
        // then holds, by design - that is one engage, not thrash).
        let steady = Self.mix([(1, 0.91), (2, 0.09)], seconds: 30, nominalHz: 120, seed: 4)
        #expect(Self.run(nominalHz: 120, gaps: steady, jitterPeriods: 0.1).fired.isEmpty)
        // A game LEGITIMATELY holding 60 in a 120 request (every gap 2 periods)
        // locks to k=2 once and holds - that is the metronome, by design.
        let halved = [Int](repeating: 2, count: 60 * 60)
        let halvedResult = Self.run(nominalHz: 120, gaps: halved, jitterPeriods: 0.1)
        #expect(Self.engaged(halvedResult.fired).count == 1)
        #expect(halvedResult.detector.lock == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
    }

    // MARK: - (d) a source that returns to regular disengages with hysteresis

    @Test func regularSourceDisengagesWithHysteresis() {
        let loaded = Self.mix([(1, 0.6), (2, 0.4)], seconds: 10, nominalHz: 240, seed: 8)
        let clean = [Int](repeating: 1, count: 240 * 20)
        let result = Self.run(nominalHz: 240, gaps: loaded + clean, jitterPeriods: 0.15)
        let engages = Self.engaged(result.fired)
        let disengages = Self.disengaged(result.fired)
        #expect(engages.count == 1)
        #expect(disengages.count == 1)
        #expect(result.fired.count == 2, "no retunes on the way out: \(result.fired)")
        guard let engage = engages.first, let disengage = disengages.first else { return }
        #expect(engage.seconds <= 3.0)
        // The window must first CLEAR (2s) and the verdict must then HOLD for
        // consecutive evaluations: never before ~12s, comfortably by 16s.
        #expect(disengage.seconds > 12.0, "hysteresis: disengaged at \(disengage.seconds)s")
        #expect(disengage.seconds < 16.0, "still prompt: disengaged at \(disengage.seconds)s")
        #expect(result.detector.lock == nil)
    }

    // MARK: - (e) a stall is not a cadence lock

    @Test func stallIsNotTreatedAsCadenceLock() {
        // Regular frames with a 10-period stall every fourth frame: the rate
        // (31%) and multi-period fraction (25%) would both pass, the max-gap
        // bound must refuse it.
        var gaps: [Int] = []
        while gaps.count < 240 * 30 { gaps += [1, 1, 1, 10] }
        let result = Self.run(nominalHz: 240, gaps: gaps)
        #expect(result.fired.isEmpty)
        #expect(result.detector.lock == nil)
        // Whole-second stalls (a >1s gap the pacer's cadence estimator rejects
        // outright) must also be seen by the detector as a veto, never a lock.
        var bursty: [Int] = []
        while bursty.count < 240 * 30 { bursty += [Int](repeating: 1, count: 120) + [300] }
        let burstyResult = Self.run(nominalHz: 240, gaps: bursty)
        #expect(burstyResult.fired.isEmpty)
        // An ISOLATED stall inside an otherwise lockable source only delays the
        // engage until the stall leaves the window; it does not forbid it.
        let mixed = Self.cyberpunkPattern(seconds: 1, nominalHz: 240) + [12]
            + Self.cyberpunkPattern(seconds: 10, nominalHz: 240)
        let mixedResult = Self.run(nominalHz: 240, gaps: mixed)
        let engages = Self.engaged(mixedResult.fired)
        #expect(engages.count == 1)
        if let engage = engages.first {
            #expect(engage.seconds > 3.0 && engage.seconds < 6.0, "delayed engage at \(engage.seconds)s")
            #expect(Self.lock(engage) == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
        }
    }

    @Test func timestampDiscontinuityDropsTheLock() {
        let gaps = Self.cyberpunkPattern(seconds: 6, nominalHz: 240)
        var (detector, _) = Self.run(nominalHz: 240, gaps: gaps)
        #expect(detector.lock != nil)
        #expect(detector.observe(deltaSeconds: -0.5) == nil)
        #expect(detector.lock == nil)
        #expect(detector.lastStats == nil)
    }

    // MARK: - The divisor staircase (no rate-specific constants)

    /// Under-delivery at ~0.7x of nominal (a 1-or-2-period mix with ~43%
    /// multi-period gaps) selects k=2 with one reserve frame at every common
    /// requested rate.
    @Test(arguments: [120.0, 144.0, 165.0, 240.0])
    func staircaseSelectsK2AtSeventyPercent(nominalHz: Double) {
        let gaps = Self.mix([(1, 0.57), (2, 0.43)], seconds: 20, nominalHz: nominalHz, seed: 31)
        let result = Self.run(nominalHz: nominalHz, gaps: gaps, jitterPeriods: 0.15)
        let engages = Self.engaged(result.fired)
        #expect(engages.count == 1, "\(nominalHz): \(result.fired)")
        #expect(engages.first.flatMap(Self.lock) == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
        #expect(result.detector.lock == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
        if case let .engaged(_, stats)? = engages.first?.transition {
            #expect(abs(stats.achievedFraction - 0.70) < 0.05, "\(nominalHz): \(stats.achievedFraction)")
        }
    }

    /// Under-delivery at ~0.45x of nominal (a 2-or-3-period mix, ~22% threes)
    /// selects k=3; the 3-period gaps fit one k=3 slot, so one reserve frame
    /// covers the boundary case and nothing more is bought.
    @Test(arguments: [120.0, 144.0, 165.0, 240.0])
    func staircaseSelectsK3AtFortyFivePercent(nominalHz: Double) {
        let gaps = Self.mix([(2, 0.78), (3, 0.22)], seconds: 20, nominalHz: nominalHz, seed: 37)
        let result = Self.run(nominalHz: nominalHz, gaps: gaps, jitterPeriods: 0.15)
        let engages = Self.engaged(result.fired)
        #expect(engages.count == 1, "\(nominalHz): \(result.fired)")
        #expect(engages.first.flatMap(Self.lock) == SourceCadenceDetector.Lock(divisor: 3, cushion: 1))
        #expect(result.detector.lock == SourceCadenceDetector.Lock(divisor: 3, cushion: 1))
        if case let .engaged(_, stats)? = engages.first?.transition {
            #expect(abs(stats.achievedFraction - 0.45) < 0.05, "\(nominalHz): \(stats.achievedFraction)")
        }
        // And the grid the pacer will present on, refresh-based (165/3 = 55,
        // 144/3 = 48, 120/3 = 40, 240/3 = 80 - non-integer grids are fine).
        let coverage = Self.slotCoverage(
            gaps: gaps, divisor: 3, cushion: 1, jitterPeriods: 0.3, phase: 0.4, seed: 2)
        #expect(coverage == 1.0, "\(nominalHz): k=3 cushion 1 covers every slot: \(coverage)")
    }

    @Test func gridDivisorStaircaseTable() {
        typealias Detector = SourceCadenceDetector
        // 240 -> 120 / 80 / 60 / 48, then nothing below the floor.
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 168) == 2)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 108) == 3)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 62) == 4)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 50) == 5)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 40) == nil)
        // 144 -> 72 / 48 / 36.
        #expect(Detector.gridDivisor(nominalHz: 144, achievedHz: 100.8) == 2)
        #expect(Detector.gridDivisor(nominalHz: 144, achievedHz: 64.8) == 3)
        #expect(Detector.gridDivisor(nominalHz: 144, achievedHz: 45) == 4)
        #expect(Detector.gridDivisor(nominalHz: 144, achievedHz: 30) == nil)
        // 165 -> 82.5 / 55 (non-integer grids are refresh-based, so fine).
        #expect(Detector.gridDivisor(nominalHz: 165, achievedHz: 115.5) == 2)
        #expect(Detector.gridDivisor(nominalHz: 165, achievedHz: 74.25) == 3)
        // 120 -> 60 / 40 / 30.
        #expect(Detector.gridDivisor(nominalHz: 120, achievedHz: 84) == 2)
        #expect(Detector.gridDivisor(nominalHz: 120, achievedHz: 54) == 3)
        #expect(Detector.gridDivisor(nominalHz: 120, achievedHz: 38) == 4)
        #expect(Detector.gridDivisor(nominalHz: 120, achievedHz: 25) == nil)
        // 60 -> 30, never lower.
        #expect(Detector.gridDivisor(nominalHz: 60, achievedHz: 40) == 2)
        #expect(Detector.gridDivisor(nominalHz: 60, achievedHz: 15) == nil)
        // At or within tolerance of full rate: passthrough, never k=1.
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 235) == nil)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 240) == nil)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: 0) == nil)
        #expect(Detector.gridDivisor(nominalHz: 240, achievedHz: .nan) == nil)
    }

    @Test func cushionRule() {
        typealias Detector = SourceCadenceDetector
        // ceil(g / k): (max gap - 1) at k=2 for the measured 2- and 3-period
        // cases, one reserve frame for a gap that fits one slot, capped.
        #expect(Detector.cushionFrames(maxGapPeriods: 2, divisor: 2) == 1)
        #expect(Detector.cushionFrames(maxGapPeriods: 3, divisor: 2) == 2)
        #expect(Detector.cushionFrames(maxGapPeriods: 3, divisor: 3) == 1)
        #expect(Detector.cushionFrames(maxGapPeriods: 4, divisor: 2) == 2)
        #expect(Detector.cushionFrames(maxGapPeriods: 4, divisor: 3) == 2)
        #expect(Detector.cushionFrames(maxGapPeriods: 5, divisor: 2) == 3)
        #expect(Detector.cushionFrames(maxGapPeriods: 1, divisor: 2) == 1)
        #expect(Detector.cushionFrames(maxGapPeriods: 0, divisor: 2) == 1)
        #expect(Detector.cushionFrames(maxGapPeriods: 15, divisor: 2) == Detector.maxCushionFrames)
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

    @Test func cyberpunkTraceReplayEngagesAndHolds() {
        let deltas = Self.cyberpunkRtpDeltas
        #expect(deltas.count == 2400)
        var detector = SourceCadenceDetector(nominalPeriodSeconds: 1.0 / 240.0)
        var fired: [Fired] = []
        var elapsed = 0.0
        for ticks in deltas {
            let delta = Double(ticks) / 90_000.0
            elapsed += delta
            if let transition = detector.observe(deltaSeconds: delta) {
                fired.append(Fired(seconds: elapsed, transition: transition))
            }
        }
        #expect(elapsed > 13.0 && elapsed < 16.0, "slice spans ~14s at ~169fps: \(elapsed)")
        let engages = Self.engaged(fired)
        #expect(engages.count == 1, "\(fired)")
        #expect(fired.count == 1, "engages once and holds, no retune/disengage: \(fired)")
        guard let engage = engages.first else { return }
        #expect(engage.seconds <= 3.0, "engaged at \(engage.seconds)s")
        #expect(Self.lock(engage) == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
        #expect(detector.lock == SourceCadenceDetector.Lock(divisor: 2, cushion: 1))
        if let stats = detector.lastStats {
            #expect(abs(stats.achievedFraction - 0.70) < 0.04, "achieved \(stats.achievedFraction)")
            #expect(abs(stats.multiPeriodFraction - 0.42) < 0.05, "multi \(stats.multiPeriodFraction)")
            #expect(stats.maxGapPeriods == 2)
        }
        // The lock's grid: k=2 cushion 1 covers every 120Hz slot of the real
        // delivery pattern (jitter from the trace itself, plus phase sweeps).
        let gaps = deltas.map { Int((Double($0) / 375.0).rounded()) }
        for phase in [0.0, 0.5] {
            let coverage = Self.slotCoverage(
                gaps: gaps, divisor: 2, cushion: 1, jitterPeriods: 0.2, phase: phase, seed: 1)
            #expect(coverage == 1.0, "real trace on k=2 cushion 1 (phase \(phase)): \(coverage)")
        }
    }
}
