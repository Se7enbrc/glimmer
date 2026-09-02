//
//  SourceCadenceDetector.swift
//
//  The SOURCE-CADENCE detector behind the pacer's cadence lock: a pure,
//  allocation-free sliding-window classifier of the host's frame delivery,
//  fed one source-timestamp delta per decoded frame, that decides whether the
//  host is UNDER-DELIVERING in a bounded, structured way (skipped capture
//  frames, so gaps are small integer multiples of the requested period) and,
//  if so, which refresh DIVISOR k and reserve CUSHION the pacer should present
//  on.
//
//  Why it exists - the pacer's only adaptive input was RFC 3550 transit jitter,
//  which is structurally blind to the host skipping frames: when Sunshine's
//  capture-convert-encode overruns the period budget (4K240 under a heavy
//  game: host_encode_avg_ms ~8 vs a 4.17ms budget), the RTP timestamps and the
//  arrivals stretch TOGETHER, transit jitter reads ~0, depth correctly rests at
//  1 - and the pacer faithfully reproduces the host's irregularity on screen.
//  Measured on 388k frames of a Cyberpunk 4K240 session: source gaps were 1
//  period 59.9% of the time and 2 periods 40.1% (3+ at 0.0%, ~169fps
//  achieved), and the present gaps mirrored it (72% one period / 27% two) - a
//  60/40 mix of 4.2ms and 8.3ms steps, the worst pattern for perceived
//  smoothness. Presenting on every 2nd refresh (a 120Hz grid) with one frame of
//  reserve gives 100% slot coverage at +~4ms of latency: a metronome at the
//  rate the host can actually sustain instead of a stutter at the rate it
//  cannot.
//
//  What it measures (in units of the NOMINAL period = 1 / REQUESTED fps, never
//  the display rate - the lock is a divisor of the requested stream rate, so a
//  120fps request on a 120Hz panel and a 240fps request on a 240Hz panel are
//  judged by the same rules): over a trailing ~2s window, the achieved source
//  rate as a fraction of nominal, the fraction of gaps that are >= 2 periods,
//  and the largest gap seen. The multi-period FRACTION is the structural
//  signal - a game legitimately running at 60 in a 120 request has gaps that
//  are exact period multiples and locks to k=2 (that is the metronome the
//  user wants); a source whose rate is merely a little low but whose gaps are
//  still one period does not.
//
//  Staircase (no rate-specific constants anywhere): k is the smallest integer
//  >= 2 with nominal/k <= achieved * (1 + tolerance), bounded by `maxDivisor`
//  and a floor on the grid rate, so 240 -> 120/80/60/48, 165 -> 82.5/55,
//  144 -> 72/48/36, 120 -> 60/40 all fall out of the same rule. The grid is
//  refresh-based (present on every k-th tick of a link whose floor is pinned to
//  the requested rate), so a non-integer grid rate like 82.5 is fine.
//
//  Cushion: the number of reserve frames the pacer holds so that the longest
//  observed gap cannot leave a grid slot without a fresh frame. A gap of g
//  periods can span at most floor((g - 1) / k) whole slots of k periods; add
//  one for the slot a boundary-jittered arrival can still miss, and the reserve
//  is ceil(g / k). At k=2 this is exactly (max gap - 1) for the measured 2- and
//  3-period cases; it generalizes to the staircase without over-buffering (a
//  3-period gap on a k=3 grid needs one reserve frame, not two - two would add
//  a whole 12.5ms slot of latency for no coverage gain). The gap that keys the
//  cushion must have been seen at least twice in the window, so a lone outlier
//  cannot buy a frame of latency for the two seconds it stays in the window.
//
//  Engage (all of): sustained achieved <= 85% of nominal, >= 15% of gaps
//  multi-period, max gap <= k + 1 (larger is a STALL, the freeze/gap-recovery
//  machinery's territory, not a cadence problem), window populated, held for
//  consecutive evaluations. Disengage with hysteresis: >= 95% one-period gaps
//  for consecutive evaluations (~3s after the source cleans up). Re-evaluated
//  continuously while engaged; k / cushion retune only after the same candidate
//  holds for consecutive evaluations, so the lock cannot thrash between steps.
//
//  Time base: the detector accumulates SOURCE time from the deltas it is fed
//  (the host clock), so its window, sustain counts and hysteresis are a pure
//  function of the timestamp sequence - fully deterministic under test, and
//  immune to wall-clock scheduling of the decode queue. Storage is eight
//  250ms buckets of a 16-bin gap histogram plus a period sum, preallocated
//  once: per frame it is a handful of integer adds, and the window stats are
//  summed over the eight buckets only when a bucket boundary is crossed (4x
//  per second). No allocation, no locks - the pacer calls it under its own.
//

