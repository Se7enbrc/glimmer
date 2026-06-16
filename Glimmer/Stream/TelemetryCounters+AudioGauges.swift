//
//  TelemetryCounters+AudioGauges.swift
//
//  The AUDIO gauge accessors: live playout state (buffer fill + clock drift),
//  the windowed buffer-fill trough, the audio cold-start
//  (time-to-first-decoded-audio) anchor + measurement, the AUDIO-TTF
//  context (warm/cold classification + host-idle covariate), the cross-stream
//  A/V-skew store (`av_skew_ms`), and the cushion-memory telemetry latch
//  (seed + live loss floor). Split out of TelemetryCounters.swift to keep that
//  file under the length limit (pure move, same idiom as the FramePacer split).
//  The stored gauge state (the locks + values) stays on the class in
//  TelemetryCounters.swift — stored properties cannot live in extensions; the
//  new stores below are self-locked top-level classes (the `AudioTtfContext`
//  idiom) so they need no class storage.
//

import Foundation
import os

extension TelemetryCounters {

    // MARK: - Audio playout gauges + cold-start

    /// Publish the live AUDIO playout state (buffer fill + A/V sync drift). Called
    /// off the hot path — the audio decode path stamps it under the lock it already
    /// holds for the decode (no extra lock on the audio path).
    func setAudioState(_ state: AudioState) {
        os_unfair_lock_lock(audioStateLock); audioStateValue = state; os_unfair_lock_unlock(audioStateLock)
    }
    /// Latest AUDIO playout state, or nil before the first decoded audio packet.
    /// Read by the exporter on its 1Hz queue (never the hot path).
    var audioState: AudioState? {
        os_unfair_lock_lock(audioStateLock); defer { os_unfair_lock_unlock(audioStateLock) }
        return audioStateValue
    }

    /// Lower the windowed MIN buffer-fill if this sample is a new trough. Called
    /// from the audio playout completion path (under the audio meter lock there,
    /// not this one — these are independent locks, no nesting). One compare + a
    /// conditional store; far below the 5ms audio budget.
    func noteAudioBufferFill(ms: Double) {
        os_unfair_lock_lock(audioStateLock)
        if ms < audioBufferFillMinMsValue { audioBufferFillMinMsValue = ms }
        os_unfair_lock_unlock(audioStateLock)
    }
    /// Take + RESET the windowed MIN buffer-fill (ms). Read once per tick by the
    /// exporter on its 1Hz queue (never the hot path); resetting on read makes each
    /// tick's min cover only that window's troughs. nil when no sample this window.
    func takeAudioBufferFillMinMs() -> Double? {
        os_unfair_lock_lock(audioStateLock)
        let value = audioBufferFillMinMsValue
        audioBufferFillMinMsValue = .infinity
        os_unfair_lock_unlock(audioStateLock)
        return value.isFinite ? value : nil
    }

