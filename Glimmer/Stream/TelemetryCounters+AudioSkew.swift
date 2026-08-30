//
//  TelemetryCounters+AudioSkew.swift
//
//  The CROSS-STREAM A/V skew store (`av_skew_ms` / `av_clock_skew_ms`): the two
//  hot-path one-word RTP position writes (last-PRESENTED video at the
//  renderer-enqueue site, last-SCHEDULED audio at the decode hand-off) and the
//  1Hz cold derive that turns them into a signed skew, its cushion-subtracted
//  true clock skew, and the pair re-anchoring that keeps a stale stream or an
//  RTP discontinuity from poisoning the baseline. Split out of
//  TelemetryCounters+AudioGauges.swift (pure move, same file-split idiom as the
//  rest of the telemetry rig) to keep both units under the length limit; see
//  that file for the audio playout gauges, the AUDIO-TTF context, and the
//  cushion-memory latch it sits between.
//
//  Self-locked top-level store (the `AudioTtfContext` idiom), so it needs no
//  storage on `TelemetryCounters` and stays callable from any thread.
//

import Foundation
import os

// MARK: - Cross-stream A/V skew store (`av_skew_ms`)

/// The TRUE cross-stream A/V alignment meter the deferred `av_lag_est_ms`
/// derivation comment (TelemetryExporter+RenderNDJSON) called for. Two hot-path
/// one-word writes feed it - the last-PRESENTED video RTP (90kHz host capture
/// clock, written at the renderer-enqueue site) and the last-SCHEDULED audio RTP
/// (written at the audio decode hand-off) - and a 1Hz cold read derives
///   skew_ms = video_presented_pos − (audio_scheduled_pos − buffer_fill_ms)
/// with SIGN CONVENTION: positive = AUDIO LATE (behind video). The buffer-fill
/// term converts the schedule-head position to the PLAYHEAD position (the
/// playhead trails the newest scheduled packet by exactly the standing fill).
///
/// AUDIO CLOCK UNITS (a past instrument break): the audio
/// RTP timestamp is NOT a 48kHz sample clock. Sunshine advances it by
/// `packetDuration` per packet (stream.cpp) - 5 per 5ms packet - i.e. a
/// 1 tick/ms MILLISECOND clock. The old /48 misread made the audio half
/// advance at 1000/48000 ≈ 2% of wall rate, so skew ramped at wall×(1−1/48)
/// ≈ 979 ms/s to the 10s sanity guard and re-anchored on a 12s metronome
/// (716 rebases, degenerate scorecard quantiles). The conversion is now the
/// ms clock by default, CONFIRMED against the measured advance rate at the
/// first derive ≥2s after audio starts flowing (see `audioTicksPerMs`): a
/// host whose audio RTP really is a 48kHz sample clock snaps to /48 within
/// ~2s and the instrument self-heals instead of metronoming. The 48x gap
/// between the two clock families means even seconds of arrival clumping on
/// a jittery link cannot mis-snap the estimate.
///
/// EPOCH HONESTY: RTP timestamps carry no shared epoch (each stream starts at
/// an arbitrary offset), so both sides are measured from a PAIR-ANCHOR latched
/// at the first derive tick where both streams are flowing. The host-side
/// video-vs-audio capture offset at the anchor instant (≈ the video pipeline
/// e2e, single-digit ms) rides along as a constant bias - the trend and the
/// steps are the signal, the absolute is approximate. The anchor pair drops
/// whenever either stream goes stale (>2s - present-suppressed/AFK windows,
/// session teardown) or the sanity bound trips (an RTP discontinuity), and
/// re-latches at the next tick where both flow - counted in `rebaseTotal`, so a
/// mid-session re-baseline is never a silent step. Never a permanent give-up:
/// every dark state self-heals one tick after both streams resume.
///
/// Self-locked (the `AudioTtfContext` idiom); the per-write cost is one clock
/// read + an unfair lock + two stores at ≤240Hz video / 200Hz audio - the same
/// always-live budget as the audio meter's per-packet accounting.
final class AudioVideoSkewStore: @unchecked Sendable {
    static let shared = AudioVideoSkewStore()