import Foundation

/// Pure sliding-window classifier of source frame-delivery cadence. Value
/// type; the pacer owns one under its lock. See the file header for the model.
struct SourceCadenceDetector: Sendable {

    // MARK: - Tuning

    /// Window geometry: eight buckets of 250ms = a trailing 2s window, rotated
    /// on SOURCE time. 2s is long enough that the 60/40 skip mix reads as a
    /// stable statistic (~340 gaps at 170fps) and short enough that a lock
    /// engages within a couple of seconds of the load coming on.
    static let bucketSeconds = 0.25
    static let bucketCount = 8
    /// Gap histogram bins per bucket: bin g counts gaps of g periods for
    /// 1...14; the last bin collects everything >= `stallBin` periods (a stall
    /// by any definition - it only ever vetoes an engage).
    static let gapBins = 16
    static let stallBin = gapBins - 1
    /// A window must carry this many frames across this many populated buckets
    /// before it may judge - a thin/partial window (session start, a drought)
    /// says nothing about cadence.
    static let minWindowFrames = 32
    static let minPopulatedBuckets = 7
    /// Engage when the achieved rate is at or below this fraction of nominal...
    static let engageAchievedMax = 0.85
    /// ...AND at least this fraction of gaps are multi-period (the structural
    /// signal: skipped whole frames, not a slightly-slow clock). For a pure
    /// 1-or-2-period mix the two coincide near 17.6% multi-period.
    static let engageMultiPeriodMin = 0.15
    /// Disengage once at most this fraction of gaps are multi-period (>= 95%
    /// one-period) - the hysteresis band 5%..15% cannot flap.
    static let disengageMultiPeriodMax = 0.05
    /// Consecutive bucket-boundary evaluations (250ms apart) a verdict must
    /// hold: engage after 2 (a full window plus ~0.5s = ~2-2.5s after onset),
    /// disengage after 4 (a clean window plus ~1s), retune k/cushion after 4.
    static let engageSustainEvaluations = 2
    static let disengageSustainEvaluations = 4
    static let retuneSustainEvaluations = 4
    /// Grid selection: smallest k with nominal/k <= achieved * (1 + tolerance).
    /// 5% lets a source hovering just under a grid rate (115 of 240) still
    /// take the k=2 grid; the reserve absorbs the few slots it under-fills.
    static let gridRateTolerance = 0.05
    /// Staircase bounds: never divide by more than this, and never present on
    /// a grid slower than this - below it the display is a slideshow the
    /// existing stall machinery should be owning, not a cadence to lock.
    static let maxDivisor = 5
    static let minGridHz = 30.0
    /// Reserve frames cap. ceil(g / k) with g <= k + 1 at engage is at most 2;
    /// a larger gap while engaged is a stall, and chasing it with depth would
    /// only add latency.
    static let maxCushionFrames = 3
    /// A gap value must occur this many times in the window to key the cushion.
    static let cushionSupportMinCount: UInt32 = 2

    // MARK: - Types

    /// The window statistics behind a verdict, surfaced on every transition and
    /// as the live telemetry gauge. `achievedFraction` / `multiPeriodFraction`
    /// are NaN until the window has judged at least once.
    struct Stats: Sendable, Equatable {
        /// Frames (gaps) in the window.
        var frames: Int = 0
        /// Achieved source rate as a fraction of nominal (frames / periods spanned).
        var achievedFraction: Double = .nan
        /// Fraction of gaps that are >= 2 periods.
        var multiPeriodFraction: Double = .nan
        /// Largest gap in the window, in periods (`stallBin` means >= that many).
        var maxGapPeriods: Int = 0
        /// Largest gap seen at least `cushionSupportMinCount` times (falls back
        /// to `maxGapPeriods` when nothing repeats) - the cushion's input.
        var supportedMaxGapPeriods: Int = 0
        /// Buckets with at least one frame (window fill).
        var populatedBuckets: Int = 0
    }