    /// Anchor the audio cold-start clock at STREAM START. Called once when the
    /// audio receiver opens its socket; idempotent (a second call before the first
    /// packet is harmless, and after is ignored so the anchor stays the true start).
    func anchorAudioStreamStart() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(audioFirstPacketLock)
        if audioStreamStartNanosValue == 0 { audioStreamStartNanosValue = now }
        os_unfair_lock_unlock(audioFirstPacketLock)
    }

    /// Record the FIRST decoded-audio instant: compute time-to-first-audio (ms)
    /// from the TRUE session/connect-start anchor. Called once by the audio receive
    /// path on the first packet. No-op if no anchor is available, or if already
    /// recorded (keeps the first measurement). The cold-start (~5-7s on a lossy
    /// link) metric.
    ///
    /// The anchor is the P2 `connectStart`, stamped at the connect edge in
    /// `StreamSession.start()` immediately after `resetForNewSession` — which
    /// now ALSO runs at that edge, BEFORE any receiver exists, so neither this
    /// gauge nor the socket-open fallback epoch can carry a stale prior-session
    /// value into a warm-host race anymore (the chimeric audio_ttf mechanism).
    /// Measuring from the session-lifecycle anchor ties TTF to the real session
    /// start. NOTE: a big reading here is usually NOT an anchor bug — a ~40s
    /// reading has been observed as REAL host-side cold-start audio delay (our
    /// pings flowed at the designed cadence the whole time). Host audio bring-up
    /// is bimodal — warm ~0.3-1s, cold ~4.6-40s — and client-uncontrollable; this
    /// gauge makes that delay visible, it cannot shrink it. The audio-socket-
    /// open epoch is kept only as a fallback when the connect anchor is somehow
    /// unset.
    func recordAudioFirstPacket() {
        let now = DispatchTime.now().uptimeNanoseconds
        let connectStart = p2.connectStart
        os_unfair_lock_lock(audioFirstPacketLock)
        defer { os_unfair_lock_unlock(audioFirstPacketLock) }
        guard audioFirstPacketMsValue == 0 else { return }
        // Prefer the true session/connect-start anchor; fall back to the
        // audio-socket-open epoch only if connect-start was never stamped.
        let anchor = connectStart != 0 ? connectStart : audioStreamStartNanosValue
        guard anchor != 0, now >= anchor else { return }
        audioFirstPacketMsValue = Double(now &- anchor) / 1_000_000.0
    }
    /// Time-to-first-decoded-audio (ms), or nil if not yet measured. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    var audioFirstPacketMs: Double? {
        os_unfair_lock_lock(audioFirstPacketLock); defer { os_unfair_lock_unlock(audioFirstPacketLock) }
        return audioFirstPacketMsValue != 0 ? audioFirstPacketMsValue : nil
    }
}

// MARK: - Audio-TTF context (warm/cold classification + host-idle covariate)

/// The shared state behind the `audio_ttf` event's warm/cold classification and
/// its `host_idle_s` covariate, plus the latched record the session scorecard
/// reads at stop. Host audio bring-up is bimodal (warm ~0.3-1s vs cold
/// ~4.6-40s, host-side and client-uncontrollable); classifying every session
/// makes the warm-host-luck confound machine-checkable instead of agent-argued.
///
/// HOST-IDLE APPROXIMATION (data-first honesty — the field is best-effort):
/// `host_idle_s` measures from a WALL-CLOCK stamp of when THIS CLIENT's
/// previous session ended (`markStreamEnd()`, called at session teardown), not
/// the host's true last packet — teardown trails the last packet by under a
/// second, close enough for a covariate whose interesting scale is minutes.
/// The stamp is PROCESS-LIFETIME only: after an app relaunch there is no prior
/// stamp and `host_idle_s` is simply omitted (absent ≠ 0). And it cannot see
/// another client warming the host in between. Wall clock (not mach uptime)
/// deliberately: the Mac may sleep across the idle gap, and uptime stops while
/// asleep.
///
/// Self-locked like `P2State` so the rare TTF-latch / teardown writes stay off
/// every other counter's lock.
final class AudioTtfContext: @unchecked Sendable {
    /// Classification threshold (ms) on the ping→first-RTP span: ~2s cleanly
    /// splits the measured bimodal data (warm 284-984ms vs cold 4.6-40.2s
    /// across 12 sessions). Source sites classify against THIS constant so the
    /// event row and the scorecard can never disagree on the split.
    static let warmPingToRtpThresholdMs: Double = 2000

    /// One session's latched TTF classification, written once at the TTF event.
    struct Record: Sendable {
        /// "warm" | "cold", keyed on ping_to_rtp_ms vs the threshold above
        /// (nil ping span → "cold": no RTP answer inside any warm window).
        var ttfClass: String
        /// The host-side bring-up span the class was keyed on, when measured.
        var pingToRtpMs: Double?
        /// Seconds since this client's previous session ended (see the
        /// approximation note on the type). nil when underivable.
        var hostIdleSeconds: Double?
        /// The startup-pacing verdict ("burst" | "paced") carried alongside so
        /// the scorecard tells the whole startup story on one line.
        var startup: String?
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var record: Record?
    /// Wall-clock stamp (`timeIntervalSinceReferenceDate`) of the previous
    /// stream's end; 0 = no stream has ended this process run.
    private var lastStreamEndReference: Double = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// Stamp the stream-end instant. Called from session teardown (the source
    /// site wires this); idempotence doesn't matter — last writer wins and a
    /// double teardown stamps the same instant twice.
    func markStreamEnd() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        lastStreamEndReference = now
        os_unfair_lock_unlock(lock)
    }