    /// Freshness horizon (ns) per side: a side not written within this window
    /// (suppressed presents, drained audio, teardown) drops the anchor pair and
    /// the derive reports absent (absent ≠ 0) until both sides flow again.
    static let freshnessNanos: UInt64 = 2_000_000_000
    /// Sanity bound (ms) on a derived skew: beyond this the anchors are judged
    /// inconsistent (host RTP discontinuity) and the pair re-latches. 600ms
    /// clears the deepest cushion (300ms) + a real lip-sync excursion with margin
    /// but rejects the railed values a stale anchor produces - the old 1800ms was
    /// loose enough to pass a −1517ms artifact into the percentile buckets.
    static let sanityBoundMs: Double = 600
    /// Signed bucket bounds (ms) for the session percentile accumulator -
    /// resolution concentrated around the 0...150ms cushion range where the
    /// lip-sync trade lives, with the ~125ms ITU annoyance threshold bracketed.
    static let bucketBoundsMs: [Double] = [
        -1000, -500, -250, -125, -90, -60, -40, -25, -10, 0,
        10, 25, 40, 60, 75, 90, 110, 125, 150, 200, 300, 500, 1000
    ]
    /// Video RTP is a 90kHz capture clock (RTP standard for video).
    static let videoRtpTicksPerMs = 90.0
    /// The two known audio RTP clock families: Sunshine's packet-duration
    /// MILLISECOND clock (1 tick/ms - the live host, the default) and a true
    /// 48kHz sample clock (48 ticks/ms - what the RTP header would suggest and
    /// what the old conversion wrongly assumed). The measured-rate snap picks
    /// between them; see the AUDIO CLOCK UNITS doc on the type.
    static let audioTicksPerMsCandidates: [Double] = [1.0, 48.0]
    /// Minimum audio-flow span before the measured advance rate is trusted to
    /// snap the clock family. At ~200 packets/s, 2s ≈ 400 packets; arrival
    /// clumping on a jittery link distorts a 2s window by a few percent - the
    /// candidate families are 4800% apart, so a mis-snap would take a clumping
    /// pathology no real link produces.
    static let audioRateCalibrationNanos: UInt64 = 2_000_000_000
    /// Outlier-guard jump threshold (ms): a 1Hz sample more than this from the
    /// running EWMA is rejected once (then re-seeds, so a sustained step is
    /// accepted on the next tick). Generous - real skew moves slowly (cushion
    /// ramps tens of ms/s), so only a one-tick artifact clears it.
    static let outlierJumpMs: Double = 250

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var videoLastRtp: UInt32 = 0
    private var videoNoteNanos: UInt64 = 0
    private var audioLastRtp: UInt32 = 0
    private var audioNoteNanos: UInt64 = 0
    private var videoAnchorRtp: UInt32 = 0
    private var audioAnchorRtp: UInt32 = 0
    private var anchored = false
    private var everAnchored = false
    private var rebases: UInt64 = 0
    // Audio clock-family calibration: anchor of the first audio note (the
    // measured-rate baseline) + the resolved ticks/ms. Nominal 1.0 (the live
    // host's ms clock) until the first derive ≥2s of audio flow snaps it to
    // the nearest candidate family - once, then latched for the session.
    private var audioRateAnchorRtp: UInt32 = 0
    private var audioRateAnchorNanos: UInt64 = 0
    private var audioTicksPerMs = 1.0
    private var audioRateResolved = false
    // Two-window snap latch: the family must agree across two consecutive windows
    // before latching, so one arrival-clumping window can't flip the clock. The
    // first window re-baselines the rate anchor for the second. nil = no candidate.
    private var audioRatePendingFamily: Double?
    /// Latest RESIDENT corrector-inserted silence (ms) in the audio buffer, pushed
    /// by `publishAudioState`. Subtracted from the buffer-fill term in `deriveSkewMs`
    /// so the playhead reflects real media, not inserted silence (see the type doc
    /// + `AudioDecoder.pendingSilenceFrames`). 0 until audio flows / no inserts.
    private var residentSilenceMs: Double = 0
    /// Cushion-subtracted true clock skew (ms) from the most recent successful
    /// derive; nil when that derive produced no value (dark/stale/re-anchor/bound).
    private var lastTrueClockSkewMs: Double?
    // Session accumulator (scorecard percentiles): bucket counts + exact
    // min/max/sum, plus an explicit OVERFLOW count for samples past the last
    // bound so the quantile walk's rank space covers EVERY sample - the old
    // fall-through made overflow samples invisible to `cumulative` while still
    // counted in `rank`, which collapsed p50=p95=p99=max the moment a session
    // had any overflow mass (a broken-units session read one value four ways).
    // Reset per session via `resetForNewSession`.
    private var bucketCounts = [UInt64](repeating: 0, count: bucketBoundsMs.count)
    private var overflowCount: UInt64 = 0
    private var sampleCount: UInt64 = 0
    private var sampleSum: Double = 0
    private var sampleMin: Double = .infinity
    private var sampleMax: Double = -.infinity
    // Parallel accumulator for the cushion-SUBTRACTED true clock skew - the real
    // A/V sync signal (av_skew_ms is dominated by the cushion). Same bucket set
    // and feeder cadence (the NDJSON tick); summarized alongside av_skew.
    private var clockBucketCounts = [UInt64](repeating: 0, count: bucketBoundsMs.count)
    private var clockOverflowCount: UInt64 = 0
    private var clockSampleCount: UInt64 = 0
    private var clockSampleSum: Double = 0
    private var clockSampleMin: Double = .infinity
    private var clockSampleMax: Double = -.infinity
    // Outlier guard: an EWMA of accepted av_skew samples + whether one has been
    // seeded. A single 1Hz sample that jumps more than `outlierJumpMs` from the
    // running estimate is rejected ONCE (not bucketed) - it re-seeds the
    // estimate, so a SUSTAINED step passes on the very next tick. Catches a lone
    // in-bound artifact (a −1517ms reading inside a loose bound) without dropping
    // legitimate sustained skew.
    private var skewEwmaMs: Double = 0
    private var skewEwmaSeeded = false

    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// VIDEO half: the RTP timestamp of the frame that just reached the
    /// renderer. Called from the present site (gate-on path only - the
    /// `FrameTimingTracker.shared` nil-check upstream keeps telemetry-off
    /// sessions zero-cost). 0 = untracked frame, ignored.
    func noteVideoPresented(rtp: UInt32) {
        guard rtp != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        videoLastRtp = rtp
        videoNoteNanos = now
        os_unfair_lock_unlock(lock)
    }