    /// An engaged lock: present on every `divisor`-th refresh of the requested
    /// rate, holding `cushion` reserve frames.
    struct Lock: Sendable, Equatable {
        var divisor: Int
        var cushion: Int
    }

    /// A state transition the window evaluation produced.
    enum Transition: Sendable, Equatable {
        case engaged(Lock, Stats)
        case retuned(from: Lock, to: Lock, Stats)
        case disengaged(Lock, Stats)
    }

    // MARK: - State

    /// 1 / requested fps - the unit every gap is measured in.
    let nominalPeriodSeconds: Double
    /// The engaged lock, nil in passthrough.
    private(set) var lock: Lock?
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
    private var engageStreak = 0
    private var disengageStreak = 0
    private var retuneStreak = 0
    private var retuneCandidate: Lock?

    init(nominalPeriodSeconds: Double) {
        let period = nominalPeriodSeconds.isFinite && nominalPeriodSeconds > 0
            ? nominalPeriodSeconds : 1.0 / 60.0
        self.nominalPeriodSeconds = period
        self.histogram = [UInt32](repeating: 0, count: Self.bucketCount * Self.gapBins)
        self.periodSums = [Int](repeating: 0, count: Self.bucketCount)
    }

    /// Nominal (requested) rate in Hz.
    var nominalHz: Double { 1.0 / nominalPeriodSeconds }

    // MARK: - Pure selection rules

    /// The grid divisor for an achieved rate: the smallest k >= 2 whose grid
    /// rate nominal/k does not exceed the achieved rate by more than the
    /// tolerance, within the staircase bounds. nil when the source is at (or
    /// within tolerance of) full rate, or when no bounded k fits.
    static func gridDivisor(nominalHz: Double, achievedHz: Double) -> Int? {
        guard nominalHz.isFinite, nominalHz > 0, achievedHz.isFinite, achievedHz > 0 else { return nil }
        let ceiling = achievedHz * (1.0 + gridRateTolerance)
        // Full rate (k = 1 would satisfy the rule) is passthrough, not a lock.
        guard nominalHz > ceiling else { return nil }
        var k = 2
        while k <= maxDivisor {
            let gridHz = nominalHz / Double(k)
            guard gridHz >= minGridHz else { return nil }
            if gridHz <= ceiling { return k }
            k += 1
        }
        return nil
    }

    /// Reserve frames for a divisor and the longest supported gap: ceil(g / k),
    /// at least 1, capped. See the file header for the derivation.
    static func cushionFrames(maxGapPeriods: Int, divisor: Int) -> Int {
        guard divisor >= 1 else { return 1 }
        let gap = max(1, maxGapPeriods)
        let needed = (gap + divisor - 1) / divisor
        return min(maxCushionFrames, max(1, needed))
    }

    // MARK: - Feed