    /// Classify + latch this session's TTF record (first writer wins, like the
    /// cold-start gauge it travels with), deriving `host_idle_s` from the
    /// previous stream-end stamp. Returns the latched record so the event row
    /// emits exactly what the scorecard will report. Called once per session
    /// from the audio receive path's TTF latch — never a hot path.
    @discardableResult
    func latchClassifying(pingToRtpMs: Double?, startup: String?) -> Record {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if let existing = record { return existing }
        let warm = (pingToRtpMs ?? .infinity) <= Self.warmPingToRtpThresholdMs
        let idle = lastStreamEndReference > 0 && now > lastStreamEndReference
            ? now - lastStreamEndReference : nil
        let latched = Record(ttfClass: warm ? "warm" : "cold",
                             pingToRtpMs: pingToRtpMs,
                             hostIdleSeconds: idle,
                             startup: startup)
        record = latched
        return latched
    }

    /// This session's latched record, or nil before the TTF event. Read by the
    /// scorecard at stop.
    var latched: Record? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return record
    }

    /// Clear the per-session record but PRESERVE the last-stream-end stamp —
    /// the stamp is the previous session's teardown instant, exactly what this
    /// session's `host_idle_s` measures from.
    func resetForNewSession() {
        os_unfair_lock_lock(lock); record = nil; os_unfair_lock_unlock(lock)
    }
}

// MARK: - Cross-stream A/V skew store (`av_skew_ms`)

/// The TRUE cross-stream A/V alignment meter the deferred `av_lag_est_ms`
/// derivation comment (TelemetryExporter+RenderNDJSON) called for. Two hot-path
/// one-word writes feed it — the last-PRESENTED video RTP (90kHz host capture
/// clock, written at the renderer-enqueue site) and the last-SCHEDULED audio RTP
/// (written at the audio decode hand-off) — and a 1Hz cold read derives
///   skew_ms = video_presented_pos − (audio_scheduled_pos − buffer_fill_ms)
/// with SIGN CONVENTION: positive = AUDIO LATE (behind video). The buffer-fill
/// term converts the schedule-head position to the PLAYHEAD position (the
/// playhead trails the newest scheduled packet by exactly the standing fill).
///
/// AUDIO CLOCK UNITS (a past instrument break): the audio
/// RTP timestamp is NOT a 48kHz sample clock. Sunshine advances it by
/// `packetDuration` per packet (stream.cpp) — 5 per 5ms packet — i.e. a
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
/// e2e, single-digit ms) rides along as a constant bias — the trend and the
/// steps are the signal, the absolute is approximate. The anchor pair drops
/// whenever either stream goes stale (>2s — present-suppressed/AFK windows,
/// session teardown) or the sanity bound trips (an RTP discontinuity), and
/// re-latches at the next tick where both flow — counted in `rebaseTotal`, so a
/// mid-session re-baseline is never a silent step. Never a permanent give-up:
/// every dark state self-heals one tick after both streams resume.
///
/// Self-locked (the `AudioTtfContext` idiom); the per-write cost is one clock
/// read + an unfair lock + two stores at ≤240Hz video / 200Hz audio — the same
/// always-live budget as the audio meter's per-packet accounting.
final class AudioVideoSkewStore: @unchecked Sendable {
    static let shared = AudioVideoSkewStore()