    /// AUDIO half: the RTP timestamp of the packet about to be handed to the
    /// decode/schedule path. Always-live (the audio meter budget); ~200Hz.
    /// The first note also anchors the clock-family calibration baseline (one
    /// extra branch on the hot path; the calibration itself runs on the 1Hz
    /// cold derive, never here).
    func noteAudioScheduled(rtp: UInt32) {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        // RATE-ANCHOR FRESHNESS (stale-anchor audit, 2026-08-12): a pre-resolve
        // audio stall spanning the calibration window inflates elapsed-ms while
        // the RTP stands still, depressing the measured rate toward 0 - and the
        // two-window hold then AGREES with itself (both windows see the same
        // depressed rate), latching the wrong family. The 2s freshness horizon
        // that already governs the pair anchor restarts the calibration window
        // instead; harmless post-resolve (the family is latched for the session).
        if !audioRateResolved, audioNoteNanos != 0,
           now &- audioNoteNanos > Self.freshnessNanos {
            audioRateAnchorRtp = rtp
            audioRateAnchorNanos = now
            audioRatePendingFamily = nil
        }
        audioLastRtp = rtp
        audioNoteNanos = now
        if audioRateAnchorNanos == 0 {
            audioRateAnchorRtp = rtp
            audioRateAnchorNanos = now
        }
        os_unfair_lock_unlock(lock)
    }

    /// Push the latest resident corrector-inserted silence (ms). Called from
    /// `publishAudioState` at the schedule + completion cadence; one lock + one
    /// store - the same always-live budget as the audio meter's per-packet work.
    func setResidentSilenceMs(_ ms: Double) {
        os_unfair_lock_lock(lock)
        residentSilenceMs = ms > 0 ? ms : 0
        os_unfair_lock_unlock(lock)
    }

