//
//  SourceCadenceDetector.swift
//
//  A pure, allocation-free sliding-window classifier of the HOST's frame
//  delivery, fed one source-timestamp delta per decoded frame, that says
//  whether the host is SUSTAINEDLY under-delivering in whole-frame steps -
//  skipped captures, so the gaps between source timestamps are small integer
//  multiples of the requested period. It is a TELEMETRY signal only: it names
//  the host as the cause of a juddery stream in the session log and on the
//  exporter rows; the pacer's presentation path does not consult it.
//
//  Why it exists - the pacer's only adaptive input is RFC 3550 transit jitter,
//  which is structurally blind to the host skipping frames: when Sunshine's
//  capture-convert-encode overruns the period budget (4K240 under a heavy
//  game: host_encode_avg_ms ~8 vs a 4.17ms budget), the RTP timestamps and the
//  arrivals stretch TOGETHER, transit jitter reads ~0 and nothing in the
//  client's telemetry says why the picture judders. Measured on 388k frames of
//  a Cyberpunk 4K240 session: source gaps were 1 period 59.9% of the time and
//  2 periods 40.1% (~169fps achieved) - a 60/40 mix of 4.2ms and 8.3ms steps
//  that is in the CONTENT (an uncapped game sampled irregularly by a host that
//  skips captures). A presentation-side lock onto a slower grid was tried and
//  removed: it produced a perfect 120Hz metronome that felt no better and cost
//  ~8ms of glass-to-glass. What remains is the diagnosis.
//
//  What it measures (in units of the NOMINAL period = 1 / REQUESTED fps, never
//  the display rate): over a trailing ~2s window, the achieved source rate as a
//  fraction of nominal, the fraction of gaps that are >= 2 periods, and the
//  largest gap seen. The multi-period FRACTION is the structural signal - a
//  game legitimately running at 60 in a 120 request has gaps that are exact
//  period multiples and reads as skipping too (it is: the host samples it at
//  half rate), while a source whose rate is merely a little low with one-period
//  gaps does not.
//
//  Detect (all of): sustained achieved <= 85% of nominal, >= 15% of gaps
//  multi-period, max gap <= `detectMaxGapPeriods` (larger is a STALL, the
//  freeze/gap-recovery machinery's territory, and only ever vetoes), window
//  populated, held for consecutive evaluations (~2.25s after onset). Clear
//  with hysteresis: >= 95% one-period gaps for consecutive evaluations (~3s
//  after the source cleans up), so a source hovering across the band cannot
//  flap the signal.
//
//  Time base: the detector accumulates SOURCE time from the deltas it is fed
//  (the host clock), so its window, sustain counts and hysteresis are a pure
//  function of the timestamp sequence - fully deterministic under test, and
//  immune to wall-clock scheduling of the decode queue. Storage is eight 250ms
//  buckets of a 16-bin gap histogram plus a period sum, preallocated once: per
//  frame it is a handful of integer adds, and the window stats are summed over
//  the eight buckets only when a bucket boundary is crossed (4x per second). No
//  allocation, no locks - the pacer calls it under its own.
//

import Foundation

/// Pure sliding-window classifier of source frame-delivery cadence. Value
/// type; the pacer owns one under its lock. See the file header for the model.
struct SourceCadenceDetector: Sendable {

    // MARK: - Tuning

    /// Window geometry: eight buckets of 250ms = a trailing 2s window, rotated
    /// on SOURCE time. 2s is long enough that the 60/40 skip mix reads as a
    /// stable statistic (~340 gaps at 170fps) and short enough that the signal
    /// lands within a couple of seconds of the load coming on.
    static let bucketSeconds = 0.25
    static let bucketCount = 8
    /// Gap histogram bins per bucket: bin g counts gaps of g periods for
    /// 1...14; the last bin collects everything >= `stallBin` periods (a stall
    /// by any definition - it only ever vetoes a detect).
    static let gapBins = 16
    static let stallBin = gapBins - 1
    /// A window must carry this many frames across this many populated buckets
    /// before it may judge - a thin/partial window (session start, a drought)
    /// says nothing about cadence.
    static let minWindowFrames = 32
    static let minPopulatedBuckets = 7
    /// Detect when the achieved rate is at or below this fraction of nominal...
    static let detectAchievedMax = 0.85
    /// ...AND at least this fraction of gaps are multi-period (the structural
    /// signal: skipped whole frames, not a slightly-slow clock). For a pure
    /// 1-or-2-period mix the two coincide near 17.6% multi-period.
    static let detectMultiPeriodMin = 0.15
    /// ...AND the largest gap in the window is at most this many periods. A
    /// host skipping captures under load misses one, two, occasionally three
    /// in a row; anything longer is a stall, not a cadence, and must not be
    /// reported as the host skipping frames.
    static let detectMaxGapPeriods = 4
    /// Clear once at most this fraction of gaps are multi-period (>= 95%
    /// one-period) - the hysteresis band 5%..15% cannot flap.
    static let clearMultiPeriodMax = 0.05
    /// Consecutive bucket-boundary evaluations (250ms apart) a verdict must
    /// hold: detect after 2 (a full window plus ~0.25s), clear after 4 (a
    /// clean window plus ~1s).
    static let detectSustainEvaluations = 2
    static let clearSustainEvaluations = 4