    /// Freshness horizon (ns) per side: a side not written within this window
    /// (suppressed presents, drained audio, teardown) drops the anchor pair and
    /// the derive reports absent (absent ≠ 0) until both sides flow again.
    static let freshnessNanos: UInt64 = 2_000_000_000
    /// Sanity bound (ms) on a derived skew: beyond this the anchors are judged
    /// inconsistent (host RTP discontinuity) and the pair re-latches.
    static let sanityBoundMs: Double = 10_000
    /// Signed bucket bounds (ms) for the session percentile accumulator —
    /// resolution concentrated around the 0…150ms cushion range where the
    /// lip-sync trade lives, with the ~125ms ITU annoyance threshold bracketed.
    static let bucketBoundsMs: [Double] = [
        -1000, -500, -250, -125, -90, -60, -40, -25, -10, 0,
        10, 25, 40, 60, 75, 90, 110, 125, 150, 200, 300, 500, 1000
    ]
    /// Video RTP is a 90kHz capture clock (RTP standard for video).
    static let videoRtpTicksPerMs = 90.0
    /// The two known audio RTP clock families: Sunshine's packet-duration
    /// MILLISECOND clock (1 tick/ms — the live host, the default) and a true
    /// 48kHz sample clock (48 ticks/ms — what the RTP header would suggest and
    /// what the old conversion wrongly assumed). The measured-rate snap picks
    /// between them; see the AUDIO CLOCK UNITS doc on the type.
    static let audioTicksPerMsCandidates: [Double] = [1.0, 48.0]
    /// Minimum audio-flow span before the measured advance rate is trusted to
    /// snap the clock family. At ~200 packets/s, 2s ≈ 400 packets; arrival
    /// clumping on a jittery link distorts a 2s window by a few percent — the
    /// candidate families are 4800% apart, so a mis-snap would take a clumping
    /// pathology no real link produces.
    static let audioRateCalibrationNanos: UInt64 = 2_000_000_000

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
    // the nearest candidate family — once, then latched for the session.
    private var audioRateAnchorRtp: UInt32 = 0
    private var audioRateAnchorNanos: UInt64 = 0
    private var audioTicksPerMs = 1.0
    private var audioRateResolved = false
    // Session accumulator (scorecard percentiles): bucket counts + exact
    // min/max/sum, plus an explicit OVERFLOW count for samples past the last
    // bound so the quantile walk's rank space covers EVERY sample — the old
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

    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// VIDEO half: the RTP timestamp of the frame that just reached the
    /// renderer. Called from the present site (gate-on path only — the
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
        audioLastRtp = rtp
        audioNoteNanos = now
        if audioRateAnchorNanos == 0 {
            audioRateAnchorRtp = rtp
            audioRateAnchorNanos = now
        }
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
    /// tick. `accumulate` feeds the session percentile accumulator — set it
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
            return nil
        }
        resolveAudioClockFamilyLocked(now: now)
        if !anchored {
            anchored = true
            videoAnchorRtp = videoLastRtp
            audioAnchorRtp = audioLastRtp
            if everAnchored { rebases &+= 1 }
            everAnchored = true
            return nil // the anchor tick defines the epoch, measures nothing
        }
        // Wrap-safe modular distances on the two host capture clocks (90kHz
        // video / the calibrated audio clock — see AUDIO CLOCK UNITS on the
        // type); both monotone within any realistic session.
        let videoMs = Double(videoLastRtp &- videoAnchorRtp) / Self.videoRtpTicksPerMs
        let audioMs = Double(audioLastRtp &- audioAnchorRtp) / audioTicksPerMs
        let skewMs = videoMs - audioMs + fillMs
        guard abs(skewMs) <= Self.sanityBoundMs else {
            anchored = false // discontinuity: re-anchor next tick, never wedge
            return nil
        }
        if accumulate { observeLocked(skewMs) }
        return skewMs
    }

    /// One-shot audio clock-family snap (lock already held; 1Hz cold path):
    /// once ≥2s of audio has flowed, measure ticks-per-ms against the wall
    /// clock and latch the nearest known family (ratio space, so the compare
    /// is symmetric around the 48x gap). Until it resolves, derives run on
    /// the nominal ms clock — correct for the live Sunshine host from tick 1;
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
        }
        audioTicksPerMs = snapped ?? 1.0
        audioRateResolved = true
    }

    /// Feed one 1Hz sample into the session accumulator. Lock already held.
    private func observeLocked(_ skewMs: Double) {
        sampleCount &+= 1
        sampleSum += skewMs
        if skewMs < sampleMin { sampleMin = skewMs }
        if skewMs > sampleMax { sampleMax = skewMs }
        if let idx = Self.bucketBoundsMs.firstIndex(where: { skewMs <= $0 }) {
            bucketCounts[idx] &+= 1
        } else {
            overflowCount &+= 1 // past the last bound; see the overflow doc
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
                       p50Ms: quantileLocked(0.50),
                       p95Ms: quantileLocked(0.95),
                       p99Ms: quantileLocked(0.99),
                       rebases: rebases)
    }

    /// Bucket-interpolated quantile. Lock already held; `sampleCount > 0`
    /// guaranteed by the caller. Clamped to the exact min/max so a single
    /// sample never reads as a bucket edge. The OVERFLOW tail is a real
    /// bucket in the walk — [last bound, exact max] with `overflowCount`
    /// mass — so a rank landing past the fixed bounds interpolates instead
    /// of pinning every quantile to the max (the degenerate-quantile half of
    /// a past av_skew break).
    private func quantileLocked(_ quantile: Double) -> Double {
        let rank = quantile * Double(sampleCount)
        var cumulative: UInt64 = 0
        var lower = sampleMin
        for (idx, count) in bucketCounts.enumerated() where count > 0 {
            let upper = Self.bucketBoundsMs[idx]
            let next = cumulative &+ count
            if Double(next) >= rank {
                let within = (rank - Double(cumulative)) / Double(count)
                let base = max(lower, Self.lowerEdge(idx))
                let estimate = base + (upper - base) * within
                return min(max(estimate, sampleMin), sampleMax)
            }
            cumulative = next
            lower = upper
        }
        if overflowCount > 0 {
            let base = max(Self.bucketBoundsMs.last ?? sampleMin, sampleMin)
            let within = (rank - Double(cumulative)) / Double(overflowCount)
            let estimate = base + (sampleMax - base) * within
            return min(max(estimate, sampleMin), sampleMax)
        }
        return sampleMax // floating-point edge backstop; the walk covers all mass
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
        bucketCounts = [UInt64](repeating: 0, count: Self.bucketBoundsMs.count)
        overflowCount = 0
        sampleCount = 0
        sampleSum = 0
        sampleMin = .infinity
        sampleMax = -.infinity
        os_unfair_lock_unlock(lock)
    }
}