    /// Re-anchors after the first latch are counted so a mid-session
    /// re-baseline (suppression window, RTP discontinuity) is visible next to
    /// the skew series it steps.
    var rebaseTotal: UInt64 {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return rebases
    }

    /// The 1Hz cold read: derive the current skew (ms, + = audio late), or nil
    /// when either stream is dark/stale or the pair is (re-)anchoring this
    /// tick. `accumulate` feeds the session percentile accumulator - set it
    /// from exactly ONE caller cadence (the NDJSON tick) so the scorecard
    /// can't double-count; other readers (Prometheus) derive without feeding.
    func deriveSkewMs(bufferFillMs: Double?, accumulate: Bool) -> Double? {
        guard let fillMs = bufferFillMs else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard videoNoteNanos != 0, audioNoteNanos != 0,
              now &- videoNoteNanos <= Self.freshnessNanos,
              now &- audioNoteNanos <= Self.freshnessNanos else {
            anchored = false
            lastTrueClockSkewMs = nil
            return nil
        }
        resolveAudioClockFamilyLocked(now: now)
        if !anchored {
            anchored = true
            videoAnchorRtp = videoLastRtp
            audioAnchorRtp = audioLastRtp
            if everAnchored { rebases &+= 1 }
            everAnchored = true
            lastTrueClockSkewMs = nil
            return nil // the anchor tick defines the epoch, measures nothing
        }
        // Wrap-safe modular distances on the two host capture clocks (90kHz
        // video / the calibrated audio clock - see AUDIO CLOCK UNITS on the
        // type); both monotone within any realistic session.
        let videoMs = Double(videoLastRtp &- videoAnchorRtp) / Self.videoRtpTicksPerMs
        let audioMs = Double(audioLastRtp &- audioAnchorRtp) / audioTicksPerMs
        // Subtract resident corrector-silence from the fill: the audio playhead is
        // (audioMs − REAL buffered media), and inserted silence inflates `fillMs`
        // without advancing `audioMs`, so counting it biases skew toward "audio
        // late". Clamp ≥0 (silence is a subset of fill; guards snapshot skew).
        let realFillMs = max(0, fillMs - residentSilenceMs)
        let skewMs = videoMs - audioMs + realFillMs
        guard abs(skewMs) <= Self.sanityBoundMs else {
            anchored = false // discontinuity: re-anchor next tick, never wedge
            lastTrueClockSkewMs = nil
            return nil
        }
        // TRUE clock skew: same alignment WITHOUT the deliberate cushion
        // (`realFillMs`) baked in - the genuine host↔Mac offset the drift
        // resampler corrects, vs av_skew_ms which is dominated by the cushion.
        let clockSkewMs = videoMs - audioMs
        lastTrueClockSkewMs = clockSkewMs
        // Outlier guard runs on av_skew (the EWMA target); when it rejects a lone
        // artifact, drop the paired clock sample too so the two accumulators stay
        // aligned tick-for-tick.
        if accumulate, observeLocked(skewMs) {
            observeClockLocked(clockSkewMs)
        }
        return skewMs
    }