    // MARK: - Types

    /// The window statistics behind a verdict, surfaced on every evaluation as
    /// the live telemetry gauge. The fractions are NaN until the window has
    /// judged at least once.
    struct Stats: Sendable, Equatable {
        /// Frames (gaps) in the window.
        var frames: Int = 0
        /// Achieved source rate as a fraction of nominal (frames / periods spanned).
        var achievedFraction: Double = .nan
        /// Fraction of gaps that are >= 2 periods.
        var multiPeriodFraction: Double = .nan
        /// Largest gap in the window, in periods (`stallBin` means >= that many).
        var maxGapPeriods: Int = 0
        /// Buckets with at least one frame (window fill).
        var populatedBuckets: Int = 0
    }

    /// A state transition of the under-delivery signal.
    enum Transition: Sendable, Equatable {
        case detected(Stats)
        case cleared(Stats)
    }

    /// One window evaluation (produced when a frame crosses a bucket boundary,
    /// 4x per second): the stats to publish, plus the transition if the signal
    /// changed state on this evaluation.
    struct Evaluation: Sendable, Equatable {
        let stats: Stats
        let transition: Transition?
    }

    // MARK: - State

    /// 1 / requested fps - the unit every gap is measured in.
    let nominalPeriodSeconds: Double
    /// True while sustained whole-frame under-delivery is being reported.
    private(set) var underDelivering = false
    /// Stats from the most recent window evaluation (nil before the first).
    private(set) var lastStats: Stats?

    /// Ring of `bucketCount` gap histograms (`gapBins` each), flat + preallocated.
    private var histogram: [UInt32]
    /// Per-bucket sum of gap periods (the rate denominator).
    private var periodSums: [Int]
    /// Accumulated source time (seconds) from the deltas fed so far.
    private var sourceTimeSeconds = 0.0
    /// Absolute index (sourceTime / bucketSeconds) of the bucket being filled;
    /// -1 until the first observation seeds it.
    private var currentBucketIndex = -1
    private var detectStreak = 0
    private var clearStreak = 0

    init(nominalPeriodSeconds: Double) {
        let period = nominalPeriodSeconds.isFinite && nominalPeriodSeconds > 0
            ? nominalPeriodSeconds : 1.0 / 60.0
        self.nominalPeriodSeconds = period
        self.histogram = [UInt32](repeating: 0, count: Self.bucketCount * Self.gapBins)
        self.periodSums = [Int](repeating: 0, count: Self.bucketCount)
    }

    /// Nominal (requested) rate in Hz.
    var nominalHz: Double { 1.0 / nominalPeriodSeconds }

    // MARK: - Feed