// MARK: - Cushion-memory telemetry latch (seed + live loss floor)

/// Visibility shim for the audio cushion's persistent memory (the decay-
/// limit-cycle fix): the seed the session started from (ridden by the
/// `audio_ttf` event so every session self-describes its starting cushion) and
/// the LIVE learned loss floor (1Hz `audio_cushion_floor_ms` field). Stored
/// here — not on `AudioState` — so the exporter reads it without touching the
/// snapshot structs; written only on the rare seed/learn/decay edges.
final class AudioCushionTelemetry: @unchecked Sendable {
    static let shared = AudioCushionTelemetry()

    /// One session's seed record, latched at audio-decoder init (last writer
    /// wins — one audio init per session IS the session edge).
    struct Seed: Sendable {
        let link: String
        let targetMs: Double
        let floorMs: Double
        let fromMemory: Bool
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var seedValue: Seed?
    private var floorMsValue: Double = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    func latchSeed(_ seed: Seed) {
        os_unfair_lock_lock(lock)
        seedValue = seed
        floorMsValue = seed.floorMs
        os_unfair_lock_unlock(lock)
    }
    var seed: Seed? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return seedValue
    }

    /// The live learned loss floor (0 = unlearned). Updated on learn/decay/
    /// link-resolve edges only.
    func setFloorMs(_ value: Double) {
        os_unfair_lock_lock(lock); floorMsValue = value; os_unfair_lock_unlock(lock)
    }
    var floorMs: Double {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return floorMsValue
    }
}