    /// The cushion-SUBTRACTED true clock skew (ms, + = audio clock behind video)
    /// from the most recent `deriveSkewMs` this tick, or nil if that derive made
    /// no value (dark/stale/re-anchor/bound). Read right after it; no side effects.
    func lastTrueClockSkew() -> Double? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return lastTrueClockSkewMs
    }

    /// One-shot audio clock-family snap (lock already held; 1Hz cold path):
    /// once ≥2s of audio has flowed, measure ticks-per-ms against the wall
    /// clock and latch the nearest known family (ratio space, so the compare
    /// is symmetric around the 48x gap). Until it resolves, derives run on
    /// the nominal ms clock - correct for the live Sunshine host from tick 1;
    /// on a true-48kHz host the pre-snap derives blow the sanity bound and
    /// re-anchor for ≤2s, then the snap lands and the instrument self-heals
    /// (bounded recovery, never a permanent give-up). A zero/garbage measured
    /// rate (audio stalled across the whole window) declines to latch and
    /// simply retries on the next derive.
    private func resolveAudioClockFamilyLocked(now: UInt64) {
        guard !audioRateResolved, audioRateAnchorNanos != 0,
              now &- audioRateAnchorNanos >= Self.audioRateCalibrationNanos else { return }
        let elapsedMs = Double(now &- audioRateAnchorNanos) / 1_000_000.0
        let measured = Double(audioLastRtp &- audioRateAnchorRtp) / elapsedMs
        guard measured > 0 else { return }
        let snapped = Self.audioTicksPerMsCandidates.min {
            abs(log($0 / measured)) < abs(log($1 / measured))
        } ?? 1.0
        // TWO-WINDOW HOLD: latch only when a SECOND independent window snaps to
        // the same family (the first window's measurement re-baselines the rate
        // anchor for the second). A lone clumping window can't flip the clock.
        if audioRatePendingFamily == snapped {
            audioTicksPerMs = snapped
            audioRateResolved = true
            return
        }
        audioRatePendingFamily = snapped
        audioRateAnchorRtp = audioLastRtp
        audioRateAnchorNanos = now
    }

    /// Feed one 1Hz sample into the session accumulator, with the single-sample
    /// outlier guard. Lock already held. Returns false (and buckets nothing) when
    /// the sample is rejected as a lone artifact - the EWMA still re-seeds to it,
    /// so a SUSTAINED step is accepted on the next tick.
    @discardableResult
    private func observeLocked(_ skewMs: Double) -> Bool {
        if skewEwmaSeeded, abs(skewMs - skewEwmaMs) > Self.outlierJumpMs {
            skewEwmaMs = skewMs // re-seed so a real step isn't rejected twice
            return false
        }
        skewEwmaMs = skewEwmaSeeded ? skewEwmaMs * 0.7 + skewMs * 0.3 : skewMs
        skewEwmaSeeded = true
        sampleCount &+= 1
        sampleSum += skewMs
        if skewMs < sampleMin { sampleMin = skewMs }
        if skewMs > sampleMax { sampleMax = skewMs }
        if let idx = Self.bucketBoundsMs.firstIndex(where: { skewMs <= $0 }) {
            bucketCounts[idx] &+= 1
        } else {
            overflowCount &+= 1 // past the last bound; see the overflow doc
        }
        return true
    }

    /// Feed one 1Hz CUSHION-FREE clock-skew sample into its accumulator. Lock
    /// already held; mirrors `observeLocked` so the true-sync percentiles use
    /// the same bucket/overflow discipline as av_skew.
    private func observeClockLocked(_ skewMs: Double) {
        clockSampleCount &+= 1
        clockSampleSum += skewMs
        if skewMs < clockSampleMin { clockSampleMin = skewMs }
        if skewMs > clockSampleMax { clockSampleMax = skewMs }
        if let idx = Self.bucketBoundsMs.firstIndex(where: { skewMs <= $0 }) {
            clockBucketCounts[idx] &+= 1
        } else {
            clockOverflowCount &+= 1
        }
    }

    /// Session percentile summary for the scorecard (nil before any sample).
    /// p50/p95/p99 are interpolated within the fixed buckets (the NDJSON
    /// histogram-estimator discipline), min/max/avg exact.
    struct Summary {
        let samples: UInt64
        let minMs: Double
        let maxMs: Double
        let avgMs: Double
        let p50Ms: Double
        let p95Ms: Double
        let p99Ms: Double
        let rebases: UInt64
    }
    func sessionSummary() -> Summary? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard sampleCount > 0 else { return nil }
        return Summary(samples: sampleCount,
                       minMs: sampleMin, maxMs: sampleMax,
                       avgMs: sampleSum / Double(sampleCount),
                       p50Ms: quantileLocked(0.50, bucketCounts, overflowCount,
                                             sampleCount, sampleMin, sampleMax),
                       p95Ms: quantileLocked(0.95, bucketCounts, overflowCount,
                                             sampleCount, sampleMin, sampleMax),
                       p99Ms: quantileLocked(0.99, bucketCounts, overflowCount,
                                             sampleCount, sampleMin, sampleMax),
                       rebases: rebases)
    }

    /// Session percentiles of the CUSHION-FREE true clock skew - the real A/V
    /// sync signal (av_skew is dominated by the cushion). Same shape/discipline
    /// as `sessionSummary`; nil before any sample. `rebases` is shared (one pair
    /// epoch feeds both accumulators).
    func clockSkewSessionSummary() -> Summary? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard clockSampleCount > 0 else { return nil }
        return Summary(samples: clockSampleCount,
                       minMs: clockSampleMin, maxMs: clockSampleMax,
                       avgMs: clockSampleSum / Double(clockSampleCount),
                       p50Ms: quantileLocked(0.50, clockBucketCounts, clockOverflowCount,
                                             clockSampleCount, clockSampleMin, clockSampleMax),
                       p95Ms: quantileLocked(0.95, clockBucketCounts, clockOverflowCount,
                                             clockSampleCount, clockSampleMin, clockSampleMax),
                       p99Ms: quantileLocked(0.99, clockBucketCounts, clockOverflowCount,
                                             clockSampleCount, clockSampleMin, clockSampleMax),
                       rebases: rebases)
    }

    /// Bucket-interpolated quantile over a given accumulator. Lock already held;
    /// `sampleCount > 0` guaranteed by the caller. Clamped to the exact min/max
    /// so a single sample never reads as a bucket edge. The OVERFLOW tail is a
    /// real bucket in the walk - [last bound, exact max] with `overflow` mass -
    /// so a rank landing past the fixed bounds interpolates instead of pinning
    /// every quantile to the max (the degenerate-quantile half of a past
    /// av_skew break).
    private func quantileLocked(_ quantile: Double, _ buckets: [UInt64],
                                _ overflow: UInt64, _ count: UInt64,
                                _ minMs: Double, _ maxMs: Double) -> Double {
        let rank = quantile * Double(count)
        var cumulative: UInt64 = 0
        var lower = minMs
        for (idx, bucketCount) in buckets.enumerated() where bucketCount > 0 {
            let upper = Self.bucketBoundsMs[idx]
            let next = cumulative &+ bucketCount
            if Double(next) >= rank {
                let within = (rank - Double(cumulative)) / Double(bucketCount)
                let base = max(lower, Self.lowerEdge(idx))
                let estimate = base + (upper - base) * within
                return min(max(estimate, minMs), maxMs)
            }
            cumulative = next
            lower = upper
        }
        if overflow > 0 {
            let base = max(Self.bucketBoundsMs.last ?? minMs, minMs)
            let within = (rank - Double(cumulative)) / Double(overflow)
            let estimate = base + (maxMs - base) * within
            return min(max(estimate, minMs), maxMs)
        }
        return maxMs // floating-point edge backstop; the walk covers all mass
    }
    private static func lowerEdge(_ idx: Int) -> Double {
        idx > 0 ? bucketBoundsMs[idx - 1] : -sanityBoundMs
    }

    /// Reset the accumulator + anchors for a fresh session. Called from the
    /// audio decoder's session init (the one per-session edge both halves
    /// share); the scorecard reads at stop, before the next session's init.
    func resetForNewSession() {
        os_unfair_lock_lock(lock)
        anchored = false
        everAnchored = false
        rebases = 0
        videoNoteNanos = 0
        audioNoteNanos = 0
        // Clock-family calibration is per-session too: a different host may
        // ride a different audio RTP clock family.
        audioRateAnchorRtp = 0
        audioRateAnchorNanos = 0
        audioTicksPerMs = 1.0
        audioRateResolved = false
        audioRatePendingFamily = nil
        lastTrueClockSkewMs = nil
        bucketCounts = [UInt64](repeating: 0, count: Self.bucketBoundsMs.count)
        overflowCount = 0
        sampleCount = 0
        sampleSum = 0
        sampleMin = .infinity
        sampleMax = -.infinity
        clockBucketCounts = [UInt64](repeating: 0, count: Self.bucketBoundsMs.count)
        clockOverflowCount = 0
        clockSampleCount = 0
        clockSampleSum = 0
        clockSampleMin = .infinity
        clockSampleMax = -.infinity
        skewEwmaMs = 0
        skewEwmaSeeded = false
        os_unfair_lock_unlock(lock)
    }
}