    /// Observe the source-timestamp delta between consecutive decoded frames.
    /// A non-positive / non-finite delta is a timestamp discontinuity (IDR PTS
    /// reset, reorder) and RESETS the window - it is meaningless across one.
    /// Returns an evaluation when this frame crossed a bucket boundary.
    mutating func observe(deltaSeconds: Double) -> Evaluation? {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else {
            reset()
            return nil
        }
        // Quantize to whole periods. 0 = a sub-half-period delta (a duplicate
        // or a reorder that slipped through): not a frame slot, so it neither
        // counts a frame nor adds a period - it only advances source time.
        let periodsExact = deltaSeconds / nominalPeriodSeconds
        let gap = periodsExact < Double(Int32.max) ? Int(periodsExact.rounded()) : Int(Int32.max)
        sourceTimeSeconds += deltaSeconds
        let bucketIndex = Int(sourceTimeSeconds / Self.bucketSeconds)
        var evaluation: Evaluation?
        if currentBucketIndex < 0 {
            currentBucketIndex = bucketIndex
        } else if bucketIndex > currentBucketIndex {
            let advance = bucketIndex - currentBucketIndex
            if advance >= Self.bucketCount {
                clearAllBuckets()
            } else {
                for step in 1...advance {
                    clearBucket(slot: (currentBucketIndex + step) % Self.bucketCount)
                }
            }
            currentBucketIndex = bucketIndex
            evaluation = evaluate()
        }
        if gap >= 1 {
            let slot = currentBucketIndex % Self.bucketCount
            histogram[slot * Self.gapBins + min(gap, Self.stallBin)] &+= 1
            periodSums[slot] += gap
        }
        return evaluation
    }

    /// Forget everything (a source discontinuity, or a pacer restart). The
    /// signal drops too - a new source era must re-prove itself.
    mutating func reset() {
        clearAllBuckets()
        sourceTimeSeconds = 0
        currentBucketIndex = -1
        underDelivering = false
        lastStats = nil
        detectStreak = 0
        clearStreak = 0
    }

    // MARK: - Window evaluation (4x per second)

    private mutating func clearBucket(slot: Int) {
        let base = slot * Self.gapBins
        for bin in 0..<Self.gapBins { histogram[base + bin] = 0 }
        periodSums[slot] = 0
    }

    private mutating func clearAllBuckets() {
        for index in histogram.indices { histogram[index] = 0 }
        for index in periodSums.indices { periodSums[index] = 0 }
    }

    /// Sum the eight buckets into one window statistic.
    private func windowStats() -> Stats {
        var stats = Stats()
        var periods = 0
        var onePeriod = 0
        var maxGap = 0
        for bin in 1..<Self.gapBins {
            var count: UInt32 = 0
            for slot in 0..<Self.bucketCount { count &+= histogram[slot * Self.gapBins + bin] }
            guard count > 0 else { continue }
            stats.frames += Int(count)
            if bin == 1 { onePeriod = Int(count) }
            maxGap = bin
        }
        for slot in 0..<Self.bucketCount {
            periods += periodSums[slot]
            let base = slot * Self.gapBins
            var populated = false
            for bin in 1..<Self.gapBins where histogram[base + bin] > 0 {
                populated = true
                break
            }
            if populated { stats.populatedBuckets += 1 }
        }
        stats.maxGapPeriods = maxGap
        if stats.frames > 0, periods > 0 {
            stats.achievedFraction = Double(stats.frames) / Double(periods)
            stats.multiPeriodFraction = Double(stats.frames - onePeriod) / Double(stats.frames)
        }
        return stats
    }

    private mutating func evaluate() -> Evaluation {
        let stats = windowStats()
        lastStats = stats
        guard stats.frames >= Self.minWindowFrames,
              stats.populatedBuckets >= Self.minPopulatedBuckets,
              stats.achievedFraction.isFinite else {
            // Too thin to judge: no verdict may accrue, but a live signal
            // HOLDS (a drought is not evidence that the source is regular).
            detectStreak = 0
            clearStreak = 0
            return Evaluation(stats: stats, transition: nil)
        }
        if underDelivering {
            // Clear hysteresis: the source must be back to >= 95% one-period
            // gaps for consecutive evaluations before the signal stands down.
            clearStreak = stats.multiPeriodFraction <= Self.clearMultiPeriodMax ? clearStreak + 1 : 0
            guard clearStreak >= Self.clearSustainEvaluations else {
                return Evaluation(stats: stats, transition: nil)
            }
            underDelivering = false
            clearStreak = 0
            return Evaluation(stats: stats, transition: .cleared(stats))
        }
        let skipping = stats.achievedFraction <= Self.detectAchievedMax
            && stats.multiPeriodFraction >= Self.detectMultiPeriodMin
            && stats.maxGapPeriods <= Self.detectMaxGapPeriods
        detectStreak = skipping ? detectStreak + 1 : 0
        guard detectStreak >= Self.detectSustainEvaluations else {
            return Evaluation(stats: stats, transition: nil)
        }
        underDelivering = true
        detectStreak = 0
        clearStreak = 0
        return Evaluation(stats: stats, transition: .detected(stats))
    }
}