    /// Observe the source-timestamp delta between consecutive decoded frames.
    /// A non-positive / non-finite delta is a timestamp discontinuity (IDR PTS
    /// reset, reorder) and RESETS the window. Returns a transition when this
    /// frame crossed a bucket boundary and the window evaluation changed state.
    mutating func observe(deltaSeconds: Double) -> Transition? {
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
        var transition: Transition?
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
            transition = evaluate()
        }
        if gap >= 1 {
            let slot = currentBucketIndex % Self.bucketCount
            histogram[slot * Self.gapBins + min(gap, Self.stallBin)] &+= 1
            periodSums[slot] += gap
        }
        return transition
    }

    /// Forget everything (a source discontinuity, or a pacer restart). The
    /// engaged lock is dropped too - a new source era must re-prove itself.
    mutating func reset() {
        clearAllBuckets()
        sourceTimeSeconds = 0
        currentBucketIndex = -1
        lock = nil
        lastStats = nil
        engageStreak = 0
        disengageStreak = 0
        retuneStreak = 0
        retuneCandidate = nil
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
        var supportedMax = 0
        for bin in 1..<Self.gapBins {
            var count: UInt32 = 0
            for slot in 0..<Self.bucketCount { count &+= histogram[slot * Self.gapBins + bin] }
            guard count > 0 else { continue }
            stats.frames += Int(count)
            if bin == 1 { onePeriod = Int(count) }
            maxGap = bin
            if count >= Self.cushionSupportMinCount { supportedMax = bin }
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
        stats.supportedMaxGapPeriods = supportedMax > 0 ? supportedMax : maxGap
        if stats.frames > 0, periods > 0 {
            stats.achievedFraction = Double(stats.frames) / Double(periods)
            stats.multiPeriodFraction = Double(stats.frames - onePeriod) / Double(stats.frames)
        }
        return stats
    }

    private mutating func evaluate() -> Transition? {
        let stats = windowStats()
        lastStats = stats
        guard stats.frames >= Self.minWindowFrames,
              stats.populatedBuckets >= Self.minPopulatedBuckets,
              stats.achievedFraction.isFinite else {
            // Too thin to judge: no verdict may accrue, but an engaged lock
            // HOLDS (a drought is not evidence that the source is regular).
            engageStreak = 0
            disengageStreak = 0
            retuneStreak = 0
            retuneCandidate = nil
            return nil
        }
        if let current = lock {
            return evaluateEngaged(current: current, stats: stats)
        }
        return evaluatePassthrough(stats: stats)
    }

    private mutating func evaluatePassthrough(stats: Stats) -> Transition? {
        let achievedHz = stats.achievedFraction * nominalHz
        guard stats.achievedFraction <= Self.engageAchievedMax,
              stats.multiPeriodFraction >= Self.engageMultiPeriodMin,
              let divisor = Self.gridDivisor(nominalHz: nominalHz, achievedHz: achievedHz),
              stats.maxGapPeriods <= divisor + 1 else {
            engageStreak = 0
            return nil
        }
        engageStreak += 1
        guard engageStreak >= Self.engageSustainEvaluations else { return nil }
        engageStreak = 0
        let engaged = Lock(
            divisor: divisor,
            cushion: Self.cushionFrames(maxGapPeriods: stats.supportedMaxGapPeriods, divisor: divisor))
        lock = engaged
        disengageStreak = 0
        retuneStreak = 0
        retuneCandidate = nil
        return .engaged(engaged, stats)
    }

    private mutating func evaluateEngaged(current: Lock, stats: Stats) -> Transition? {
        // Disengage hysteresis: the source must be back to >= 95% one-period
        // gaps for consecutive evaluations before passthrough resumes.
        if stats.multiPeriodFraction <= Self.disengageMultiPeriodMax {
            disengageStreak += 1
        } else {
            disengageStreak = 0
        }
        if disengageStreak >= Self.disengageSustainEvaluations {
            lock = nil
            disengageStreak = 0
            retuneStreak = 0
            retuneCandidate = nil
            return .disengaged(current, stats)
        }
        // Continuous re-evaluation of k / cushion, adopted only once the same
        // candidate holds for consecutive evaluations. A nil divisor here means
        // the source climbed to within tolerance of full rate while still
        // showing > 5% multi-period gaps: hold the current lock, the disengage
        // streak above decides.
        let achievedHz = stats.achievedFraction * nominalHz
        guard let divisor = Self.gridDivisor(nominalHz: nominalHz, achievedHz: achievedHz) else {
            retuneStreak = 0
            retuneCandidate = nil
            return nil
        }
        let candidate = Lock(
            divisor: divisor,
            cushion: Self.cushionFrames(maxGapPeriods: stats.supportedMaxGapPeriods, divisor: divisor))
        guard candidate != current else {
            retuneStreak = 0
            retuneCandidate = nil
            return nil
        }
        if candidate == retuneCandidate {
            retuneStreak += 1
        } else {
            retuneCandidate = candidate
            retuneStreak = 1
        }
        guard retuneStreak >= Self.retuneSustainEvaluations else { return nil }
        lock = candidate
        retuneStreak = 0
        retuneCandidate = nil
        return .retuned(from: current, to: candidate, stats)
    }
}
